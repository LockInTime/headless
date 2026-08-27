#![cfg(unix)]

use std::collections::BTreeMap;
use std::fs::{self, DirBuilder, File, Permissions};
use std::io::{self, Cursor, Read, Write};
use std::os::unix::fs::{symlink, DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

use headless_protocol::protocol::{
    codec, request_with_id, CommandName, CommandRequest, CommandResponse,
    UNKNOWN_REQUEST_IDENTIFIER,
};
use headless_protocol::transport::unix::{UnixControlClient, UnixControlListener, UnixRuntime};
use headless_protocol::transport::{
    exchange, read_frame, write_frame, ControlListener, TransportError,
};
use headless_protocol::HEADLESS_MAXIMUM_MESSAGE_BYTES;

#[cfg(target_os = "linux")]
use std::os::unix::net::UnixStream;
#[cfg(target_os = "linux")]
use std::process::Command;

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

struct TestRuntime {
    root: PathBuf,
    runtime: UnixRuntime,
}

impl TestRuntime {
    fn new() -> Self {
        let suffix = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let root = PathBuf::from(format!(
            "/tmp/headless-rust-transport-test-{}-{suffix}",
            std::process::id()
        ));
        let runtime = UnixRuntime::new(root.clone(), root.join("host.sock"));
        Self { root, runtime }
    }
}

impl Drop for TestRuntime {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

struct ChunkedReader {
    data: Cursor<Vec<u8>>,
    chunk_size: usize,
}

impl Read for ChunkedReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let maximum = buffer.len().min(self.chunk_size);
        self.data.read(&mut buffer[..maximum])
    }
}

struct ChunkedWriter {
    data: Vec<u8>,
    chunk_size: usize,
}

impl Write for ChunkedWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let count = buffer.len().min(self.chunk_size);
        self.data.extend_from_slice(&buffer[..count]);
        Ok(count)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct WouldBlockReader;

impl Read for WouldBlockReader {
    fn read(&mut self, _buffer: &mut [u8]) -> io::Result<usize> {
        Err(io::Error::from(io::ErrorKind::WouldBlock))
    }
}

struct InterruptedReader {
    interrupted: bool,
}

impl Read for InterruptedReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if !self.interrupted {
            self.interrupted = true;
            return Err(io::Error::from(io::ErrorKind::Interrupted));
        }
        Cursor::new(b"response\n").read(buffer)
    }
}

struct ZeroWriter;

impl Write for ZeroWriter {
    fn write(&mut self, _buffer: &[u8]) -> io::Result<usize> {
        Ok(0)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct ScriptedConnection {
    response: Cursor<Vec<u8>>,
    request: Vec<u8>,
}

impl Read for ScriptedConnection {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.response.read(buffer)
    }
}

impl Write for ScriptedConnection {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.request.extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn ping_request(id: &str) -> CommandRequest {
    request_with_id(id, CommandName::Ping, None, BTreeMap::new())
}

fn create_directory(path: &Path, mode: u32) {
    let mut builder = DirBuilder::new();
    builder.mode(mode);
    builder.create(path).unwrap();
    fs::set_permissions(path, Permissions::from_mode(mode)).unwrap();
}

#[test]
fn framing_handles_partial_io_and_exact_limit() {
    let mut exact = vec![b'x'; HEADLESS_MAXIMUM_MESSAGE_BYTES - 1];
    exact.push(b'\n');
    let mut reader = ChunkedReader {
        data: Cursor::new(exact.clone()),
        chunk_size: 37,
    };
    assert_eq!(read_frame(&mut reader).unwrap(), exact);

    let mut writer = ChunkedWriter {
        data: Vec::new(),
        chunk_size: 19,
    };
    write_frame(&mut writer, b"request\n").unwrap();
    assert_eq!(writer.data, b"request\n");
}

#[test]
fn framing_rejects_oversized_and_closed_inputs() {
    let mut oversized = vec![b'x'; HEADLESS_MAXIMUM_MESSAGE_BYTES];
    oversized.push(b'\n');
    assert!(matches!(
        read_frame(&mut Cursor::new(oversized)),
        Err(TransportError::MessageTooLarge)
    ));
    assert!(matches!(
        write_frame(
            &mut Cursor::new(Vec::new()),
            &vec![b'x'; HEADLESS_MAXIMUM_MESSAGE_BYTES + 1]
        ),
        Err(TransportError::MessageTooLarge)
    ));
    assert!(matches!(
        read_frame(&mut Cursor::new(Vec::<u8>::new())),
        Err(TransportError::ConnectionClosed)
    ));
    assert!(matches!(
        read_frame(&mut WouldBlockReader),
        Err(TransportError::TimedOut)
    ));
    assert_eq!(
        read_frame(&mut InterruptedReader { interrupted: false }).unwrap(),
        b"response\n"
    );
    assert!(matches!(
        write_frame(&mut ZeroWriter, b"request\n"),
        Err(TransportError::ConnectionClosed)
    ));
}

#[test]
fn exchange_requires_a_correlated_response() {
    let request = ping_request("request-1");
    let mismatched = codec::encode_line(&CommandResponse::success("request-2", None)).unwrap();
    let mut connection = ScriptedConnection {
        response: Cursor::new(mismatched),
        request: Vec::new(),
    };
    assert!(matches!(
        exchange(&mut connection, &request),
        Err(TransportError::MismatchedResponse)
    ));

    let sentinel = codec::encode_line(&CommandResponse::failure(
        UNKNOWN_REQUEST_IDENTIFIER,
        "INVALID_REQUEST",
        "unreadable",
        None,
    ))
    .unwrap();
    let mut connection = ScriptedConnection {
        response: Cursor::new(sentinel),
        request: Vec::new(),
    };
    let response = exchange(&mut connection, &request).unwrap();
    assert_eq!(response.id, UNKNOWN_REQUEST_IDENTIFIER);
    assert!(!response.ok);
}

#[test]
fn runtime_and_socket_permissions_are_private() {
    let test = TestRuntime::new();
    let listener = UnixControlListener::bind(&test.runtime).unwrap();
    let directory = fs::symlink_metadata(test.runtime.directory()).unwrap();
    let socket = fs::symlink_metadata(listener.socket_path()).unwrap();
    assert_eq!(directory.mode() & 0o777, 0o700);
    assert_eq!(socket.mode() & 0o777, 0o600);
}

#[test]
fn runtime_rejects_permissive_or_symlinked_directories() {
    let permissive = TestRuntime::new();
    create_directory(permissive.runtime.directory(), 0o755);
    assert!(matches!(
        UnixControlListener::bind(&permissive.runtime),
        Err(TransportError::InvalidRuntimeDirectory)
    ));

    let linked = TestRuntime::new();
    let real = linked.root.with_extension("real");
    create_directory(&real, 0o700);
    symlink(&real, linked.runtime.directory()).unwrap();
    assert!(matches!(
        UnixControlListener::bind(&linked.runtime),
        Err(TransportError::InvalidRuntimeDirectory)
    ));
    fs::remove_file(linked.runtime.directory()).unwrap();
    fs::remove_dir(&real).unwrap();
}

#[test]
fn endpoint_must_be_a_direct_child_of_runtime_directory() {
    let test = TestRuntime::new();
    let outside = UnixRuntime::new(
        test.runtime.directory().to_path_buf(),
        test.root.with_extension("outside.sock"),
    );
    assert!(matches!(
        UnixControlListener::bind(&outside),
        Err(TransportError::EndpointOutsideRuntimeDirectory)
    ));
}

#[test]
fn stale_socket_is_removed_but_live_socket_is_preserved() {
    let test = TestRuntime::new();
    test.runtime.prepare_private_directory().unwrap();
    let stale = UnixListener::bind(test.runtime.socket()).unwrap();
    drop(stale);
    assert!(test.runtime.socket().exists());

    let listener = UnixControlListener::bind(&test.runtime).unwrap();
    assert!(matches!(
        UnixControlListener::bind(&test.runtime),
        Err(TransportError::AlreadyRunning)
    ));
    assert!(listener.socket_path().exists());
}

#[test]
fn listener_does_not_unlink_a_replaced_path() {
    let test = TestRuntime::new();
    let listener = UnixControlListener::bind(&test.runtime).unwrap();
    fs::remove_file(test.runtime.socket()).unwrap();
    File::create(test.runtime.socket()).unwrap();
    drop(listener);
    assert!(test.runtime.socket().is_file());
}

#[test]
fn unix_client_and_listener_round_trip() {
    let test = TestRuntime::new();
    let listener = UnixControlListener::bind(&test.runtime).unwrap();
    let server = thread::spawn(move || {
        let mut connection = listener.accept().unwrap();
        let frame = read_frame(&mut connection).unwrap();
        let request: CommandRequest = codec::decode_line(&frame).unwrap();
        let response = CommandResponse::success(&request.id, None);
        write_frame(&mut connection, &codec::encode_line(&response).unwrap()).unwrap();
    });

    let client =
        UnixControlClient::new(test.runtime.socket().to_path_buf(), Duration::from_secs(2));
    let response = client.send(&ping_request("round-trip")).unwrap();
    assert!(response.ok);
    assert_eq!(response.id, "round-trip");
    server.join().unwrap();
}

#[cfg(target_os = "linux")]
#[test]
fn different_peer_user_is_rejected_when_privileged() {
    const CHILD_FLAG: &str = "HEADLESS_RUST_PEER_CLIENT";
    const SOCKET_PATH: &str = "HEADLESS_RUST_PEER_SOCKET";

    if std::env::var_os(CHILD_FLAG).is_some() {
        let path = std::env::var_os(SOCKET_PATH).unwrap();
        let mut stream = UnixStream::connect(PathBuf::from(path)).unwrap();
        let mut byte = [0_u8; 1];
        assert_eq!(stream.read(&mut byte).unwrap(), 0);
        return;
    }

    if unsafe { geteuid() } != 0 || !Path::new("/usr/bin/setpriv").is_file() {
        return;
    }

    let test = TestRuntime::new();
    let listener = UnixControlListener::bind(&test.runtime).unwrap();
    fs::set_permissions(test.runtime.directory(), Permissions::from_mode(0o777)).unwrap();
    fs::set_permissions(test.runtime.socket(), Permissions::from_mode(0o666)).unwrap();

    let mut child = Command::new("/usr/bin/setpriv")
        .args(["--reuid=65534", "--regid=65534", "--clear-groups"])
        .arg(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "different_peer_user_is_rejected_when_privileged",
            "--nocapture",
        ])
        .env(CHILD_FLAG, "1")
        .env(SOCKET_PATH, test.runtime.socket())
        .spawn()
        .unwrap();

    assert!(matches!(listener.accept(), Err(TransportError::PeerDenied)));
    assert!(child.wait().unwrap().success());
}

#[test]
fn invalid_request_fails_before_connecting() {
    let test = TestRuntime::new();
    let client =
        UnixControlClient::new(test.runtime.socket().to_path_buf(), Duration::from_secs(1));
    let invalid = request_with_id("", CommandName::Ping, None, BTreeMap::new());
    assert!(matches!(
        client.send(&invalid),
        Err(TransportError::Protocol(_))
    ));
    assert!(matches!(
        client.send(&ping_request("missing-host")),
        Err(TransportError::ConnectionFailed)
    ));
}

#[cfg(target_os = "linux")]
extern "C" {
    fn geteuid() -> u32;
}
