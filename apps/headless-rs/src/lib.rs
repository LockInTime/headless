//! Rust port of the Headless shared protocol core (ADR #21).
//!
//! The Swift implementation in `apps/headless/Sources/HeadlessProtocol` is
//! the reference. This crate mirrors its security-critical semantics:
//! strict request validation, bounded messages, and the navigation
//! boundaries. The hard rules do not change here: no arbitrary-JS verb,
//! no TCP listener, fail closed, bounded everything.

pub mod error;
pub mod json;
pub mod protocol;
pub mod transport;
pub mod url;
pub mod validate;

pub const HEADLESS_PROTOCOL_VERSION: &str = "0.5";
/// One MiB frame cap, identical to `headlessMaximumMessageBytes`.
pub const HEADLESS_MAXIMUM_MESSAGE_BYTES: usize = 1_048_576;
