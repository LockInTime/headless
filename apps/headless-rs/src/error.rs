//! Typed errors mirroring `ProtocolValidationError` and the
//! `HostErrorCode` strings from the Swift core.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValidationError {
    UnsupportedVersion(String),
    InvalidRequestID,
    InvalidIdentifier { field: String },
    InvalidUrl(String),
    UnsafeResourceType(String),
    InvalidParameter(String),
}

impl fmt::Display for ValidationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ValidationError::UnsupportedVersion(v) => write!(f, "Unsupported protocol version: {v}"),
            ValidationError::InvalidRequestID => {
                write!(f, "Request ID must contain 1-128 bytes")
            }
            ValidationError::InvalidIdentifier { field } => write!(
                f,
                "Invalid {field}; use letters, numbers, '.', '_' or '-'"
            ),
            ValidationError::InvalidUrl(value) => write!(f, "Unsupported URL: {value}"),
            ValidationError::UnsafeResourceType(ty) => {
                write!(f, "Blocked unsafe remote resource type: .{ty}")
            }
            ValidationError::InvalidParameter(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for ValidationError {}

/// Wire-visible error code strings. Keep byte-identical with the Swift
/// `HostErrorCode` raw values; clients match on these.
pub mod host_error_codes {
    pub const TIMEOUT: &str = "TIMEOUT";
    pub const ELEMENT_NOT_FOUND: &str = "ELEMENT_NOT_FOUND";
    pub const REGION_NOT_FOUND: &str = "REGION_NOT_FOUND";
    pub const UNSAFE_NAVIGATION: &str = "UNSAFE_NAVIGATION";
    pub const UNSAFE_RESOURCE_TYPE: &str = "UNSAFE_RESOURCE_TYPE";
    pub const SENSITIVE_DIAGNOSTICS_DISABLED: &str = "SENSITIVE_DIAGNOSTICS_DISABLED";
    pub const UNSUPPORTED_CAPABILITY: &str = "UNSUPPORTED_CAPABILITY";
    pub const MISSING_PARAMETER: &str = "MISSING_PARAMETER";
    pub const INVALID_FLOW: &str = "INVALID_FLOW";
    pub const FLOW_FAILED: &str = "FLOW_FAILED";
    pub const INVALID_COMMAND: &str = "INVALID_COMMAND";
    pub const OPERATION_FAILED: &str = "OPERATION_FAILED";
}
