//! Tests mirroring the security-critical cases from the Swift protocol
//! suite (`Tests/HeadlessProtocolTests/ProtocolTests.swift`).

use std::collections::BTreeMap;

use headless_protocol::error::{host_error_codes, ValidationError};
use headless_protocol::protocol::{
    codec, request_with_id, CommandName, CommandRequest, CommandResponse,
};
use headless_protocol::url::{agent_may_navigate, normalized_web_url, Url};
use headless_protocol::validate::{
    has_portable_name_characters, validate_artifact_name, validate_artifact_prefix,
    validate_identifier,
};

fn params(pairs: &[(&str, serde_json::Value)]) -> BTreeMap<String, serde_json::Value> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.clone()))
        .collect()
}

fn valid_request(command: CommandName, parameters: BTreeMap<String, serde_json::Value>) -> CommandRequest {
    request_with_id("request-1", command, Some("qa"), parameters)
}

#[test]
fn request_round_trip() {
    let request = request_with_id(
        "request-1",
        CommandName::Visit,
        Some("qa"),
        params(&[("url", serde_json::json!("http://localhost:3000/dashboard"))]),
    );
    let data = codec::encode_line(&request).unwrap();
    let decoded: CommandRequest = codec::decode_line(&data).unwrap();
    assert_eq!(decoded, request);
}

#[test]
fn rejects_unexpected_request_fields() {
    // The Swift decoder fails closed on any field outside id/version/
    // command/session/parameters.
    let raw = br#"{"id":"a","version":"0.5","command":"ping","extra":1}"#;
    let result: Result<CommandRequest, _> = codec::decode_line(raw);
    assert!(result.is_err(), "unknown request field must be rejected");
}

#[test]
fn rejects_unsafe_navigation_schemes() {
    for value in [
        "file:///etc/passwd",
        "javascript:alert(1)",
        "mailto:test@example.com",
        "https://user:password@example.com/private",
        "data:text/html,unsafe",
    ] {
        assert!(
            normalized_web_url(value).is_err(),
            "expected {value} to be rejected"
        );
    }
}

#[test]
fn normalizes_localhost_to_http() {
    let url = normalized_web_url("localhost:3000/designers/dashboard").unwrap();
    assert_eq!(url.scheme, "http");
    assert_eq!(url.host.as_deref(), Some("localhost"));

    // A localhost-looking public hostname must not be downgraded to HTTP.
    let url = normalized_web_url("localhost.evil.example/path").unwrap();
    assert_eq!(url.scheme, "https");
}

#[test]
fn page_navigation_boundary() {
    let ok = Url::parse("https://example.com/dashboard").unwrap();
    assert!(agent_may_navigate(&ok), "ordinary HTTPS should be allowed");

    let credentialed = Url::parse("https://user:secret@example.com/private").unwrap();
    assert!(!agent_may_navigate(&credentialed));

    let payload = Url::parse("https://example.com/payload.exe").unwrap();
    assert!(!agent_may_navigate(&payload), "active payloads are blocked");

    let archive = Url::parse("https://example.com/bundle.zip").unwrap();
    assert!(agent_may_navigate(&archive), "archives are caution-only, allowed");

    let no_host = Url::parse("http:///etc/passwd");
    assert!(no_host.map(|u| !agent_may_navigate(&u)).unwrap_or(true));
}

#[test]
fn message_size_limit() {
    // A line over the 1 MiB cap must be rejected at the decode boundary.
    let big = "x".repeat(headless_protocol::HEADLESS_MAXIMUM_MESSAGE_BYTES);
    let mut oversized = Vec::new();
    oversized.extend_from_slice(big.as_bytes());
    oversized.push(b'\n');
    let result: Result<CommandRequest, _> = codec::decode_line(&oversized);
    assert!(result.is_err(), "oversized frame must be rejected");

    // And a well-formed frame still decodes.
    let request = valid_request(CommandName::Ping, params(&[]));
    let encoded = codec::encode_line(&request).unwrap();
    assert!(encoded.len() < headless_protocol::HEADLESS_MAXIMUM_MESSAGE_BYTES);
    let decoded: CommandRequest = codec::decode_line(&encoded).unwrap();
    assert_eq!(decoded, request);
}

#[test]
fn identifier_validation() {
    for value in ["qa", "qa.session", "qa_session", "qa-session", "QA1"] {
        validate_identifier(value, "session").expect(value);
    }
    for value in ["", "qa session", "qa/session", "über", "qa#1"] {
        assert!(validate_identifier(value, "session").is_err(), "{value}");
    }
    assert!(has_portable_name_characters("report-1.json"));
}

#[test]
fn artifact_name_validation() {
    validate_artifact_name("dashboard.png", &["png"]).unwrap();
    validate_artifact_name("capture.MP4", &["mp4"]).unwrap();
    assert!(validate_artifact_name("../escape.png", &["png"]).is_err());
    assert!(validate_artifact_name(".hidden.png", &["png"]).is_err());
    assert!(validate_artifact_name("wrong.gif", &["png"]).is_err());
    assert!(validate_artifact_name("", &["png"]).is_err());
    validate_artifact_prefix("dashboard-scroll").unwrap();
    assert!(validate_artifact_prefix("../escape").is_err());
}

#[test]
fn command_parameter_validation() {
    use serde_json::json;

    // ping with unexpected parameter
    let request = valid_request(CommandName::Ping, params(&[("url", json!("http://x"))]));
    assert!(matches!(
        request.validate(),
        Err(ValidationError::InvalidParameter(_))
    ));

    // visit with unsafe URL
    let request = valid_request(CommandName::Visit, params(&[("url", json!("javascript:alert(1)"))]));
    assert!(matches!(request.validate(), Err(ValidationError::InvalidUrl(_))));

    // click with conflicting target
    let request = valid_request(
        CommandName::Click,
        params(&[
            ("target", json!("@e8")),
            ("role", json!("button")),
        ]),
    );
    assert!(request.validate().is_err());

    // click with a well-formed reference passes
    let request = valid_request(CommandName::Click, params(&[("target", json!("@e8"))]));
    request.validate().unwrap();

    // click with a malformed reference fails
    let request = valid_request(CommandName::Click, params(&[("target", json!("@food"))]));
    assert!(request.validate().is_err());

    // fill requires a value
    let request = valid_request(CommandName::Fill, params(&[("target", json!("@e12"))]));
    assert!(request.validate().is_err());

    // inspect context bounds
    let request = valid_request(CommandName::Inspect, params(&[("context", json!("bogus"))]));
    assert!(request.validate().is_err());
    let request = valid_request(CommandName::Inspect, params(&[("limit", json!(0))]));
    assert!(request.validate().is_err());
    let request = valid_request(CommandName::Inspect, params(&[("limit", json!(1.5))]));
    assert!(request.validate().is_err());

    // wait timeout bounds
    let request = valid_request(CommandName::Wait, params(&[("timeoutMs", json!(121_000))]));
    assert!(request.validate().is_err());

    // screenshot PDF rules
    let request = valid_request(CommandName::Screenshot, params(&[("format", json!("pdf"))]));
    assert!(request.validate().is_err(), "pdf without fullPage must fail");
    let request = valid_request(
        CommandName::Screenshot,
        params(&[("format", json!("pdf")), ("fullPage", json!(true)), ("output", json!("page.pdf"))]),
    );
    request.validate().unwrap();

    // visual compare only accepts private PNG artifacts
    let request = valid_request(
        CommandName::VisualCompare,
        params(&[("before", json!("before.png")), ("after", json!("after.png"))]),
    );
    request.validate().unwrap();
    let request = valid_request(
        CommandName::VisualCompare,
        params(&[("before", json!("/etc/passwd")), ("after", json!("after.png"))]),
    );
    assert!(request.validate().is_err());

    // network mock content-type printable ASCII only
    let request = valid_request(
        CommandName::NetworkMockSet,
        params(&[
            ("url", json!("https://api.example.com/v1")),
            ("body", json!("{}")),
            ("contentType", json!("application/json\n")),
        ]),
    );
    assert!(request.validate().is_err());

    // version mismatch fails closed
    let mut request = valid_request(CommandName::Ping, params(&[]));
    request.version = "0.4".to_string();
    assert!(matches!(
        request.validate(),
        Err(ValidationError::UnsupportedVersion(_))
    ));
}

#[test]
fn response_round_trip_and_unknown_id_semantics() {
    let response = CommandResponse::success("request-9", None);
    let data = codec::encode_line(&response).unwrap();
    let decoded: CommandResponse = codec::decode_line(&data).unwrap();
    assert_eq!(decoded, response);

    let failure = CommandResponse::failure(
        headless_protocol::protocol::UNKNOWN_REQUEST_IDENTIFIER,
        host_error_codes::OPERATION_FAILED,
        "could not read request",
        None,
    );
    assert_eq!(failure.id, "unknown");
    assert!(!failure.ok);
}
