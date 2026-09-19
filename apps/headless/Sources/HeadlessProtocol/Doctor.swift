import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DoctorCheckStatus: String, Sendable {
    case healthy
    case warning
    case unsupported
    case failed
}

public enum DoctorCheckSeverity: String, Sendable {
    case info
    case warning
    case error
}

public struct DoctorCheck: Equatable, Sendable {
    public let id: String
    public let status: DoctorCheckStatus
    public let severity: DoctorCheckSeverity
    public let detail: String
    public let suggestion: String?

    public init(
        id: String,
        status: DoctorCheckStatus,
        severity: DoctorCheckSeverity,
        detail: String,
        suggestion: String? = nil
    ) {
        self.id = id
        self.status = status
        self.severity = severity
        self.detail = String(detail.prefix(512))
        self.suggestion = suggestion.map { String($0.prefix(512)) }
    }

    public var document: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "status": .string(status.rawValue),
            "severity": .string(severity.rawValue),
            "detail": .string(detail),
        ]
        if let suggestion { object["suggestion"] = .string(suggestion) }
        return .object(object)
    }
}

public struct DoctorReport: Sendable {
    public static let schemaVersion = 1
    public static let maximumChecks = 32

    public let platform: SettingPlatform
    public let checks: [DoctorCheck]

    public init(platform: SettingPlatform, checks: [DoctorCheck]) {
        self.platform = platform
        self.checks = Array(checks.prefix(Self.maximumChecks))
    }

    public var hasFailures: Bool { checks.contains { $0.status == .failed } }

    public var status: DoctorCheckStatus {
        if hasFailures { return .failed }
        if checks.contains(where: { $0.status == .warning }) { return .warning }
        return .healthy
    }

    public var document: JSONValue {
        .object([
            "schemaVersion": .number(Double(Self.schemaVersion)),
            "productVersion": .string(headlessProductVersion),
            "protocolVersion": .string(headlessProtocolVersion),
            "platform": .string(platform.rawValue),
            "status": .string(status.rawValue),
            "ok": .bool(!hasFailures),
            "checks": .array(checks.map(\.document)),
        ])
    }
}

public struct DoctorConfiguration: Sendable {
    public let environment: [String: String]
    public let platform: SettingPlatform
    public let executableURL: URL
    public let runtimeDirectoryURL: URL
    public let socketURL: URL
    public let artifactRootURL: URL
    public let settingsRootURL: URL?
    public let chromiumCandidates: [String]
    public let ffmpegCandidates: [String]
    public let runningAsRoot: Bool
    let artifactConfigurationValid: Bool
    let settingsConfigurationValid: Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platform: SettingPlatform = .current,
        executableURL: URL? = nil,
        runtimeDirectoryURL: URL = LocalRuntime.directoryURL,
        socketURL: URL? = nil,
        artifactRootURL: URL? = nil,
        settingsRootURL: URL? = nil,
        chromiumCandidates: [String]? = nil,
        ffmpegCandidates: [String]? = nil,
        runningAsRoot: Bool = geteuid() == 0
    ) throws {
        self.environment = environment
        self.platform = platform
        self.executableURL = try executableURL ?? Self.runningExecutableURL()
        self.runtimeDirectoryURL = runtimeDirectoryURL.standardizedFileURL
        let environmentSocket = environment["HEADLESS_SOCKET"].flatMap { value in
            value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil
        }
        self.socketURL = (socketURL ?? environmentSocket
            ?? runtimeDirectoryURL.appendingPathComponent("host.sock")).standardizedFileURL
        if let artifactRootURL {
            self.artifactRootURL = artifactRootURL.standardizedFileURL
            artifactConfigurationValid = artifactRootURL.path.hasPrefix("/")
        } else if let resolved = try? ArtifactStore.resolvedRootURL(
            environment: environment, platform: platform
        ) {
            self.artifactRootURL = resolved
            artifactConfigurationValid = true
        } else {
            self.artifactRootURL = URL(fileURLWithPath: "/")
            artifactConfigurationValid = false
        }
        if let settingsRootURL {
            self.settingsRootURL = settingsRootURL.standardizedFileURL
            settingsConfigurationValid = settingsRootURL.path.hasPrefix("/")
        } else if platform == .linux {
            self.settingsRootURL = try? FileSettingsBackend.resolvedRootURL(environment: environment)
            settingsConfigurationValid = self.settingsRootURL != nil
        } else {
            self.settingsRootURL = nil
            settingsConfigurationValid = true
        }
        self.chromiumCandidates = chromiumCandidates ?? ChromiumRuntimeResolver.defaultCandidatePaths(
            environment: environment
        )
        self.ffmpegCandidates = ffmpegCandidates ?? [
            "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
        ]
        self.runningAsRoot = runningAsRoot
    }

    private static func runningExecutableURL() throws -> URL {
        #if os(Linux)
        let candidate = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().standardizedFileURL
        #else
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw DoctorConfigurationError.executableUnavailable
        }
        let candidate = URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath().standardizedFileURL
        #endif
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw DoctorConfigurationError.executableUnavailable
        }
        return candidate
    }
}

public enum DoctorConfigurationError: Error {
    case executableUnavailable
}

public struct HeadlessDoctor {
    private let configuration: DoctorConfiguration

    public init(configuration: DoctorConfiguration) {
        self.configuration = configuration
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try self.init(configuration: DoctorConfiguration(environment: environment))
    }

    public func run() -> DoctorReport {
        var checks = [
            executableCheck(),
            runtimeDirectoryCheck(),
            socketCheck(),
            artifactStoreCheck(),
            hostLogCheck(),
            ffmpegCheck(),
            browserCheck(),
            settingsCheck(),
            sandboxCheck(),
        ]
        checks.sort { $0.id < $1.id }
        return DoctorReport(platform: configuration.platform, checks: checks)
    }

    private func executableCheck() -> DoctorCheck {
        var info = stat()
        guard lstat(configuration.executableURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            return failed(
                "executable.cli", "The running CLI executable cannot be validated.",
                "Reinstall Headless from a trusted release."
            )
        }
        return healthy("executable.cli", "The running CLI resolves to an executable regular file.")
    }

    private func runtimeDirectoryCheck() -> DoctorCheck {
        switch privateDirectoryState(configuration.runtimeDirectoryURL) {
        case .absent:
            return warning(
                "runtime.directory", "The private runtime directory has not been created yet.",
                "Run `headless start` to create it."
            )
        case .safe:
            return healthy("runtime.directory", "The runtime directory is private and owned by the current user.")
        case .unsafe:
            return failed(
                "runtime.directory", "The runtime directory is not a private owned directory.",
                "Remove or secure the runtime entry before starting Headless."
            )
        }
    }

    private func socketCheck() -> DoctorCheck {
        guard configuration.socketURL.deletingLastPathComponent().standardizedFileURL
                == configuration.runtimeDirectoryURL.standardizedFileURL else {
            return failed(
                "runtime.socket", "The configured socket is outside the private runtime directory.",
                "Unset HEADLESS_SOCKET and retry."
            )
        }
        var info = stat()
        guard lstat(configuration.socketURL.path, &info) == 0 else {
            if errno == ENOENT { return healthy("runtime.socket", "No host socket is present; the host is stopped.") }
            return failed(
                "runtime.socket", "The host socket cannot be inspected.",
                "Check runtime-directory ownership and permissions."
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0 else {
            return failed(
                "runtime.socket", "The socket entry has an unsafe type, owner, or mode.",
                "Stop using this runtime directory and inspect the entry manually."
            )
        }
        do {
            let response = try LocalSocketClient(socketPath: configuration.socketURL.path).send(
                CommandRequest(command: .ping), timeout: 0.5
            )
            guard response.ok else {
                return failed(
                    "runtime.socket", "A host answered but rejected the health probe.",
                    "Restart the Headless host."
                )
            }
            return healthy("runtime.socket", "A running host answered the non-disruptive health probe.")
        } catch {
            return failed(
                "runtime.socket", "A socket exists but no healthy host answered it.",
                "Stop any stale process and remove the socket only after verifying no host is running."
            )
        }
    }

    private func artifactStoreCheck() -> DoctorCheck {
        guard configuration.artifactConfigurationValid else {
            return failed(
                "storage.artifacts", "The artifact-directory override is not an absolute path.",
                "Use an absolute path or unset HEADLESS_ARTIFACT_DIR."
            )
        }
        switch privateDirectoryState(configuration.artifactRootURL) {
        case .absent:
            return warning(
                "storage.artifacts", "The artifact directory has not been created yet.",
                "Start Headless once to initialize private artifact storage."
            )
        case .safe:
            return healthy("storage.artifacts", "The artifact directory is private and owned by the current user.")
        case .unsafe:
            return failed(
                "storage.artifacts", "The artifact path is not a private owned directory.",
                "Choose an owned directory and restrict it to mode 0700."
            )
        }
    }

    private func hostLogCheck() -> DoctorCheck {
        let url: URL
        let isOverride: Bool
        if let override = configuration.environment["HEADLESS_HOST_LOG"] {
            guard override.hasPrefix("/"),
                  let resolved = try? HostLogStore(environment: configuration.environment).url else {
                return failed(
                    "storage.host-log", "The host-log override cannot be resolved safely.",
                    "Use an absolute path with an existing safe parent, or unset HEADLESS_HOST_LOG."
                )
            }
            url = resolved
            isOverride = true
        } else {
            url = configuration.runtimeDirectoryURL.appendingPathComponent("host.log")
            isOverride = false
        }
        var parentInfo = stat()
        guard lstat(url.deletingLastPathComponent().path, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
            return isOverride
                ? failed(
                    "storage.host-log", "The configured host-log parent is unavailable.",
                    "Create a safe writable parent or unset HEADLESS_HOST_LOG."
                )
                : warning(
                    "storage.host-log", "The host-log parent has not been created yet.",
                    "Run `headless start` to initialize host logging."
                )
        }
        if url.deletingLastPathComponent().standardizedFileURL == configuration.runtimeDirectoryURL,
           (parentInfo.st_uid != geteuid() || (parentInfo.st_mode & 0o077) != 0) {
            return failed(
                "storage.host-log", "The default host-log parent is not private.",
                "Secure the runtime directory before starting Headless."
            )
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT {
                guard access(url.deletingLastPathComponent().path, W_OK) == 0 else {
                    return failed(
                        "storage.host-log", "The host-log destination is not writable.",
                        "Choose a writable private log destination."
                    )
                }
                return warning(
                    "storage.host-log", "No host log exists because no detached host has written one yet.",
                    "Run `headless start` to create the bounded host log."
                )
            }
            return failed("storage.host-log", "The host log cannot be inspected.", "Check its parent directory.")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              (info.st_mode & 0o077) == 0, info.st_size <= off_t(HostLogStore.maximumFileBytes),
              access(url.path, W_OK) == 0 else {
            return failed(
                "storage.host-log", "The host log violates its private bounded-file contract.",
                "Replace it with an owned 0600 regular file with one link."
            )
        }
        for (candidate, maximumSize) in [
            (URL(fileURLWithPath: url.path + ".1"), HostLogStore.maximumFileBytes),
            (URL(fileURLWithPath: url.path + ".lock"), Int.max),
        ] {
            guard lstat(candidate.path, &info) == 0 else {
                if errno == ENOENT { continue }
                return failed(
                    "storage.host-log", "A host-log companion file cannot be inspected.",
                    "Inspect the host-log archive and lock entries."
                )
            }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                  (info.st_mode & 0o077) == 0, info.st_size <= off_t(maximumSize),
                  access(candidate.path, W_OK) == 0 else {
                return failed(
                    "storage.host-log", "A host-log archive or lock entry is unsafe.",
                    "Replace companion entries with owned 0600 regular files with one link."
                )
            }
        }
        return healthy("storage.host-log", "The host log is private, regular, and within its size bound.")
    }

    private func ffmpegCheck() -> DoctorCheck {
        if BrowserRecording.ffmpegExecutable(
            environment: configuration.environment,
            systemCandidates: configuration.ffmpegCandidates
        ) != nil {
            return healthy("dependency.ffmpeg", "FFmpeg is available for recording and visual comparison.")
        }
        return warning(
            "dependency.ffmpeg", "FFmpeg is unavailable; recording and visual comparison are disabled.",
            "Install FFmpeg or set HEADLESS_FFMPEG_EXECUTABLE to a trusted absolute executable."
        )
    }

    private func browserCheck() -> DoctorCheck {
        guard configuration.platform == .linux else {
            return healthy("browser.runtime", "The system WebKit framework provides the browser engine.")
        }
        do {
            _ = try ChromiumRuntimeResolver(
                environment: configuration.environment,
                hostExecutablePath: configuration.executableURL.path,
                systemCandidates: configuration.chromiumCandidates
            ).resolve()
            return healthy("browser.runtime", "A supported Chromium executable is available.")
        } catch {
            return failed(
                "browser.runtime", "No supported Chromium executable is available.",
                "Install native Chromium or use the bundled Linux runtime."
            )
        }
    }

    private func settingsCheck() -> DoctorCheck {
        guard configuration.settingsConfigurationValid else {
            return failed(
                "settings.storage", "The settings location is not an absolute path.",
                "Set XDG_CONFIG_HOME to an absolute directory or unset it."
            )
        }
        do {
            if configuration.platform == .macOS {
                _ = try SettingsStore.production(environment: configuration.environment).snapshots(caller: .user)
                return healthy("settings.storage", "Stored settings match the current typed registry.")
            }
            guard let root = configuration.settingsRootURL else {
                return failed("settings.storage", "The settings location cannot be resolved.", "Check XDG_CONFIG_HOME.")
            }
            let backend = try FileSettingsBackend(rootURL: root)
            let exists = try backend.validateReadOnly()
            return healthy(
                "settings.storage",
                exists ? "Stored settings are private and valid." : "No settings file exists; typed defaults will be used."
            )
        } catch {
            return failed(
                "settings.storage", "Settings storage is unsafe or corrupt.",
                "Inspect or reset the settings storage before starting Headless."
            )
        }
    }

    private func sandboxCheck() -> DoctorCheck {
        guard configuration.platform == .linux else {
            return DoctorCheck(
                id: "sandbox.linux", status: .unsupported, severity: .info,
                detail: "Linux Chromium sandbox checks do not apply on macOS."
            )
        }
        guard !configuration.runningAsRoot else {
            return failed(
                "sandbox.linux", "Headless is running as root, which the Chromium host refuses.",
                "Run Headless as a non-root user without disabling Chromium's sandbox."
            )
        }
        return healthy("sandbox.linux", "The current user is eligible to run sandboxed Chromium.")
    }

    private enum DirectoryState { case absent, safe, unsafe }

    private func privateDirectoryState(_ url: URL) -> DirectoryState {
        guard url.path.hasPrefix("/") else { return .unsafe }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? .absent : .unsafe }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid()
            && (info.st_mode & 0o077) == 0 ? .safe : .unsafe
    }

    private func healthy(_ id: String, _ detail: String) -> DoctorCheck {
        DoctorCheck(id: id, status: .healthy, severity: .info, detail: detail)
    }

    private func warning(_ id: String, _ detail: String, _ suggestion: String) -> DoctorCheck {
        DoctorCheck(id: id, status: .warning, severity: .warning, detail: detail, suggestion: suggestion)
    }

    private func failed(_ id: String, _ detail: String, _ suggestion: String) -> DoctorCheck {
        DoctorCheck(id: id, status: .failed, severity: .error, detail: detail, suggestion: suggestion)
    }
}
