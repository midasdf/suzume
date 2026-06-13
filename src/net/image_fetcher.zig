//! Background image fetcher — a fixed pool of worker threads performing the
//! blocking libcurl fetches off the UI thread. Image decode and every DOM /
//! JS / layout mutation stays on the main thread, which submits jobs and
//! drains completed results once per event-loop tick.
//!
//! Ownership: all job/result strings and bodies live on `std.heap.c_allocator`
//! (thread-safe), duped on submit and freed via `Result.deinit()` after the
//! main thread has consumed them. Each worker owns a private `HttpClient`
//! (curl easy handles must not be shared across threads); the handles are
//! created on the main thread in `start()` so `curl_global_init` is never
//! raced.
//!
//! Results carry the `generation` stamp of the page that submitted them so
//! the drain loop can discard fetches that complete after a navigation.

const std = @import("std");
const sync = @import("../sync.zig");
const env = @import("../env.zig");
const http = @import("http.zig");

const alloc = std.heap.c_allocator;

pub const Job = struct {
    /// Page-side image-cache key (the raw src as collected from the box tree).
    url: []u8,
    /// Absolute URL to fetch.
    resolved: [:0]u8,
    intrinsic_width: f32,
    intrinsic_height: f32,
    is_retry: bool,
    /// Opaque lxb_dom_node pointer for firing load/error events — only ever
    /// dereferenced on the main thread, and only when the generation matches.
    dom_node: ?*anyopaque,
    generation: u64,
};

pub const Result = struct {
    job: Job,
    /// Response body for a 200 within size bounds; null on any failure.
    body: ?[]u8,

    pub fn deinit(self: *Result) void {
        alloc.free(self.job.url);
        alloc.free(self.job.resolved);
        if (self.body) |b| alloc.free(b);
    }
};

pub const ImageFetcher = struct {
    const num_workers = 4;
    /// Mirrors the old synchronous path's per-image body cap.
    const max_body_bytes = 2 * 1024 * 1024;

    jobs: std.ArrayListUnmanaged(Job) = .empty,
    results: std.ArrayListUnmanaged(Result) = .empty,
    mutex: sync.Mutex = .{},
    threads: [num_workers]?std.Thread = @splat(null),
    clients: [num_workers]?http.HttpClient = @splat(null),
    shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Spawn the worker pool. Curl handles are created here (main thread)
    /// so the global-init refcount is never touched concurrently. Workers
    /// that fail to start simply shrink the pool; with zero workers
    /// `isActive()` returns false and callers fall back to sync fetching.
    pub fn start(self: *ImageFetcher) void {
        for (0..num_workers) |i| {
            const client = http.HttpClient.init() catch continue;
            self.clients[i] = client;
            self.threads[i] = std.Thread.spawn(.{}, workerMain, .{ self, i }) catch {
                self.clients[i].?.deinit();
                self.clients[i] = null;
                continue;
            };
        }
    }

    pub fn isActive(self: *const ImageFetcher) bool {
        for (self.threads) |t| {
            if (t != null) return true;
        }
        return false;
    }

    /// Queue a fetch. Strings are duped; the caller keeps ownership of its
    /// slices. Main thread only.
    pub fn submit(
        self: *ImageFetcher,
        url: []const u8,
        resolved: []const u8,
        intrinsic_width: f32,
        intrinsic_height: f32,
        is_retry: bool,
        dom_node: ?*anyopaque,
        generation: u64,
    ) !void {
        const url_d = try alloc.dupe(u8, url);
        errdefer alloc.free(url_d);
        const res_d = try alloc.dupeZ(u8, resolved);
        errdefer alloc.free(res_d);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.jobs.append(alloc, .{
            .url = url_d,
            .resolved = res_d,
            .intrinsic_width = intrinsic_width,
            .intrinsic_height = intrinsic_height,
            .is_retry = is_retry,
            .dom_node = dom_node,
            .generation = generation,
        });
    }

    /// Pop one completed result, or null. Main thread only; caller must
    /// `Result.deinit()` when done.
    pub fn popResult(self: *ImageFetcher) ?Result {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.results.pop();
    }

    /// True while any fetch is queued or being processed — used by the main
    /// loop to keep its poll timeout short so results paint promptly.
    pub fn busy(self: *ImageFetcher) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.jobs.items.len > 0 or self.results.items.len > 0;
    }

    pub fn stop(self: *ImageFetcher) void {
        self.shutdown_flag.store(true, .release);
        for (&self.threads) |*t| {
            if (t.*) |th| th.join();
            t.* = null;
        }
        for (&self.clients) |*cl| {
            if (cl.*) |*client| client.deinit();
            cl.* = null;
        }
        for (self.jobs.items) |job| {
            alloc.free(job.url);
            alloc.free(job.resolved);
        }
        self.jobs.deinit(alloc);
        self.jobs = .empty;
        for (self.results.items) |*r| r.deinit();
        self.results.deinit(alloc);
        self.results = .empty;
    }

    fn workerMain(self: *ImageFetcher, idx: usize) void {
        const client = &self.clients[idx].?;
        while (!self.shutdown_flag.load(.acquire)) {
            const job_opt: ?Job = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.jobs.items.len == 0) break :blk null;
                break :blk self.jobs.orderedRemove(0);
            };
            const job = job_opt orelse {
                env.sleepNs(10 * std.time.ns_per_ms);
                continue;
            };
            var body: ?[]u8 = null;
            if (client.getWithTimeout(alloc, job.resolved, 5)) |resp_val| {
                var resp = resp_val;
                if (resp.status_code == 200 and resp.body.len > 0 and resp.body.len <= max_body_bytes) {
                    body = resp.body;
                    if (resp.content_type.len > 0) alloc.free(resp.content_type);
                    if (resp.etag.len > 0) alloc.free(resp.etag);
                    if (resp.last_modified.len > 0) alloc.free(resp.last_modified);
                } else {
                    resp.deinit();
                }
            } else |_| {}
            self.mutex.lock();
            defer self.mutex.unlock();
            self.results.append(alloc, .{ .job = job, .body = body }) catch {
                alloc.free(job.url);
                alloc.free(job.resolved);
                if (body) |b| alloc.free(b);
            };
        }
    }
};
