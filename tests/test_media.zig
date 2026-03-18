const std = @import("std");
const media = @import("media");

test "empty query returns true" {
    try std.testing.expect(media.evaluateMediaQuery("", 1024, 768));
    try std.testing.expect(media.evaluateMediaQuery("   ", 1024, 768));
}

test "media type: screen is true" {
    try std.testing.expect(media.evaluateMediaQuery("screen", 1024, 768));
}

test "media type: print is false" {
    try std.testing.expect(!media.evaluateMediaQuery("print", 1024, 768));
}

test "media type: all is true" {
    try std.testing.expect(media.evaluateMediaQuery("all", 1024, 768));
}

test "min-width matches" {
    try std.testing.expect(media.evaluateMediaQuery("(min-width: 768px)", 1024, 768));
    try std.testing.expect(media.evaluateMediaQuery("(min-width: 768px)", 768, 768));
    try std.testing.expect(!media.evaluateMediaQuery("(min-width: 1025px)", 1024, 768));
}

test "max-width matches" {
    try std.testing.expect(media.evaluateMediaQuery("(max-width: 1024px)", 1024, 768));
    try std.testing.expect(media.evaluateMediaQuery("(max-width: 1280px)", 1024, 768));
    try std.testing.expect(!media.evaluateMediaQuery("(max-width: 600px)", 1024, 768));
}

test "min-height and max-height" {
    try std.testing.expect(media.evaluateMediaQuery("(min-height: 600px)", 1024, 768));
    try std.testing.expect(!media.evaluateMediaQuery("(min-height: 1000px)", 1024, 768));
    try std.testing.expect(media.evaluateMediaQuery("(max-height: 768px)", 1024, 768));
    try std.testing.expect(!media.evaluateMediaQuery("(max-height: 600px)", 1024, 768));
}

test "not negates" {
    try std.testing.expect(!media.evaluateMediaQuery("not screen", 1024, 768));
    try std.testing.expect(media.evaluateMediaQuery("not print", 1024, 768));
    try std.testing.expect(!media.evaluateMediaQuery("not (min-width: 768px)", 1024, 768));
}

test "and combines" {
    try std.testing.expect(media.evaluateMediaQuery("screen and (min-width: 768px)", 1024, 768));
    try std.testing.expect(!media.evaluateMediaQuery("screen and (min-width: 1200px)", 1024, 768));
    try std.testing.expect(!media.evaluateMediaQuery("print and (min-width: 768px)", 1024, 768));
}

test "comma is OR" {
    try std.testing.expect(media.evaluateMediaQuery("print, (min-width: 768px)", 1024, 768));
    try std.testing.expect(media.evaluateMediaQuery("print, screen", 1024, 768));
    try std.testing.expect(!media.evaluateMediaQuery("print, (min-width: 2000px)", 1024, 768));
}

test "prefers-color-scheme: dark is true" {
    try std.testing.expect(media.evaluateMediaQuery("(prefers-color-scheme: dark)", 1024, 768));
    try std.testing.expect(!media.evaluateMediaQuery("(prefers-color-scheme: light)", 1024, 768));
}

test "only prefix treated same as without" {
    try std.testing.expect(media.evaluateMediaQuery("only screen", 1024, 768));
    try std.testing.expect(!media.evaluateMediaQuery("only print", 1024, 768));
}

test "complex query: screen and range" {
    try std.testing.expect(media.evaluateMediaQuery("screen and (min-width: 600px) and (max-width: 1200px)", 1024, 768));
    try std.testing.expect(!media.evaluateMediaQuery("screen and (min-width: 600px) and (max-width: 900px)", 1024, 768));
}

test "unknown media feature: fail-open" {
    try std.testing.expect(media.evaluateMediaQuery("(color)", 1024, 768));
    try std.testing.expect(media.evaluateMediaQuery("(hover: hover)", 1024, 768));
}

test "em units in media query" {
    // 48em = 48 * 16 = 768px
    try std.testing.expect(media.evaluateMediaQuery("(min-width: 48em)", 768, 600));
    try std.testing.expect(!media.evaluateMediaQuery("(min-width: 48em)", 767, 600));
}
