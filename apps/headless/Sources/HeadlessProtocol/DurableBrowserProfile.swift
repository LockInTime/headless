import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DurableBrowserProfileError: Error, CustomStringConvertible {
    case invalidDataDirectory
    case invalidProfile
    case profileInUse
    case operationFailed(String)

    public var description: String {
        switch self {
        case .invalidDataDirectory:
            return "Browser profile data directory must be private and owned by the current user"
        case .invalidProfile:
            return "Browser profile is unsafe; remove the invalid entry before retrying"
        case .profileInUse:
            return "Another Headless host is already using the browser profile"
        case .operationFailed(let operation):
            return "Browser profile \(operation) failed: \(String(cString: strerror(errno)))"
        }
    }
}

public enum DurableBrowserProfileMigration: String, Sendable {
    case none
    case migrated
    case skippedUnsafe = "skipped-unsafe"
    case recoveredCorruption = "recovered-corruption"
}

/// Owns the Linux normal-profile directory and its process-wide lease. Paths
/// are selected by the host, never by an agent-facing command.
public final class DurableBrowserProfile: @unchecked Sendable {
    public let rootURL: URL
    public let directoryURL: URL
    public let migration: DurableBrowserProfileMigration
    private let lockDescriptor: Int32

    public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let base: URL
        if let xdgDataHome = environment["XDG_DATA_HOME"], xdgDataHome.hasPrefix("/") {
            base = URL(fileURLWithPath: xdgDataHome, isDirectory: true).standardizedFileURL
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true)
        }
        try self.init(
            rootURL: base.appendingPathComponent("headless", isDirectory: true),
            legacyProfileURL: LocalRuntime.directoryURL.appendingPathComponent("chromium-profile", isDirectory: true)
        )
    }

    public init(rootURL: URL, legacyProfileURL: URL? = nil) throws {
        let root = rootURL.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw DurableBrowserProfileError.invalidDataDirectory
        }
        try Self.prepareParentDirectories(for: root)
        try Self.preparePrivateDirectory(root, recoverOwnedInvalidEntry: false)
        Self.removeStaleMigrationDirectories(from: root)

        let lockURL = root.appendingPathComponent("normal-profile.lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DurableBrowserProfileError.operationFailed("lock creation") }
        do {
            try Self.validateLock(descriptor)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw DurableBrowserProfileError.profileInUse }
                throw DurableBrowserProfileError.operationFailed("lock acquisition")
            }
        } catch {
            _ = close(descriptor)
            throw error
        }

        let profile = root.appendingPathComponent("chromium-profile", isDirectory: true)
        let migrationResult: DurableBrowserProfileMigration
        do {
            migrationResult = try Self.prepareProfile(profile, legacyProfileURL: legacyProfileURL)
        } catch {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw error
        }
        self.rootURL = root
        self.directoryURL = profile
        self.lockDescriptor = descriptor
        self.migration = migrationResult
    }

    deinit {
        _ = flock(lockDescriptor, LOCK_UN)
        _ = close(lockDescriptor)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
        try Self.preparePrivateDirectory(directoryURL, recoverOwnedInvalidEntry: true)
    }

    private static func prepareParentDirectories(for root: URL) throws {
        let parent = root.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw DurableBrowserProfileError.operationFailed("parent directory creation")
        }
    }

    private static func prepareProfile(
        _ profile: URL, legacyProfileURL: URL?
    ) throws -> DurableBrowserProfileMigration {
        var info = stat()
        if lstat(profile.path, &info) == 0 {
            if isPrivateOwnedDirectory(info) { return .none }
            guard info.st_uid == getuid(), (info.st_mode & S_IFMT) != S_IFLNK else {
                throw DurableBrowserProfileError.invalidProfile
            }
            let quarantine = profile.deletingLastPathComponent().appendingPathComponent(
                "chromium-profile.corrupt-\(UUID().uuidString)", isDirectory: true
            )
            guard rename(profile.path, quarantine.path) == 0 else {
                throw DurableBrowserProfileError.operationFailed("corruption recovery")
            }
            try preparePrivateDirectory(profile, recoverOwnedInvalidEntry: false)
            return .recoveredCorruption
        }
        guard errno == ENOENT else { throw DurableBrowserProfileError.operationFailed("profile check") }

        if let legacyProfileURL, FileManager.default.fileExists(atPath: legacyProfileURL.path) {
            guard isSafeLegacyTree(legacyProfileURL) else {
                try preparePrivateDirectory(profile, recoverOwnedInvalidEntry: false)
                return .skippedUnsafe
            }
            let staging = profile.deletingLastPathComponent().appendingPathComponent(
                ".chromium-profile-migration-\(UUID().uuidString)", isDirectory: true
            )
            do {
                try FileManager.default.copyItem(at: legacyProfileURL, to: staging)
                _ = chmod(staging.path, 0o700)
                removeChromiumLeaseArtifacts(from: staging)
                guard rename(staging.path, profile.path) == 0 else {
                    throw DurableBrowserProfileError.operationFailed("migration activation")
                }
                try? FileManager.default.removeItem(at: legacyProfileURL)
                return .migrated
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }

        try preparePrivateDirectory(profile, recoverOwnedInvalidEntry: false)
        return .none
    }

    private static func preparePrivateDirectory(
        _ url: URL, recoverOwnedInvalidEntry: Bool
    ) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard isPrivateOwnedDirectory(info) else {
                if recoverOwnedInvalidEntry, info.st_uid == getuid(), (info.st_mode & S_IFMT) != S_IFLNK {
                    try FileManager.default.removeItem(at: url)
                    return try preparePrivateDirectory(url, recoverOwnedInvalidEntry: false)
                }
                throw DurableBrowserProfileError.invalidDataDirectory
            }
            return
        }
        guard errno == ENOENT else { throw DurableBrowserProfileError.operationFailed("directory check") }
        guard mkdir(url.path, 0o700) == 0 else {
            if errno == EEXIST { return try preparePrivateDirectory(url, recoverOwnedInvalidEntry: false) }
            throw DurableBrowserProfileError.operationFailed("directory creation")
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw DurableBrowserProfileError.operationFailed("directory permissions")
        }
    }

    private static func validateLock(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw DurableBrowserProfileError.operationFailed("lock validation")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw DurableBrowserProfileError.invalidDataDirectory
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw DurableBrowserProfileError.operationFailed("lock permissions")
        }
    }

    private static func isPrivateOwnedDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && (info.st_mode & 0o077) == 0
    }

    private static func isSafeLegacyTree(_ root: URL) -> Bool {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, isPrivateOwnedDirectory(rootInfo) else { return false }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]
        ) else { return false }
        for case let item as URL in enumerator {
            var info = stat()
            guard lstat(item.path, &info) == 0, info.st_uid == getuid() else { return false }
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else { return false }
        }
        return true
    }

    private static func removeChromiumLeaseArtifacts(from profile: URL) {
        for name in ["SingletonCookie", "SingletonLock", "SingletonSocket"] {
            try? FileManager.default.removeItem(at: profile.appendingPathComponent(name))
        }
    }

    private static func removeStaleMigrationDirectories(from root: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(".chromium-profile-migration-") {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(candidate.path, &info) == 0, info.st_uid == getuid(),
                  (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
    }
}
