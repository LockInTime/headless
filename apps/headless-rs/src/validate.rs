//! Identifier, artifact-name, and bound rules mirroring the Swift core.

use crate::error::ValidationError;

pub const MAX_IDENTIFIER_BYTES: usize = 64;
pub const MAX_ARTIFACT_NAME_BYTES: usize = 128;
pub const MAX_ARTIFACT_PREFIX_BYTES: usize = 80;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BoundRange {
    pub lower: f64,
    pub upper: f64,
}

const fn range(lower: f64, upper: f64) -> BoundRange {
    BoundRange { lower, upper }
}

/// Identical to `ProtocolBounds`.
pub mod protocol_bounds {
    use super::range;
    use super::BoundRange;

    pub const SCROLL_AMOUNT: BoundRange = range(0.1, 100_000.0);
    pub const NETWORK_LATENCY_MILLISECONDS: BoundRange = range(0.0, 120_000.0);
    pub const NETWORK_THROUGHPUT_KBPS: BoundRange = range(-1.0, 1_000_000.0);
    pub const SCREENSHOT_DIMENSION: f64 = 16_384.0;
    pub const SCREENSHOT_PIXELS: f64 = 64_000_000.0;
}

pub fn has_portable_name_characters(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

pub fn validate_identifier(value: &str, field: &str) -> Result<(), ValidationError> {
    if value.is_empty() || value.len() > MAX_IDENTIFIER_BYTES || !has_portable_name_characters(value) {
        return Err(ValidationError::InvalidIdentifier {
            field: field.to_string(),
        });
    }
    Ok(())
}

fn simple_filename(value: &str) -> Option<&str> {
    // Mirror `value == URL(fileURLWithPath: value).lastPathComponent`:
    // reject anything containing a separator, and leading dots.
    if value.is_empty() || value.starts_with('.') || value.contains('/') || value.contains('\\') {
        return None;
    }
    Some(value)
}

pub fn validate_artifact_name(
    value: &str,
    expected_extensions: &[&str],
) -> Result<(), ValidationError> {
    let normalized: Vec<String> = expected_extensions.iter().map(|e| e.to_ascii_lowercase()).collect();
    let description = {
        let mut sorted = normalized.clone();
        sorted.sort();
        sorted
            .iter()
            .map(|e| format!(".{e}"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let invalid = || ValidationError::InvalidParameter(format!(
        "Artifact output must be a simple {description} filename"
    ));

    simple_filename(value).ok_or_else(invalid)?;
    if value.len() > MAX_ARTIFACT_NAME_BYTES {
        return Err(invalid());
    }
    let ext = value.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase());
    match ext {
        Some(e) if normalized.contains(&e) => {}
        _ => return Err(invalid()),
    }
    if !has_portable_name_characters(value) {
        return Err(ValidationError::InvalidParameter(
            "Artifact output contains unsupported characters".to_string(),
        ));
    }
    Ok(())
}

pub fn validate_artifact_prefix(value: &str) -> Result<(), ValidationError> {
    simple_filename(value).ok_or_else(|| {
        ValidationError::InvalidParameter(
            "Artifact prefix must be a simple filename prefix".to_string(),
        )
    })?;
    if value.len() > MAX_ARTIFACT_PREFIX_BYTES {
        return Err(ValidationError::InvalidParameter(
            "Artifact prefix must be a simple filename prefix".to_string(),
        ));
    }
    if !has_portable_name_characters(value) {
        return Err(ValidationError::InvalidParameter(
            "Artifact prefix contains unsupported characters".to_string(),
        ));
    }
    Ok(())
}
