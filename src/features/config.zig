const std = @import("std");

pub const Config = struct {
    entries: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    const defaults = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "max_active_tabs", .value = "3" },
        .{ .key = "homepage", .value = "suzume://home" },
        .{ .key = "adblock_enabled", .value = "true" },
    };

    pub fn init(allocator: std.mem.Allocator) Config {
        var self = Config{
            .entries = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };

        // Load defaults
        for (defaults) |d| {
            const key = allocator.dupe(u8, d.key) catch continue;
            const val = allocator.dupe(u8, d.value) catch {
                allocator.free(key);
                continue;
            };
            self.entries.put(key, val) catch {
                allocator.free(key);
                allocator.free(val);
            };
        }

        // Try to load config file
        self.loadFromFile();

        return self;
    }

    pub fn deinit(self: *Config) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn get(self: *const Config, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    pub fn getInt(self: *const Config, key: []const u8) ?i64 {
        const val = self.entries.get(key) orelse return null;
        return std.fmt.parseInt(i64, val, 10) catch null;
    }

    fn loadFromFile(self: *Config) void {
        const home = std.posix.getenv("HOME") orelse return;
        const config_dir = std.fmt.allocPrint(self.allocator, "{s}/.config/suzume", .{home}) catch return;
        defer self.allocator.free(config_dir);

        // Create config directory if needed
        std.fs.cwd().makePath(config_dir) catch {};

        const config_path = std.fmt.allocPrint(self.allocator, "{s}/config", .{config_dir}) catch return;
        defer self.allocator.free(config_path);

        const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Write default config file
                self.writeDefaults(config_path);
            }
            return;
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        const content = file.readAll(&buf) catch return;
        if (content == buf.len) {
            std.debug.print("[Config] Warning: config file may be truncated (>= {d} bytes)\n", .{buf.len});
        }
        const data = buf[0..content];

        var line_iter = std.mem.splitScalar(u8, data, '\n');
        while (line_iter.next()) |line| {

            // Skip comments and blank lines
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Parse key=value
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                if (key.len == 0) continue;

                // Remove old entry if exists
                if (self.entries.fetchRemove(key)) |old| {
                    self.allocator.free(old.key);
                    self.allocator.free(old.value);
                }

                const owned_key = self.allocator.dupe(u8, key) catch continue;
                const owned_val = self.allocator.dupe(u8, val) catch {
                    self.allocator.free(owned_key);
                    continue;
                };
                self.entries.put(owned_key, owned_val) catch {
                    self.allocator.free(owned_key);
                    self.allocator.free(owned_val);
                };
            }
        }
    }

    fn writeDefaults(self: *Config, path: []const u8) void {
        _ = self;
        const file = std.fs.cwd().createFile(path, .{}) catch return;
        defer file.close();

        const content =
            \\# Suzume browser configuration
            \\# Lines starting with # are comments
            \\
            \\max_active_tabs=3
            \\homepage=suzume://home
            \\adblock_enabled=true
            \\
        ;
        _ = file.writeAll(content) catch {};
    }
};
