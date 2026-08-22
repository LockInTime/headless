//! Wire protocol: command names, requests, responses, and the newline
//! codec with the 1 MiB frame cap. Mirrors `Protocol.swift`.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

use crate::error::ValidationError;
use crate::json::JsonValueAccessors;
use crate::url::normalized_web_url;
use crate::validate::{
    protocol_bounds, validate_artifact_name, validate_artifact_prefix, validate_identifier,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CommandName {
    Ping,
    Shutdown,
    #[serde(rename = "session.create")]
    SessionCreate,
    #[serde(rename = "session.list")]
    SessionList,
    #[serde(rename = "session.close")]
    SessionClose,
    Visit,
    Inspect,
    Click,
    Fill,
    Press,
    Scroll,
    Back,
    Reload,
    Wait,
    Tour,
    #[serde(rename = "capture.info")]
    CaptureInfo,
    Screenshot,
    #[serde(rename = "artifact.list")]
    ArtifactList,
    #[serde(rename = "record.start")]
    RecordStart,
    #[serde(rename = "record.status")]
    RecordStatus,
    #[serde(rename = "record.stop")]
    RecordStop,
    #[serde(rename = "qa.report")]
    QaReport,
    #[serde(rename = "qa.clear")]
    QaClear,
    #[serde(rename = "console.list")]
    ConsoleList,
    #[serde(rename = "network.list")]
    NetworkList,
    #[serde(rename = "network.get")]
    NetworkGet,
    #[serde(rename = "styles.get")]
    StylesGet,
    #[serde(rename = "cookies.list")]
    CookiesList,
    #[serde(rename = "storage.list")]
    StorageList,
    #[serde(rename = "visual.compare")]
    VisualCompare,
    #[serde(rename = "performance.get")]
    PerformanceGet,
    #[serde(rename = "animation.list")]
    AnimationList,
    #[serde(rename = "report.create")]
    ReportCreate,
    #[serde(rename = "flow.start")]
    FlowStart,
    #[serde(rename = "flow.stop")]
    FlowStop,
    #[serde(rename = "flow.run")]
    FlowRun,
    #[serde(rename = "network.emulate")]
    NetworkEmulate,
    #[serde(rename = "network.mock.set")]
    NetworkMockSet,
    #[serde(rename = "network.mock.clear")]
    NetworkMockClear,
}

impl CommandName {
    pub fn as_str(&self) -> &'static str {
        match self {
            CommandName::Ping => "ping",
            CommandName::Shutdown => "shutdown",
            CommandName::SessionCreate => "session.create",
            CommandName::SessionList => "session.list",
            CommandName::SessionClose => "session.close",
            CommandName::Visit => "visit",
            CommandName::Inspect => "inspect",
            CommandName::Click => "click",
            CommandName::Fill => "fill",
            CommandName::Press => "press",
            CommandName::Scroll => "scroll",
            CommandName::Back => "back",
            CommandName::Reload => "reload",
            CommandName::Wait => "wait",
            CommandName::Tour => "tour",
            CommandName::CaptureInfo => "capture.info",
            CommandName::Screenshot => "screenshot",
            CommandName::ArtifactList => "artifact.list",
            CommandName::RecordStart => "record.start",
            CommandName::RecordStatus => "record.status",
            CommandName::RecordStop => "record.stop",
            CommandName::QaReport => "qa.report",
            CommandName::QaClear => "qa.clear",
            CommandName::ConsoleList => "console.list",
            CommandName::NetworkList => "network.list",
            CommandName::NetworkGet => "network.get",
            CommandName::StylesGet => "styles.get",
            CommandName::CookiesList => "cookies.list",
            CommandName::StorageList => "storage.list",
            CommandName::VisualCompare => "visual.compare",
            CommandName::PerformanceGet => "performance.get",
            CommandName::AnimationList => "animation.list",
            CommandName::ReportCreate => "report.create",
            CommandName::FlowStart => "flow.start",
            CommandName::FlowStop => "flow.stop",
            CommandName::FlowRun => "flow.run",
            CommandName::NetworkEmulate => "network.emulate",
            CommandName::NetworkMockSet => "network.mock.set",
            CommandName::NetworkMockClear => "network.mock.clear",
        }
    }
}

pub const UNKNOWN_REQUEST_IDENTIFIER: &str = "unknown";

/// Fail closed on unknown fields, mirroring the Swift decoder that rejects
/// anything outside `id`, `version`, `command`, `session`, `parameters`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommandRequest {
    pub id: String,
    pub version: String,
    pub command: CommandName,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub session: Option<String>,
    #[serde(default)]
    pub parameters: BTreeMap<String, Value>,
}

impl CommandRequest {
    pub fn new(command: CommandName) -> Self {
        Self {
            id: new_request_id(),
            version: crate::HEADLESS_PROTOCOL_VERSION.to_string(),
            command,
            session: None,
            parameters: BTreeMap::new(),
        }
    }

    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.version != crate::HEADLESS_PROTOCOL_VERSION {
            return Err(ValidationError::UnsupportedVersion(self.version.clone()));
        }
        if self.id.is_empty() || self.id.len() > 128 {
            return Err(ValidationError::InvalidRequestID);
        }
        if let Some(session) = &self.session {
            validate_identifier(session, "session")?;
        }
        self.validate_command_parameters()
    }

    fn parameter(&self, key: &str) -> Option<&Value> {
        self.parameters.get(key)
    }

    fn allow(&self, keys: &[&str]) -> Result<(), ValidationError> {
        if let Some(unexpected) = self.parameters.keys().find(|k| !keys.contains(&k.as_str())) {
            return Err(ValidationError::InvalidParameter(format!(
                "Unexpected parameter for {}: {unexpected}",
                self.command.as_str()
            )));
        }
        Ok(())
    }

    fn string(
        &self,
        key: &str,
        required: bool,
        maximum_bytes: usize,
    ) -> Result<Option<String>, ValidationError> {
        let invalid = || ValidationError::InvalidParameter(format!("Invalid string parameter: {key}"));
        match self.parameter(key) {
            None => {
                if required {
                    return Err(ValidationError::InvalidParameter(format!(
                        "Missing string parameter: {key}"
                    )));
                }
                Ok(None)
            }
            Some(value) => {
                let text = value.string_value().ok_or_else(invalid)?;
                if (required && text.is_empty()) || text.len() > maximum_bytes {
                    return Err(invalid());
                }
                Ok(Some(text.to_string()))
            }
        }
    }

    fn number(&self, key: &str, minimum: f64, maximum: f64) -> Result<Option<f64>, ValidationError> {
        let invalid =
            || ValidationError::InvalidParameter(format!("Invalid numeric parameter: {key}"));
        match self.parameter(key) {
            None => Ok(None),
            Some(value) => {
                let number = value.number_value().ok_or_else(invalid)?;
                if !number.is_finite() || number < minimum || number > maximum {
                    return Err(invalid());
                }
                Ok(Some(number))
            }
        }
    }

    fn boolean(&self, key: &str) -> Result<(), ValidationError> {
        if let Some(value) = self.parameter(key) {
            if value.bool_value().is_none() {
                return Err(ValidationError::InvalidParameter(format!(
                    "Invalid boolean parameter: {key}"
                )));
            }
        }
        Ok(())
    }

    fn strings(
        &self,
        key: &str,
        maximum_items: usize,
        maximum_bytes: usize,
    ) -> Result<(), ValidationError> {
        let invalid =
            || ValidationError::InvalidParameter(format!("Invalid string array parameter: {key}"));
        let values = match self.parameter(key) {
            None => return Ok(()),
            Some(value) => value.as_array().ok_or_else(invalid)?,
        };
        if values.len() > maximum_items
            || !values.iter().all(|v| {
                v.as_str()
                    .map(|s| !s.is_empty() && s.len() <= maximum_bytes)
                    .unwrap_or(false)
            })
        {
            return Err(invalid());
        }
        Ok(())
    }

    /// Element targeting shared by click / fill / styles / screenshot.
    fn target(
        &self,
        allow_value: bool,
        required: bool,
        check_keys: bool,
    ) -> Result<(), ValidationError> {
        let allowed: &[&str] = if allow_value {
            &["target", "role", "name", "value"]
        } else {
            &["target", "role", "name"]
        };
        if check_keys {
            self.allow(allowed)?;
        }
        let reference = self.string("target", false, 16)?;
        let role = self.string("role", false, 128)?;
        let name = self.string("name", false, 1_000)?;
        if let Some(reference) = reference {
            let digits = reference.strip_prefix("@e").map(|rest| {
                !rest.is_empty() && rest.bytes().all(|b| b.is_ascii_digit())
            });
            if role.is_some() || name.is_some() || digits != Some(true) {
                return Err(ValidationError::InvalidParameter(
                    "Invalid or conflicting element target".to_string(),
                ));
            }
        } else if required && role.is_none() && name.is_none() {
            return Err(ValidationError::InvalidParameter(
                "Missing element target".to_string(),
            ));
        }
        if allow_value {
            self.string("value", true, 900_000)?;
        }
        Ok(())
    }

    fn validate_command_parameters(&self) -> Result<(), ValidationError> {
        use CommandName::*;
        match self.command {
            Ping | Shutdown | SessionList | SessionClose | Back | Reload | CaptureInfo
            | ArtifactList | RecordStatus | QaReport | QaClear => self.allow(&[]),
            SessionCreate => {
                self.allow(&["name"])?;
                if let Some(name) = self.string("name", true, 64)? {
                    validate_identifier(&name, "session")?;
                }
                Ok(())
            }
            Visit => {
                self.allow(&["url"])?;
                if let Some(value) = self.string("url", true, 8_192)? {
                    normalized_web_url(&value)?;
                }
                Ok(())
            }
            Inspect => {
                self.allow(&["interactive", "text", "context", "task", "within", "limit", "budget", "depth"])?;
                self.boolean("interactive")?;
                self.boolean("text")?;
                if let Some(context) = self.string("context", false, 16)? {
                    if !["summary", "outline", "text", "actions", "full"].contains(&context.as_str()) {
                        return Err(ValidationError::InvalidParameter(
                            "Invalid inspect context".to_string(),
                        ));
                    }
                }
                self.string("task", false, 512)?;
                if let Some(within) = self.string("within", false, 16)? {
                    let digits = within.strip_prefix("@r").map(|rest| {
                        !rest.is_empty() && rest.bytes().all(|b| b.is_ascii_digit())
                    });
                    if digits != Some(true) {
                        return Err(ValidationError::InvalidParameter(
                            "Invalid inspect region reference".to_string(),
                        ));
                    }
                }
                for (key, minimum, maximum) in
                    [("limit", 1.0, 250.0), ("budget", 256.0, 16_000.0), ("depth", 0.0, 8.0)]
                {
                    if let Some(value) = self.number(key, minimum, maximum)? {
                        if value.round() != value {
                            return Err(ValidationError::InvalidParameter(format!(
                                "Invalid integer parameter: {key}"
                            )));
                        }
                    }
                }
                Ok(())
            }
            Click => self.target(false, true, true),
            Fill => self.target(true, true, true),
            Press => {
                self.allow(&["key"])?;
                self.string("key", true, 32)?;
                Ok(())
            }
            Scroll => {
                self.allow(&["direction", "amount"])?;
                let direction = self.string("direction", false, 8_192)?.unwrap_or_else(|| "down".to_string());
                if !["up", "down", "top", "bottom"].contains(&direction.as_str()) {
                    return Err(ValidationError::InvalidParameter(
                        "Invalid scroll direction".to_string(),
                    ));
                }
                self.number(
                    "amount",
                    protocol_bounds::SCROLL_AMOUNT.lower,
                    protocol_bounds::SCROLL_AMOUNT.upper,
                )?;
                Ok(())
            }
            Wait => {
                self.allow(&["settled", "url", "text", "timeoutMs"])?;
                self.boolean("settled")?;
                self.string("url", false, 8_192)?;
                self.string("text", false, 30_000)?;
                self.number("timeoutMs", 100.0, 120_000.0)?;
                Ok(())
            }
            Tour => {
                self.allow(&["fullPage", "pace"])?;
                self.boolean("fullPage")?;
                self.number("pace", 100.0, 5_000.0)?;
                Ok(())
            }
            Screenshot => self.validate_screenshot(),
            RecordStart => {
                self.allow(&["output", "fps", "format", "quality"])?;
                let format = recording_format(
                    self.string("format", false, 16)?.as_deref(),
                    self.parameter("output").and_then(|v| v.string_value()),
                )?;
                if let Some(output) = self.string("output", false, 128)? {
                    validate_artifact_name(&output, &[format])?;
                }
                self.number("fps", 1.0, 30.0)?;
                if let Some(quality) = self.string("quality", false, 16)? {
                    if parse_recording_quality(&quality).is_err() {
                        return Err(ValidationError::InvalidParameter(format!(
                            "Unsupported recording quality: {quality}"
                        )));
                    }
                }
                Ok(())
            }
            RecordStop => {
                self.allow(&["output"])?;
                if let Some(output) = self.string("output", false, 128)? {
                    validate_artifact_name(&output, RECORDING_FORMAT_EXTENSIONS)?;
                }
                Ok(())
            }
            ConsoleList => {
                self.allow(&["level", "limit"])?;
                if let Some(level) = self.string("level", false, 16)? {
                    if !["all", "log", "info", "debug", "warn", "error", "assert"]
                        .contains(&level.as_str())
                    {
                        return Err(ValidationError::InvalidParameter(
                            "Invalid console level".to_string(),
                        ));
                    }
                }
                self.number("limit", 1.0, 200.0)?;
                Ok(())
            }
            NetworkList => {
                self.allow(&["failed", "status", "limit"])?;
                self.boolean("failed")?;
                self.number("status", 100.0, 599.0)?;
                self.number("limit", 1.0, 200.0)?;
                Ok(())
            }
            NetworkGet => {
                self.allow(&["requestId"])?;
                self.string("requestId", true, 128)?;
                Ok(())
            }
            StylesGet => {
                self.allow(&["target", "role", "name", "properties"])?;
                self.target(false, true, false)?;
                self.strings("properties", 64, 128)?;
                Ok(())
            }
            CookiesList => {
                self.allow(&["includeValues"])?;
                self.boolean("includeValues")
            }
            StorageList => {
                self.allow(&["scope", "includeValues"])?;
                let scope = self.string("scope", false, 16)?.unwrap_or_else(|| "all".to_string());
                if !["local", "session", "all"].contains(&scope.as_str()) {
                    return Err(ValidationError::InvalidParameter(
                        "Invalid storage scope".to_string(),
                    ));
                }
                self.boolean("includeValues")
            }
            VisualCompare => {
                self.allow(&["before", "after", "output"])?;
                for key in ["before", "after"] {
                    if let Some(name) = self.string(key, true, 128)? {
                        validate_artifact_name(&name, &["png"])?;
                    }
                }
                if let Some(output) = self.string("output", false, 128)? {
                    validate_artifact_name(&output, &["png"])?;
                }
                Ok(())
            }
            PerformanceGet | AnimationList => self.allow(&[]),
            ReportCreate => {
                self.allow(&["output"])?;
                if let Some(output) = self.string("output", false, 128)? {
                    validate_artifact_name(&output, &["json"])?;
                }
                Ok(())
            }
            FlowStart => self.allow(&[]),
            FlowStop => {
                self.allow(&["output"])?;
                if let Some(output) = self.string("output", false, 128)? {
                    validate_artifact_name(&output, &["json"])?;
                }
                Ok(())
            }
            FlowRun => {
                self.allow(&["input"])?;
                if let Some(input) = self.string("input", true, 128)? {
                    validate_artifact_name(&input, &["json"])?;
                }
                Ok(())
            }
            NetworkEmulate => {
                self.allow(&["offline", "latencyMs", "downloadKbps", "uploadKbps"])?;
                self.boolean("offline")?;
                self.number(
                    "latencyMs",
                    protocol_bounds::NETWORK_LATENCY_MILLISECONDS.lower,
                    protocol_bounds::NETWORK_LATENCY_MILLISECONDS.upper,
                )?;
                self.number(
                    "downloadKbps",
                    protocol_bounds::NETWORK_THROUGHPUT_KBPS.lower,
                    protocol_bounds::NETWORK_THROUGHPUT_KBPS.upper,
                )?;
                self.number(
                    "uploadKbps",
                    protocol_bounds::NETWORK_THROUGHPUT_KBPS.lower,
                    protocol_bounds::NETWORK_THROUGHPUT_KBPS.upper,
                )?;
                Ok(())
            }
            NetworkMockSet => {
                self.allow(&["url", "status", "body", "contentType"])?;
                if let Some(url) = self.string("url", true, 8_192)? {
                    normalized_web_url(&url)?;
                }
                self.number("status", 100.0, 599.0)?;
                self.string("body", true, 65_536)?;
                if let Some(content_type) = self.string("contentType", false, 256)? {
                    if !content_type.bytes().all(|b| (0x20..=0x7e).contains(&b)) {
                        return Err(ValidationError::InvalidParameter(
                            "Invalid content type".to_string(),
                        ));
                    }
                }
                Ok(())
            }
            NetworkMockClear => self.allow(&[]),
        }
    }

    fn validate_screenshot(&self) -> Result<(), ValidationError> {
        self.allow(&[
            "fullPage", "target", "role", "name", "output", "series", "outputPrefix", "format",
            "clipboard",
        ])?;
        self.boolean("fullPage")?;
        self.boolean("clipboard")?;
        self.target(false, false, false)?;
        let has_target =
            self.parameter("target").is_some() || self.parameter("role").is_some() || self.parameter("name").is_some();
        let series = self.string("series", false, 32)?;
        if let Some(series) = &series {
            if !["viewport", "section"].contains(&series.as_str()) {
                return Err(ValidationError::InvalidParameter(
                    "Invalid screenshot series".to_string(),
                ));
            }
        }
        let format = screenshot_format(
            self.string("format", false, 16)?.as_deref(),
            self.parameter("output").and_then(|v| v.string_value()),
        )?;
        if series.is_some() && format == "pdf" {
            return Err(ValidationError::InvalidParameter(
                "PDF is only supported for single screenshots".to_string(),
            ));
        }
        if series.is_some() && self.parameter("clipboard").and_then(|v| v.bool_value()) == Some(true) {
            return Err(ValidationError::InvalidParameter(
                "Clipboard output is only supported for single screenshots".to_string(),
            ));
        }
        if format == "pdf" && self.parameter("clipboard").and_then(|v| v.bool_value()) == Some(true) {
            return Err(ValidationError::InvalidParameter(
                "Clipboard output is only supported for image screenshots".to_string(),
            ));
        }
        if format == "pdf"
            && (self.parameter("fullPage").and_then(|v| v.bool_value()) != Some(true) || has_target)
        {
            return Err(ValidationError::InvalidParameter(
                "PDF screenshots require fullPage without an element target".to_string(),
            ));
        }
        if series.is_some()
            && (self.parameter("fullPage").and_then(|v| v.bool_value()) == Some(true)
                || has_target
                || self.parameter("output").is_some())
        {
            return Err(ValidationError::InvalidParameter(
                "Use screenshot series without --full-page, output file, or element target"
                    .to_string(),
            ));
        }
        if self.parameter("fullPage").and_then(|v| v.bool_value()) == Some(true) && has_target {
            return Err(ValidationError::InvalidParameter(
                "Use either --full-page or an element target".to_string(),
            ));
        }
        if let Some(output) = self.string("output", false, 128)? {
            let extensions = SCREENSHOT_FORMAT_EXTENSIONS
                .iter()
                .find(|(f, _)| *f == format)
                .map(|(_, e)| *e)
                .unwrap_or(&["png"]);
            validate_artifact_name(&output, extensions)?;
        }
        if let Some(prefix) = self.string("outputPrefix", false, 80)? {
            if series.is_none() {
                return Err(ValidationError::InvalidParameter(
                    "Screenshot outputPrefix requires a screenshot series".to_string(),
                ));
            }
            validate_artifact_prefix(&prefix)?;
        }
        Ok(())
    }
}

const RECORDING_FORMAT_EXTENSIONS: &[&str] = &["mp4", "mov", "webm", "gif"];

const SCREENSHOT_FORMAT_EXTENSIONS: &[(&str, &[&str])] = &[
    ("png", &["png"]),
    ("jpg", &["jpg", "jpeg"]),
    ("pdf", &["pdf"]),
];

fn screenshot_format(explicit: Option<&str>, output: Option<&str>) -> Result<String, ValidationError> {
    fn parse(value: &str) -> Result<String, ValidationError> {
        match value.to_ascii_lowercase().as_str() {
            "png" => Ok("png".to_string()),
            "jpg" | "jpeg" => Ok("jpg".to_string()),
            "pdf" => Ok("pdf".to_string()),
            other => Err(ValidationError::InvalidParameter(format!(
                "Unsupported screenshot format: {other}"
            ))),
        }
    }
    if let Some(explicit) = explicit {
        return parse(explicit);
    }
    if let Some(output) = output {
        if let Some((_, ext)) = output.rsplit_once('.') {
            if !ext.is_empty() {
                return parse(ext);
            }
        }
    }
    Ok("png".to_string())
}

fn recording_format(explicit: Option<&str>, output: Option<&str>) -> Result<&'static str, ValidationError> {
    fn parse(value: &str) -> Result<&'static str, ValidationError> {
        match value.to_ascii_lowercase().as_str() {
            "mp4" => Ok("mp4"),
            "mov" => Ok("mov"),
            "webm" => Ok("webm"),
            "gif" => Ok("gif"),
            other => Err(ValidationError::InvalidParameter(format!(
                "Unsupported recording format: {other}"
            ))),
        }
    }
    if let Some(explicit) = explicit {
        return parse(explicit);
    }
    if let Some(output) = output {
        if let Some((_, ext)) = output.rsplit_once('.') {
            if !ext.is_empty() {
                return parse(ext);
            }
        }
    }
    Ok("mp4")
}

fn parse_recording_quality(value: &str) -> Result<(), ()> {
    match value.to_ascii_lowercase().as_str() {
        "fast" | "balanced" | "high" => Ok(()),
        _ => Err(()),
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CommandError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub suggestion: Option<String>,
}

/// Fail closed on unknown fields, mirroring `CommandResponse` decoding.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommandResponse {
    pub id: String,
    pub version: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub error: Option<CommandError>,
}

impl CommandResponse {
    pub fn success(id: &str, result: Option<Value>) -> Self {
        CommandResponse {
            id: id.to_string(),
            version: crate::HEADLESS_PROTOCOL_VERSION.to_string(),
            ok: true,
            result: Some(result.unwrap_or(Value::Object(Map::new()))),
            error: None,
        }
    }

    pub fn failure(id: &str, code: &str, message: &str, suggestion: Option<&str>) -> Self {
        CommandResponse {
            id: id.to_string(),
            version: crate::HEADLESS_PROTOCOL_VERSION.to_string(),
            ok: false,
            result: None,
            error: Some(CommandError {
                code: code.to_string(),
                message: message.to_string(),
                suggestion: suggestion.map(|s| s.to_string()),
            }),
        }
    }
}

pub mod codec {
    use super::*;
    use crate::error::ValidationError;

    /// Encode as one JSON line (newline appended), enforcing the frame cap.
    pub fn encode_line<T: Serialize>(value: &T) -> Result<Vec<u8>, ValidationError> {
        let mut data = serde_json::to_vec(value)
            .map_err(|e| ValidationError::InvalidParameter(format!("encode error: {e}")))?;
        data.push(b'\n');
        if data.len() > crate::HEADLESS_MAXIMUM_MESSAGE_BYTES {
            return Err(ValidationError::InvalidParameter("message too large".to_string()));
        }
        Ok(data)
    }

    /// Decode one JSON line (trailing newline optional), enforcing the cap.
    pub fn decode_line<T: serde::de::DeserializeOwned>(data: &[u8]) -> Result<T, ValidationError> {
        if data.len() > crate::HEADLESS_MAXIMUM_MESSAGE_BYTES {
            return Err(ValidationError::InvalidParameter("message too large".to_string()));
        }
        let line = if data.last() == Some(&b'\n') { &data[..data.len() - 1] } else { data };
        serde_json::from_slice(line)
            .map_err(|e| ValidationError::InvalidParameter(format!("decode error: {e}")))
    }
}

fn new_request_id() -> String {
    // Deterministic fallback; callers can substitute a UUID. Kept dependency-
    // free here by using a timestamp+counter style identifier only when the
    // uuid feature is unavailable.
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("req-{now:x}-{count:x}")
}

/// Convenience constructor used by tests to build requests like the Swift
/// initializer does.
pub fn request_with_id(
    id: &str,
    command: CommandName,
    session: Option<&str>,
    parameters: BTreeMap<String, Value>,
) -> CommandRequest {
    CommandRequest {
        id: id.to_string(),
        version: crate::HEADLESS_PROTOCOL_VERSION.to_string(),
        command,
        session: session.map(|s| s.to_string()),
        parameters,
    }
}
