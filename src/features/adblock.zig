const std = @import("std");

/// List of common ad/tracking domains to block.
const blocked_domains = [_][]const u8{
    "doubleclick.net",
    "googlesyndication.com",
    "googleadservices.com",
    "google-analytics.com",
    "analytics.google.com",
    "adnxs.com",
    "facebook.net/tr",
    "pixel.facebook.com",
    "connect.facebook.net",
    "ads.twitter.com",
    "analytics.twitter.com",
    "ad.doubleclick.net",
    "pagead2.googlesyndication.com",
    "securepubads.g.doubleclick.net",
    "adservice.google.com",
    "moatads.com",
    "amazon-adsystem.com",
    "advertising.com",
    "outbrain.com",
    "taboola.com",
    "criteo.com",
    "scorecardresearch.com",
    "quantserve.com",
    "bluekai.com",
    "krxd.net",
    "rubiconproject.com",
    "pubmatic.com",
    "openx.net",
    "casalemedia.com",
    "adsrvr.org",
};

/// Check if a URL should be blocked by the ad blocker.
/// Returns true if the URL matches any blocked domain pattern.
pub fn shouldBlock(url: []const u8) bool {
    for (blocked_domains) |domain| {
        if (containsDomain(url, domain)) return true;
    }
    return false;
}

/// Check if a URL contains a domain pattern.
/// Handles cases like "https://ads.example.com/path" matching "example.com".
fn containsDomain(url: []const u8, domain: []const u8) bool {
    // Find the host portion of the URL (after :// and before next /)
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |idx|
        url[idx + 3 ..]
    else
        url;

    // Get just the host part (before any /)
    const host_end = std.mem.indexOf(u8, after_scheme, "/") orelse after_scheme.len;
    const host_and_path = after_scheme[0..@min(host_end + domain.len, after_scheme.len)];

    // Check if the domain appears in the host+beginning of path area
    // This handles patterns like "facebook.net/tr"
    if (std.mem.indexOf(u8, host_and_path, domain)) |pos| {
        // Make sure it's at a domain boundary (start, or preceded by '.' or '/')
        if (pos == 0) return true;
        const prev = host_and_path[pos - 1];
        if (prev == '.' or prev == '/' or prev == '@') return true;
    }

    return false;
}

/// Tracking/analytics script URL patterns to skip for memory savings.
/// These scripts don't affect page content rendering.
const tracking_patterns = [_][]const u8{
    "analytics",
    "hubspot",
    "googletagmanager",
    "google-analytics",
    "onetrust",
    "segment.com",
    "segment.io",
    "hotjar",
    "sentry.io",
    "datadog",
    "newrelic",
    "intellimize",
    "optimizely",
    "crazyegg",
    "mouseflow",
    "gtm.js",
    "gtag/js",
    "clarity.ms",
    "plausible.io",
    "matomo",
};

/// Check if a script URL is for tracking/analytics and can be skipped.
pub fn isTrackingScript(url: []const u8) bool {
    for (tracking_patterns) |pattern| {
        if (std.mem.indexOf(u8, url, pattern) != null) return true;
    }
    return false;
}

/// Get the count of blocked domains.
pub fn blockedDomainCount() usize {
    return blocked_domains.len;
}
