//! Minimal URL model covering exactly what the validation boundary needs:
//! scheme, host, userinfo presence, and path extension. It is deliberately
//! conservative: anything it cannot parse cleanly is rejected upstream.

use crate::error::ValidationError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Url {
    pub scheme: String,
    pub host: Option<String>,
    pub has_userinfo: bool,
    pub path: String,
}

impl Url {
    /// Parse an absolute URL of the form `scheme://[user[:pass]@]host[:port][/path][?query][#fragment]`.
    /// Returns `None` for anything malformed, empty-hosted, or containing
    /// whitespace/control characters.
    pub fn parse(input: &str) -> Option<Url> {
        let (scheme, rest) = input.split_once("://")?;
        if scheme.is_empty() || !scheme.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'-' || b == b'.') {
            return None;
        }
        if input.bytes().any(|b| b <= 0x20 || b == 0x7f) {
            return None;
        }

        // authority runs until the first '/', '?', or '#'
        let after_authority = rest.find(|c| c == '/' || c == '?' || c == '#');
        let (authority, tail) = match after_authority {
            Some(i) => (&rest[..i], &rest[i..]),
            None => (rest, ""),
        };
        if authority.is_empty() {
            return None;
        }

        let (has_userinfo, host_port) = match authority.rfind('@') {
            Some(i) => (true, &authority[i + 1..]),
            None => (false, authority),
        };
        let host = strip_ipv6_brackets(host_port)?;
        if host.is_empty() {
            return None;
        }

        let path = match tail.find(['?', '#']) {
            Some(i) => &tail[..i],
            None => tail,
        };
        let path = if path.is_empty() { "/" } else { path };

        Some(Url {
            scheme: scheme.to_ascii_lowercase(),
            host: Some(host.to_ascii_lowercase()),
            has_userinfo,
            path: path.to_string(),
        })
    }

    pub fn path_extension(&self) -> Option<String> {
        let last = self.path.rsplit('/').next()?;
        let ext = last.rsplit_once('.')?.1;
        if ext.is_empty() {
            None
        } else {
            Some(ext.to_ascii_lowercase())
        }
    }
}

fn strip_ipv6_brackets(host_port: &str) -> Option<&str> {
    if let Some(rest) = host_port.strip_prefix('[') {
        let end = rest.find(']')?;
        return Some(&rest[..end]);
    }
    // otherwise cut an optional :port (but keep ::1-style bare IPv6 whole)
    match host_port.split_once(':') {
        Some((host, port)) => {
            if host.is_empty() && !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) {
                Some(host_port)
            } else if port.bytes().all(|b| b.is_ascii_digit()) {
                Some(host)
            } else {
                Some(host_port)
            }
        }
        None => Some(host_port),
    }
}

/// Swift's `URL(string:)` + `isWebNavigationURL`: http/https only, a host
/// must exist, and embedded credentials are rejected outright.
pub fn is_web_navigation_url(url: &Url) -> bool {
    matches!(url.scheme.as_str(), "http" | "https")
        && url.host.as_deref().map(|h| !h.is_empty()).unwrap_or(false)
        && !url.has_userinfo
}

pub fn normalized_web_url(input: &str) -> Result<Url, ValidationError> {
    let trimmed = input.trim();
    if trimmed.is_empty() || trimmed.len() > 8_192 {
        return Err(ValidationError::InvalidUrl(input.to_string()));
    }

    let lower = trimmed.to_ascii_lowercase();
    let candidate: String;
    if lower.starts_with("http://") || lower.starts_with("https://") {
        candidate = trimmed.to_string();
    } else if trimmed.contains("://") {
        return Err(ValidationError::InvalidUrl(input.to_string()));
    } else if is_local_development_address(trimmed) {
        candidate = format!("http://{trimmed}");
    } else {
        // Reject explicit non-web schemes such as javascript:, data:, and
        // mailto:. A colon followed by digits is retained as a normal port.
        if let Some((_, suffix)) = trimmed.split_once(':') {
            if !suffix.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false) {
                return Err(ValidationError::InvalidUrl(input.to_string()));
            }
        }
        candidate = format!("https://{trimmed}");
    }

    let url = Url::parse(&candidate).ok_or_else(|| ValidationError::InvalidUrl(input.to_string()))?;
    if !is_web_navigation_url(&url) {
        return Err(ValidationError::InvalidUrl(input.to_string()));
    }
    if remote_resource_safety(&url) == ResourceSafety::Blocked {
        return Err(ValidationError::UnsafeResourceType(
            url.path_extension().unwrap_or_default(),
        ));
    }
    Ok(url)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResourceSafety {
    Allowed,
    Caution,
    Blocked,
}

/// The agent is a browser controller, not an installer delivery mechanism.
pub const BLOCKED_REMOTE_RESOURCE_EXTENSIONS: &[&str] = &[
    "apk", "app", "bat", "cmd", "com", "deb", "dll", "dmg", "dylib", "exe",
    "img", "iso", "jar", "msi", "msp", "pif", "pkg", "ps1", "psm1", "scr",
    "sh", "so", "vbe", "vbs", "wsf", "zsh",
];

pub const CAUTION_REMOTE_RESOURCE_EXTENSIONS: &[&str] =
    &["7z", "bz2", "gz", "rar", "rpm", "tar", "tgz", "xz", "zip"];

pub fn remote_resource_safety(url: &Url) -> ResourceSafety {
    let extension = url.path_extension().unwrap_or_default();
    if BLOCKED_REMOTE_RESOURCE_EXTENSIONS.contains(&extension.as_str()) {
        ResourceSafety::Blocked
    } else if CAUTION_REMOTE_RESOURCE_EXTENSIONS.contains(&extension.as_str()) {
        ResourceSafety::Caution
    } else {
        ResourceSafety::Allowed
    }
}

/// The same boundary applies to explicit CLI visits and page-initiated
/// top-frame navigation.
pub fn agent_may_navigate(url: &Url) -> bool {
    is_web_navigation_url(url) && remote_resource_safety(url) != ResourceSafety::Blocked
}

pub const LOCAL_DEVELOPMENT_HOSTS: &[&str] = &["localhost", "127.0.0.1", "0.0.0.0", "::1"];

pub fn is_local_development_host(host: &str) -> bool {
    LOCAL_DEVELOPMENT_HOSTS.contains(&host.to_ascii_lowercase().as_str())
}

pub fn is_local_development_address(input: &str) -> bool {
    let trimmed = input.trim();
    // Mirror the Swift check: parse as a "//host[:port]/path" authority and
    // compare only the host part.
    let authority = match trimmed.find(['/', '?', '#']) {
        Some(i) => &trimmed[..i],
        None => trimmed,
    };
    let host_port = match authority.rfind('@') {
        Some(i) => &authority[i + 1..],
        None => authority,
    };
    let host = match strip_ipv6_brackets(host_port) {
        Some(h) => h,
        None => return false,
    };
    is_local_development_host(host)
}
