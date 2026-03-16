const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// A single history entry.
pub const HistoryEntry = struct {
    url: []const u8,
    title: []const u8,
    visited_at: []const u8,
};

/// A single bookmark entry.
pub const BookmarkEntry = struct {
    url: []const u8,
    title: []const u8,
    created_at: []const u8,
};

pub const Storage = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,

    const schema =
        \\CREATE TABLE IF NOT EXISTS history (
        \\  id INTEGER PRIMARY KEY,
        \\  url TEXT NOT NULL,
        \\  title TEXT,
        \\  visited_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\);
        \\CREATE TABLE IF NOT EXISTS bookmarks (
        \\  id INTEGER PRIMARY KEY,
        \\  url TEXT NOT NULL UNIQUE,
        \\  title TEXT,
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\);
        \\CREATE TABLE IF NOT EXISTS sessions (
        \\  id INTEGER PRIMARY KEY,
        \\  data TEXT,
        \\  saved_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\);
    ;

    pub fn init(allocator: std.mem.Allocator) !Storage {
        // Ensure XDG data directory exists
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const data_dir = try std.fmt.allocPrint(allocator, "{s}/.local/share/suzume", .{home});
        defer allocator.free(data_dir);

        // Create directory (recursive)
        std.fs.cwd().makePath(data_dir) catch {};

        const db_path_slice = try std.fmt.allocPrint(allocator, "{s}/suzume.db", .{data_dir});
        defer allocator.free(db_path_slice);

        // Create sentinel-terminated path for sqlite3_open
        const db_path = try allocator.allocSentinel(u8, db_path_slice.len, 0);
        defer allocator.free(db_path);
        @memcpy(db_path, db_path_slice);

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }

        var self = Storage{
            .db = db.?,
            .allocator = allocator,
        };

        // Create tables
        try self.exec(schema);

        return self;
    }

    pub fn deinit(self: *Storage) void {
        _ = c.sqlite3_close(self.db);
    }

    fn exec(self: *Storage, sql: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg != null) {
                std.debug.print("[Storage] SQL error: {s}\n", .{std.mem.span(err_msg)});
                c.sqlite3_free(err_msg);
            }
            return error.SqliteExecFailed;
        }
    }

    /// Add a URL visit to history.
    pub fn addHistory(self: *Storage, url: []const u8, title: []const u8) void {
        const sql = "INSERT INTO history (url, title) VALUES (?1, ?2)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, url.ptr, @intCast(url.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 2, title.ptr, @intCast(title.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_step(stmt);
    }

    /// Get recent history entries. Caller must free each entry's strings and the returned slice.
    pub fn getHistory(self: *Storage, limit: u32) []HistoryEntry {
        const sql = "SELECT url, title, visited_at FROM history ORDER BY visited_at DESC LIMIT ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return &.{};
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int(stmt, 1, @intCast(limit));

        var entries: std.ArrayListUnmanaged(HistoryEntry) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const entry = HistoryEntry{
                .url = dupeColumnText(self.allocator, stmt, 0),
                .title = dupeColumnText(self.allocator, stmt, 1),
                .visited_at = dupeColumnText(self.allocator, stmt, 2),
            };
            entries.append(self.allocator, entry) catch break;
        }

        return entries.toOwnedSlice(self.allocator) catch {
            for (entries.items) |entry| {
                self.allocator.free(entry.url);
                self.allocator.free(entry.title);
                self.allocator.free(entry.visited_at);
            }
            entries.deinit(self.allocator);
            return &.{};
        };
    }

    /// Free a slice of HistoryEntry returned by getHistory.
    pub fn freeHistory(self: *Storage, entries: []HistoryEntry) void {
        for (entries) |entry| {
            self.allocator.free(entry.url);
            self.allocator.free(entry.title);
            self.allocator.free(entry.visited_at);
        }
        self.allocator.free(entries);
    }

    /// Add a bookmark.
    pub fn addBookmark(self: *Storage, url: []const u8, title: []const u8) void {
        const sql = "INSERT OR IGNORE INTO bookmarks (url, title) VALUES (?1, ?2)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, url.ptr, @intCast(url.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 2, title.ptr, @intCast(title.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_step(stmt);
    }

    /// Remove a bookmark by URL.
    pub fn removeBookmark(self: *Storage, url: []const u8) void {
        const sql = "DELETE FROM bookmarks WHERE url = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, url.ptr, @intCast(url.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_step(stmt);
    }

    /// Check if a URL is bookmarked.
    pub fn isBookmarked(self: *Storage, url: []const u8) bool {
        const sql = "SELECT COUNT(*) FROM bookmarks WHERE url = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return false;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, url.ptr, @intCast(url.len), c.SQLITE_TRANSIENT);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return c.sqlite3_column_int(stmt, 0) > 0;
        }
        return false;
    }

    /// Get all bookmarks. Caller must free with freeBookmarks.
    pub fn getBookmarks(self: *Storage) []BookmarkEntry {
        const sql = "SELECT url, title, created_at FROM bookmarks ORDER BY created_at DESC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return &.{};
        defer _ = c.sqlite3_finalize(stmt);

        var entries: std.ArrayListUnmanaged(BookmarkEntry) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const entry = BookmarkEntry{
                .url = dupeColumnText(self.allocator, stmt, 0),
                .title = dupeColumnText(self.allocator, stmt, 1),
                .created_at = dupeColumnText(self.allocator, stmt, 2),
            };
            entries.append(self.allocator, entry) catch break;
        }

        return entries.toOwnedSlice(self.allocator) catch {
            for (entries.items) |entry| {
                self.allocator.free(entry.url);
                self.allocator.free(entry.title);
                self.allocator.free(entry.created_at);
            }
            entries.deinit(self.allocator);
            return &.{};
        };
    }

    /// Free a slice of BookmarkEntry returned by getBookmarks.
    pub fn freeBookmarks(self: *Storage, entries: []BookmarkEntry) void {
        for (entries) |entry| {
            self.allocator.free(entry.url);
            self.allocator.free(entry.title);
            self.allocator.free(entry.created_at);
        }
        self.allocator.free(entries);
    }

    /// Save session data (JSON string). Keeps only the most recent 5 sessions.
    pub fn saveSession(self: *Storage, json_data: []const u8) void {
        // Delete old sessions, keeping only the most recent 4 (new one will be 5th)
        self.exec("DELETE FROM sessions WHERE id NOT IN (SELECT id FROM sessions ORDER BY saved_at DESC LIMIT 4)") catch {};

        const sql = "INSERT INTO sessions (data) VALUES (?1)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, json_data.ptr, @intCast(json_data.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_step(stmt);
    }

    /// Load the most recent session data. Caller must free the returned slice.
    pub fn loadSession(self: *Storage) ?[]const u8 {
        const sql = "SELECT data FROM sessions ORDER BY saved_at DESC LIMIT 1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const text = dupeColumnText(self.allocator, stmt, 0);
            if (text.len > 0) return text;
            self.allocator.free(text);
        }
        return null;
    }

    fn dupeColumnText(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, col: c_int) []const u8 {
        const ptr: ?[*]const u8 = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        if (ptr == null or len == 0) return allocator.alloc(u8, 0) catch &.{};
        return allocator.dupe(u8, ptr.?[0..len]) catch allocator.alloc(u8, 0) catch &.{};
    }
};
