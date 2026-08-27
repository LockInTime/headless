//! Local control transport primitives.
//!
//! Framing and request correlation are platform-independent. Platform
//! backends provide authenticated local connections without adding a network
//! listener. The Unix backend is implemented first; Windows named pipes plug
//! into the same traits in a later increment.

use std::fmt;
use std::io::{self, Read, Write};

use crate::error::ValidationError;
use crate::protocol::{codec, CommandRequest, CommandResponse, UNKNOWN_REQUEST_IDENTIFIER};
use crate::HEADLESS_MAXIMUM_MESSAGE_BYTES;

#[cfg(unix)]
pub mod unix;

#[derive(Debug)]
pub enum TransportError {
    TimedOut,
    ConnectionFailed,
    ConnectionClosed,
    MessageTooLarge,
    InvalidRuntimeDirectory,
    EndpointOutsideRuntimeDirectory,
    AlreadyRunning,
    PeerDenied,
    MismatchedResponse,
    Protocol(ValidationError),
    Io {
        operation: &'static str,
        source: io::Error,
    },
}

impl TransportError {
    fn from_io(operation: &'static str, error: io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => Self::TimedOut,
            io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::NotConnected
            | io::ErrorKind::UnexpectedEof
            | io::ErrorKind::WriteZero => Self::ConnectionClosed,
            _ => Self::Io {
                operation,
                source: error,
            },
        }
    }
}

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TimedOut => write!(f, "Headless host did not respond before the deadline"),
            Self::ConnectionFailed => write!(f, "Headless host is not running"),
            Self::ConnectionClosed => write!(f, "Headless host closed the connection"),
            Self::MessageTooLarge => write!(f, "Headless host message exceeded the size limit"),
            Self::InvalidRuntimeDirectory => {
                write!(
                    f,
                    "Local runtime directory is not private to the current user"
                )
            }
            Self::EndpointOutsideRuntimeDirectory => {
                write!(
                    f,
                    "Local endpoint must be inside the private runtime directory"
                )
            }
            Self::AlreadyRunning => write!(
                f,
                "Another Headless host is already using the local endpoint"
            ),
            Self::PeerDenied => write!(f, "Local transport peer is not authorized"),
            Self::MismatchedResponse => write!(f, "Headless host replied to a different request"),
            Self::Protocol(error) => write!(f, "{error}"),
            Self::Io { operation, source } => {
                write!(f, "Local transport {operation} failed: {source}")
            }
        }
    }
}

impl std::error::Error for TransportError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Protocol(error) => Some(error),
            Self::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}

impl From<ValidationError> for TransportError {
    fn from(value: ValidationError) -> Self {
        Self::Protocol(value)
    }
}

pub trait ControlConnection: Read + Write + Send {}

impl<T: Read + Write + Send> ControlConnection for T {}

pub trait ControlListener {
    type Connection: ControlConnection;

    fn accept(&self) -> Result<Self::Connection, TransportError>;
}

/// Read exactly one newline-delimited frame without allowing its buffer to
/// grow beyond the wire cap. Bytes after the first newline are irrelevant to
/// the one-request-per-connection protocol and are intentionally ignored.
pub fn read_frame<R: Read>(reader: &mut R) -> Result<Vec<u8>, TransportError> {
    let mut frame = Vec::with_capacity(8_192);
    let mut chunk = [0_u8; 8_192];

    loop {
        let count = loop {
            match reader.read(&mut chunk) {
                Ok(count) => break count,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(TransportError::from_io("read", error)),
            }
        };
        if count == 0 {
            return Err(TransportError::ConnectionClosed);
        }

        if let Some(newline) = chunk[..count].iter().position(|byte| *byte == b'\n') {
            let frame_end = newline + 1;
            if frame.len() + frame_end > HEADLESS_MAXIMUM_MESSAGE_BYTES {
                return Err(TransportError::MessageTooLarge);
            }
            frame.extend_from_slice(&chunk[..frame_end]);
            return Ok(frame);
        }

        if frame.len() + count >= HEADLESS_MAXIMUM_MESSAGE_BYTES {
            return Err(TransportError::MessageTooLarge);
        }
        frame.extend_from_slice(&chunk[..count]);
    }
}

pub fn write_frame<W: Write>(writer: &mut W, frame: &[u8]) -> Result<(), TransportError> {
    if frame.len() > HEADLESS_MAXIMUM_MESSAGE_BYTES {
        return Err(TransportError::MessageTooLarge);
    }
    writer
        .write_all(frame)
        .map_err(|error| TransportError::from_io("write", error))
}

/// Exchange one validated request and correlated response on an authenticated
/// local connection.
pub fn exchange<C: ControlConnection>(
    connection: &mut C,
    request: &CommandRequest,
) -> Result<CommandResponse, TransportError> {
    request.validate()?;
    exchange_validated(connection, request)
}

pub(crate) fn exchange_validated<C: ControlConnection>(
    connection: &mut C,
    request: &CommandRequest,
) -> Result<CommandResponse, TransportError> {
    let request_frame = codec::encode_line(request)?;
    write_frame(connection, &request_frame)?;

    let response_frame = read_frame(connection)?;
    let response: CommandResponse = codec::decode_line(&response_frame)?;
    if response.id != request.id && response.id != UNKNOWN_REQUEST_IDENTIFIER {
        return Err(TransportError::MismatchedResponse);
    }
    Ok(response)
}
