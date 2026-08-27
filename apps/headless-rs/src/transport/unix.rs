//! Secure Unix-domain socket backend for the control transport.

use std::env;
use std::fs::{self, DirBuilder, FileType, Metadata, Permissions};
use std::io;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use crate::protocol::{CommandRequest, CommandResponse};
use crate::transport::{exchange_validated, ControlListener, TransportError};

const RUNTIME_DIRECTORY_MODE: u32 = 0o700;
const SOCKET_MODE: u32 = 0o600;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnixRuntime {
    directory: PathBuf,
    socket: PathBuf,
}

impl UnixRuntime {
    pub fn for_current_user() -> Self {
        let directory = PathBuf::from(format!("/tmp/headless-{}", effective_user_id()));
        let socket = env::var_os("HEADLESS_SOCKET")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .unwrap_or_else(|| directory.join("host.sock"));
        Self { directory, socket }
    }

    pub fn new(directory: PathBuf, socket: PathBuf) -> Self {
        Self { directory, socket }
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    pub fn prepare_private_directory(&self) -> Result<(), TransportError> {
        prepare_private_directory(&self.directory)
    }

    fn validate_endpoint_parent(&self) -> Result<(), TransportError> {
        if !is_direct_child(&self.socket, &self.directory) {
            return Err(TransportError::EndpointOutsideRuntimeDirectory);
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct UnixControlListener {
    listener: UnixListener,
    socket_path: PathBuf,
    socket_identity: (u64, u64),
}

impl UnixControlListener {
    pub fn bind(runtime: &UnixRuntime) -> Result<Self, TransportError> {
        runtime.prepare_private_directory()?;
        runtime.validate_endpoint_parent()?;
        remove_stale_socket_if_safe(runtime.socket())?;

        let listener = UnixListener::bind(runtime.socket())
            .map_err(|error| map_bind_error(error, runtime.socket()))?;
        if let Err(error) =
            fs::set_permissions(runtime.socket(), Permissions::from_mode(SOCKET_MODE))
        {
            let _ = fs::remove_file(runtime.socket());
            return Err(TransportError::Io {
                operation: "socket permission setup",
                source: error,
            });
        }
        let metadata = match fs::symlink_metadata(runtime.socket()) {
            Ok(metadata) => metadata,
            Err(source) => {
                let _ = fs::remove_file(runtime.socket());
                return Err(TransportError::Io {
                    operation: "socket identity validation",
                    source,
                });
            }
        };
        if !metadata.file_type().is_socket()
            || metadata.uid() != effective_user_id()
            || metadata.mode() & 0o777 != SOCKET_MODE
        {
            let _ = fs::remove_file(runtime.socket());
            return Err(TransportError::InvalidRuntimeDirectory);
        }

        Ok(Self {
            listener,
            socket_path: runtime.socket().to_path_buf(),
            socket_identity: (metadata.dev(), metadata.ino()),
        })
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }
}

impl ControlListener for UnixControlListener {
    type Connection = UnixStream;

    fn accept(&self) -> Result<Self::Connection, TransportError> {
        let (stream, _) = self.listener.accept().map_err(|error| TransportError::Io {
            operation: "accept",
            source: error,
        })?;
        authorize_peer(effective_user_id(), peer_user_id(&stream)?)?;
        Ok(stream)
    }
}

impl Drop for UnixControlListener {
    fn drop(&mut self) {
        let Ok(metadata) = fs::symlink_metadata(&self.socket_path) else {
            return;
        };
        if metadata.file_type().is_socket()
            && metadata.uid() == effective_user_id()
            && (metadata.dev(), metadata.ino()) == self.socket_identity
        {
            let _ = fs::remove_file(&self.socket_path);
        }
    }
}

#[derive(Debug, Clone)]
pub struct UnixControlClient {
    socket_path: PathBuf,
    timeout: Duration,
}

impl UnixControlClient {
    pub fn new(socket_path: PathBuf, timeout: Duration) -> Self {
        Self {
            socket_path,
            timeout,
        }
    }

    pub fn send(&self, request: &CommandRequest) -> Result<CommandResponse, TransportError> {
        request.validate()?;
        let mut stream = UnixStream::connect(&self.socket_path).map_err(|error| {
            if matches!(
                error.kind(),
                io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
            ) {
                TransportError::ConnectionFailed
            } else {
                TransportError::Io {
                    operation: "connect",
                    source: error,
                }
            }
        })?;
        stream
            .set_read_timeout(Some(self.timeout))
            .map_err(|error| TransportError::Io {
                operation: "read timeout configuration",
                source: error,
            })?;
        stream
            .set_write_timeout(Some(self.timeout))
            .map_err(|error| TransportError::Io {
                operation: "write timeout configuration",
                source: error,
            })?;
        exchange_validated(&mut stream, request)
    }
}

fn prepare_private_directory(path: &Path) -> Result<(), TransportError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => validate_private_directory(&metadata),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let mut builder = DirBuilder::new();
            builder.mode(RUNTIME_DIRECTORY_MODE);
            match builder.create(path) {
                Ok(()) => {
                    fs::set_permissions(path, Permissions::from_mode(RUNTIME_DIRECTORY_MODE))
                        .map_err(|source| TransportError::Io {
                            operation: "runtime directory permission setup",
                            source,
                        })?;
                    let metadata =
                        fs::symlink_metadata(path).map_err(|source| TransportError::Io {
                            operation: "runtime directory validation",
                            source,
                        })?;
                    validate_private_directory(&metadata)
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    let metadata =
                        fs::symlink_metadata(path).map_err(|source| TransportError::Io {
                            operation: "runtime directory validation",
                            source,
                        })?;
                    validate_private_directory(&metadata)
                }
                Err(source) => Err(TransportError::Io {
                    operation: "runtime directory creation",
                    source,
                }),
            }
        }
        Err(source) => Err(TransportError::Io {
            operation: "runtime directory validation",
            source,
        }),
    }
}

fn validate_private_directory(metadata: &Metadata) -> Result<(), TransportError> {
    if !metadata.file_type().is_dir()
        || metadata.uid() != effective_user_id()
        || metadata.mode() & 0o077 != 0
    {
        return Err(TransportError::InvalidRuntimeDirectory);
    }
    Ok(())
}

fn is_direct_child(path: &Path, parent: &Path) -> bool {
    path.is_absolute()
        && parent.is_absolute()
        && !path
            .components()
            .any(|component| matches!(component, Component::ParentDir))
        && path.parent() == Some(parent)
        && path.file_name().is_some()
}

fn remove_stale_socket_if_safe(path: &Path) -> Result<(), TransportError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(source) => {
            return Err(TransportError::Io {
                operation: "existing socket validation",
                source,
            })
        }
    };

    if !is_socket(&metadata.file_type()) || metadata.uid() != effective_user_id() {
        return Err(TransportError::InvalidRuntimeDirectory);
    }

    match UnixStream::connect(path) {
        Ok(_) => Err(TransportError::AlreadyRunning),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
            ) =>
        {
            match fs::remove_file(path) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
                Err(source) => Err(TransportError::Io {
                    operation: "stale socket removal",
                    source,
                }),
            }
        }
        Err(source) => Err(TransportError::Io {
            operation: "existing socket probe",
            source,
        }),
    }
}

fn is_socket(file_type: &FileType) -> bool {
    file_type.is_socket()
}

fn map_bind_error(error: io::Error, path: &Path) -> TransportError {
    if error.kind() == io::ErrorKind::AddrInUse && path.exists() {
        TransportError::AlreadyRunning
    } else {
        TransportError::Io {
            operation: "bind",
            source: error,
        }
    }
}

fn authorize_peer(expected: u32, actual: u32) -> Result<(), TransportError> {
    if expected == actual {
        Ok(())
    } else {
        Err(TransportError::PeerDenied)
    }
}

#[cfg(target_os = "linux")]
fn peer_user_id(stream: &UnixStream) -> Result<u32, TransportError> {
    #[repr(C)]
    struct PeerCredentials {
        pid: i32,
        uid: u32,
        gid: u32,
    }

    const SOL_SOCKET: i32 = 1;
    const SO_PEERCRED: i32 = 17;
    let mut credentials = PeerCredentials {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of::<PeerCredentials>() as u32;
    let result = unsafe {
        getsockopt(
            stream.as_raw_fd(),
            SOL_SOCKET,
            SO_PEERCRED,
            (&mut credentials as *mut PeerCredentials).cast(),
            &mut length,
        )
    };
    if result != 0 || length as usize != std::mem::size_of::<PeerCredentials>() {
        return Err(TransportError::Io {
            operation: "peer credential check",
            source: io::Error::last_os_error(),
        });
    }
    Ok(credentials.uid)
}

#[cfg(target_os = "macos")]
fn peer_user_id(stream: &UnixStream) -> Result<u32, TransportError> {
    let mut uid = 0_u32;
    let mut gid = 0_u32;
    let result = unsafe { getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    if result != 0 {
        return Err(TransportError::Io {
            operation: "peer credential check",
            source: io::Error::last_os_error(),
        });
    }
    Ok(uid)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn peer_user_id(_stream: &UnixStream) -> Result<u32, TransportError> {
    Err(TransportError::Io {
        operation: "peer credential check",
        source: io::Error::new(io::ErrorKind::Unsupported, "unsupported Unix platform"),
    })
}

#[cfg(unix)]
fn effective_user_id() -> u32 {
    unsafe { geteuid() }
}

#[cfg(target_os = "linux")]
extern "C" {
    fn getsockopt(
        socket: RawFd,
        level: i32,
        option_name: i32,
        option_value: *mut std::ffi::c_void,
        option_length: *mut u32,
    ) -> i32;
}

#[cfg(target_os = "macos")]
extern "C" {
    fn getpeereid(socket: RawFd, effective_uid: *mut u32, effective_gid: *mut u32) -> i32;
}

extern "C" {
    fn geteuid() -> u32;
}

#[cfg(test)]
mod tests {
    use super::authorize_peer;
    use crate::transport::TransportError;

    #[test]
    fn peer_authorization_fails_closed() {
        authorize_peer(501, 501).unwrap();
        assert!(matches!(
            authorize_peer(501, 502),
            Err(TransportError::PeerDenied)
        ));
    }
}
