/// HTTP status code constants and utilities.
/// Centralizes HTTP status checking to avoid magic numbers throughout the codebase.
/// 2xx Success
pub const ok = 200;
pub const created = 201;
pub const no_content = 204;

/// 3xx Redirection
pub const moved_permanently = 301;
pub const found = 302;
pub const see_other = 303;
pub const not_modified = 304;
pub const temporary_redirect = 307;
pub const permanent_redirect = 308;

/// 4xx Client Error
pub const bad_request = 400;
pub const unauthorized = 401;
pub const forbidden = 403;
pub const not_found = 404;
pub const request_timeout = 408;

/// 5xx Server Error
pub const internal_server_error = 500;
pub const bad_gateway = 502;
pub const service_unavailable = 503;

/// Check if a status code indicates success (2xx).
pub fn isSuccess(code: u16) bool {
    return code >= 200 and code < 300;
}

/// Check if a status code indicates a redirect (3xx).
pub fn isRedirect(code: u16) bool {
    return code >= 300 and code < 400;
}

/// Check if a status code indicates a client error (4xx).
pub fn isClientError(code: u16) bool {
    return code >= 400 and code < 500;
}

/// Check if a status code indicates a server error (5xx).
pub fn isServerError(code: u16) bool {
    return code >= 500 and code < 600;
}
