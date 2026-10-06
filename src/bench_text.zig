//! Rendering-thread text measurement; not a whole-browser benchmark.
const std = @import("std");
const TextRenderer = @import("paint/text.zig").TextRenderer;
const resolver = @import("paint/font_resolver.zig");
const c = @import("bindings/freetype.zig").c;

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    const path = resolver.resolve(allocator, "sans-serif") orelse return error.MissingBenchmarkFont;
    defer allocator.free(path);
    var renderer = try TextRenderer.init(path, 16);
    defer renderer.deinit();
    const samples = [_][]const u8{
        "A browser paragraph with AV kerning, office ligatures and repeated words. Layout must preserve the same measured advances while reducing allocations.",
        "const result = renderer.measure(text); // repeated layout and resize",
        "日本語 mixed with Latin: AV fi office and UTF-8 byte clusters.",
    };
    const iterations = 20000;
    var expected: [samples.len]i32 = undefined;
    var unique_expected: [iterations]i32 = undefined;
    var key: [64]u8 = undefined;
    renderer.metric_cache_enabled = false;
    for (samples, 0..) |sample, i| expected[i] = renderer.measure(sample).width;
    for (0..iterations) |i| {
        const text = try std.fmt.bufPrint(&key, "unique row label {d}", .{i});
        unique_expected[i] = renderer.measure(text).width;
    }
    // Both modes use the same already-warmed font/glyph data. Include a
    // no-cache-hit workload, not just a favorable repeated-label case.
    for ([_]bool{ false, true }) |unique| {
        for ([_]bool{ false, true }) |reuse| {
            if (renderer.measure_buffer) |buffer| c.hb_buffer_destroy(buffer);
            renderer.measure_buffer = null;
            renderer.metric_cache_enabled = reuse;
            renderer.metric_count = 0;
            renderer.metric_next = 0;
            var checksum: u64 = 0;
            const start = std.Io.Clock.awake.now(io);
            for (0..iterations) |i| {
                const index = i % samples.len;
                const text = if (unique) try std.fmt.bufPrint(&key, "unique row label {d}", .{i}) else samples[index];
                const metrics = renderer.measure(text);
                if (metrics.width != (if (unique) unique_expected[i] else expected[index])) return error.IncorrectTextMetrics;
                checksum += @intCast(metrics.width);
                // Baseline disables metric memoization and reproduces the old
                // per-measure buffer lifecycle. Every advance is checked.
                if (!reuse) {
                    c.hb_buffer_destroy(renderer.measure_buffer.?);
                    renderer.measure_buffer = null;
                }
            }
            const elapsed = start.untilNow(io, .awake).nanoseconds;
            std.debug.print("{{\"case\":\"{s}\",\"reuse\":{},\"optimize\":\"{s}\",\"iterations\":{d},\"measure_ns\":{d},\"checksum\":{d}}}\n", .{
                if (unique) "unique" else "repeated", reuse, @tagName(@import("builtin").mode), iterations, elapsed, checksum,
            });
        }
    }
}
