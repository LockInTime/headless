import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SettingPlatform: String, CaseIterable, Sendable {
    case macOS = "macos"
    case linux

    public static var current: SettingPlatform {
        #if os(macOS)
        .macOS
        #else
        .linux
        #endif
    }
}

public enum SettingAccessClass: String, Sendable {
    case agentReadable = "agent-readable"
    case agentWritable = "agent-writable"
    case userOnly = "user-only"
}

public enum SettingRestartBehavior: String, Sendable {
    case immediate
    case nextHostStart = "next-host-start"
}

public enum SettingValueType: Equatable, Sendable {
    case boolean
    case integer(ClosedRange<Int>)
    case string(maximumLength: Int)
    case enumeration([String])

    fileprivate func parse(_ rawValue: String) throws -> String {
        switch self {
        case .boolean:
            guard rawValue == "true" || rawValue == "false" else {
                throw SettingsError.invalidValue(rawValue)
            }
        case .integer(let range):
            guard let value = Int(rawValue), String(value) == rawValue, range.contains(value) else {
                throw SettingsError.invalidValue(rawValue)
            }
        case .string(let maximumLength):
            guard !rawValue.isEmpty, rawValue.utf8.count <= maximumLength,
                  !rawValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw SettingsError.invalidValue(rawValue)
            }
        case .enumeration(let values):
            guard values.contains(rawValue) else { throw SettingsError.invalidValue(rawValue) }
        }
        return rawValue
    }

    fileprivate func jsonValue(_ rawValue: String) -> JSONValue {
        switch self {
        case .boolean:
            return .bool(rawValue == "true")
        case .integer:
            return .number(Double(Int(rawValue) ?? 0))
        case .string, .enumeration:
            return .string(rawValue)
        }
    }

    fileprivate var document: JSONValue {
        switch self {
        case .boolean:
            return .object(["name": .string("boolean")])
        case .integer(let range):
            return .object([
                "name": .string("integer"),
                "minimum": .number(Double(range.lowerBound)),
                "maximum": .number(Double(range.upperBound)),
            ])
        case .string(let maximumLength):
            return .object([
                "name": .string("string"),
                "maximumLength": .number(Double(maximumLength)),
            ])
        case .enumeration(let values):
            return .object([
                "name": .string("enum"),
                "allowedValues": .array(values.map(JSONValue.string)),
            ])
        }
    }

    fileprivate var displayName: String {
        switch self {
        case .boolean: return "boolean"
        case .integer: return "integer"
        case .string: return "string"
        case .enumeration: return "enum"
        }
    }
}

public struct SettingDefinition: Equatable, Sendable {
    public let key: String
    public let valueType: SettingValueType
    public let defaultValue: String
    public let platforms: Set<SettingPlatform>
    public let restartBehavior: SettingRestartBehavior
    public let access: SettingAccessClass
    public let summary: String
    public let macOSStorageKey: String?

    public init(
        key: String,
        valueType: SettingValueType,
        defaultValue: String,
        platforms: Set<SettingPlatform>,
        restartBehavior: SettingRestartBehavior,
        access: SettingAccessClass,
        summary: String,
        macOSStorageKey: String? = nil
    ) {
        self.key = key
        self.valueType = valueType
        self.defaultValue = defaultValue
        self.platforms = platforms
        self.restartBehavior = restartBehavior
        self.access = access
        self.summary = summary
        self.macOSStorageKey = macOSStorageKey
    }

    fileprivate func validated(_ rawValue: String) throws -> String {
        try valueType.parse(rawValue)
    }

    public var document: JSONValue {
        .object([
            "key": .string(key),
            "type": valueType.document,
            "default": valueType.jsonValue(defaultValue),
            "platforms": .array(platforms.sorted { $0.rawValue < $1.rawValue }.map {
                .string($0.rawValue)
            }),
            "restartBehavior": .string(restartBehavior.rawValue),
            "access": .string(access.rawValue),
            "summary": .string(summary),
        ])
    }
}

public struct SettingsRegistry: Sendable {
    public static let shared = SettingsRegistry(definitions: [
        SettingDefinition(
            key: "startup-presentation",
            valueType: .enumeration(AgentStartupPresentation.allCases.map(\.rawValue)),
            defaultValue: AgentStartupPresentation.background.rawValue,
            platforms: [.macOS],
            restartBehavior: .nextHostStart,
            access: .agentWritable,
            summary: "Choose whether an agent-started macOS host activates in front of the current app.",
            macOSStorageKey: "AgentStartupPresentation"
        ),
    ])

    public let definitions: [SettingDefinition]
    private let definitionsByKey: [String: SettingDefinition]

    public init(definitions: [SettingDefinition]) {
        precondition(Set(definitions.map(\.key)).count == definitions.count, "Duplicate setting key")
        for definition in definitions {
            precondition((try? definition.validated(definition.defaultValue)) != nil, "Invalid setting default")
        }
        self.definitions = definitions.sorted { $0.key < $1.key }
        definitionsByKey = Dictionary(uniqueKeysWithValues: definitions.map { ($0.key, $0) })
    }

    public func definition(for key: String) throws -> SettingDefinition {
        guard let definition = definitionsByKey[key] else { throw SettingsError.unknownKey(key) }
        return definition
    }

    public var helpLines: [String] {
        definitions.compactMap { definition in
            guard definition.access != .userOnly else { return nil }
            let values: String
            if case .enumeration(let allowed) = definition.valueType {
                values = allowed.joined(separator: "|")
            } else {
                values = definition.valueType.displayName
            }
            return "  \(definition.key) \(values) [\(definition.platforms.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ","))]"
        }
    }
}

public enum SettingsCaller: Sendable {
    case agent
    case user
}

public enum SettingsError: Error, Equatable, CustomStringConvertible {
    case unknownKey(String)
    case invalidValue(String)
    case unsupportedPlatform(String)
    case accessDenied(String)
    case insecureStorage
    case corruptStorage
    case operationFailed(String)

    public var description: String {
        switch self {
        case .unknownKey(let key): return "Unknown setting: \(key)"
        case .invalidValue: return "Invalid setting value"
        case .unsupportedPlatform(let key): return "Setting \(key) is unsupported on this platform"
        case .accessDenied(let key): return "Setting \(key) is not available to this caller"
        case .insecureStorage: return "Settings storage is not private and owned by the current user"
        case .corruptStorage: return "Settings storage is corrupt or uses an unsupported schema"
        case .operationFailed(let operation): return "Settings \(operation) failed"
        }
    }
}

public protocol SettingsBackend: AnyObject, Sendable {
    func configuredValue(for definition: SettingDefinition) throws -> String?
    func setConfiguredValue(_ value: String, for definition: SettingDefinition) throws
    func resetConfiguredValue(for definition: SettingDefinition) throws
}

public final class SettingsStore: @unchecked Sendable {
    public let registry: SettingsRegistry
    public let platform: SettingPlatform
    private let backend: SettingsBackend

    public init(registry: SettingsRegistry = .shared, platform: SettingPlatform = .current, backend: SettingsBackend) {
        self.registry = registry
        self.platform = platform
        self.backend = backend
    }

    public static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SettingsStore {
        #if os(macOS)
        return SettingsStore(backend: try UserDefaultsSettingsBackend())
        #else
        return SettingsStore(backend: try FileSettingsBackend(environment: environment))
        #endif
    }

    public func list(caller: SettingsCaller = .agent) throws -> JSONValue {
        let entries = try registry.definitions.compactMap { definition -> JSONValue? in
            guard canRead(definition, caller: caller) else { return nil }
            return try settingDocument(definition, includeDescription: false)
        }
        return .object(["settings": .array(entries)])
    }

    public func describe(_ key: String, caller: SettingsCaller = .agent) throws -> JSONValue {
        let definition = try visibleDefinition(key, caller: caller)
        return try settingDocument(definition, includeDescription: true)
    }

    public func get(_ key: String, caller: SettingsCaller = .agent) throws -> JSONValue {
        let definition = try accessibleDefinition(key, caller: caller, write: false)
        return try valueDocument(definition)
    }

    public func effectiveRawValue(_ key: String, caller: SettingsCaller = .agent) throws -> String {
        let definition = try accessibleDefinition(key, caller: caller, write: false)
        return try configuredRawValue(definition) ?? definition.defaultValue
    }

    public func set(_ key: String, rawValue: String, caller: SettingsCaller = .agent) throws -> JSONValue {
        let definition = try accessibleDefinition(key, caller: caller, write: true)
        let value = try definition.validated(rawValue)
        try backend.setConfiguredValue(value, for: definition)
        return mutationDocument(definition, value: value, configured: true)
    }

    public func reset(_ key: String, caller: SettingsCaller = .agent) throws -> JSONValue {
        let definition = try accessibleDefinition(key, caller: caller, write: true)
        try backend.resetConfiguredValue(for: definition)
        return mutationDocument(definition, value: definition.defaultValue, configured: false)
    }

    private func accessibleDefinition(
        _ key: String, caller: SettingsCaller, write: Bool
    ) throws -> SettingDefinition {
        let definition = try visibleDefinition(key, caller: caller)
        guard definition.platforms.contains(platform) else { throw SettingsError.unsupportedPlatform(key) }
        let allowed = write ? canWrite(definition, caller: caller) : canRead(definition, caller: caller)
        guard allowed else { throw SettingsError.accessDenied(key) }
        return definition
    }

    private func visibleDefinition(_ key: String, caller: SettingsCaller) throws -> SettingDefinition {
        let definition = try registry.definition(for: key)
        guard caller == .user || definition.access != .userOnly else {
            throw SettingsError.unknownKey(key)
        }
        return definition
    }

    private func canRead(_ definition: SettingDefinition, caller: SettingsCaller) -> Bool {
        caller == .user || definition.access != .userOnly
    }

    private func canWrite(_ definition: SettingDefinition, caller: SettingsCaller) -> Bool {
        if caller == .user { return true }
        return definition.access == .agentWritable
    }

    private func configuredRawValue(_ definition: SettingDefinition) throws -> String? {
        guard let value = try backend.configuredValue(for: definition) else { return nil }
        return try definition.validated(value)
    }

    private func settingDocument(_ definition: SettingDefinition, includeDescription: Bool) throws -> JSONValue {
        guard case .object(var object) = definition.document else { preconditionFailure() }
        let configured = try configuredRawValue(definition)
        object["value"] = definition.valueType.jsonValue(configured ?? definition.defaultValue)
        object["configured"] = configured.map(definition.valueType.jsonValue) ?? .null
        object["supportedOnCurrentPlatform"] = .bool(definition.platforms.contains(platform))
        if !includeDescription { object.removeValue(forKey: "summary") }
        addCompatibilityFields(to: &object, definition: definition, configured: configured)
        return .object(object)
    }

    private func valueDocument(_ definition: SettingDefinition) throws -> JSONValue {
        let configured = try configuredRawValue(definition)
        var object: [String: JSONValue] = [
            "key": .string(definition.key),
            "value": definition.valueType.jsonValue(configured ?? definition.defaultValue),
            "default": definition.valueType.jsonValue(definition.defaultValue),
            "configured": configured.map(definition.valueType.jsonValue) ?? .null,
        ]
        addCompatibilityFields(to: &object, definition: definition, configured: configured)
        return .object(object)
    }

    private func mutationDocument(
        _ definition: SettingDefinition, value: String, configured: Bool
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(definition.key),
            "value": definition.valueType.jsonValue(value),
            "configured": .bool(configured),
            "takesEffect": .string(definition.restartBehavior.rawValue),
        ]
        if definition.key == "startup-presentation" {
            object["startupPresentation"] = .string(value)
        }
        return .object(object)
    }

    private func addCompatibilityFields(
        to object: inout [String: JSONValue], definition: SettingDefinition, configured: String?
    ) {
        guard definition.key == "startup-presentation" else { return }
        object["builtInDefault"] = .string(definition.defaultValue)
        object["startupPresentation"] = .string(configured ?? definition.defaultValue)
    }
}

public final class UserDefaultsSettingsBackend: @unchecked Sendable, SettingsBackend {
    private static let domain = "com.headless.app"
    private static let canonicalPrefix = "HeadlessSetting."
    private let defaults: UserDefaults

    public convenience init() throws {
        try self.init(suiteName: Self.domain)
    }

    public init(suiteName: String) throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SettingsError.operationFailed("preferences access")
        }
        self.defaults = defaults
    }

    public func configuredValue(for definition: SettingDefinition) throws -> String? {
        let key = storageKey(for: definition)
        if let value = defaults.string(forKey: key) { return value }
        guard defaults.object(forKey: key) == nil else { throw SettingsError.corruptStorage }
        return nil
    }

    public func setConfiguredValue(_ value: String, for definition: SettingDefinition) throws {
        defaults.set(value, forKey: storageKey(for: definition))
        guard defaults.synchronize() else { throw SettingsError.operationFailed("write") }
    }

    public func resetConfiguredValue(for definition: SettingDefinition) throws {
        defaults.removeObject(forKey: storageKey(for: definition))
        guard defaults.synchronize() else { throw SettingsError.operationFailed("reset") }
    }


    private func storageKey(for definition: SettingDefinition) -> String {
        definition.macOSStorageKey ?? Self.canonicalPrefix + definition.key
    }
}

private struct SettingsFile: Codable {
    let schemaVersion: Int
    let values: [String: String]
}

public final class FileSettingsBackend: @unchecked Sendable, SettingsBackend {
    public static let maximumFileBytes = 65_536

    public let rootURL: URL
    private let registry: SettingsRegistry
    private static let fileName = "settings.json"
    private static let lockName = "settings.lock"

    public convenience init(
        environment: [String: String], registry: SettingsRegistry = .shared
    ) throws {
        let base: URL
        if let configured = environment["XDG_CONFIG_HOME"] {
            guard configured.hasPrefix("/") else { throw SettingsError.insecureStorage }
            base = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        try self.init(rootURL: base.appendingPathComponent("headless", isDirectory: true), registry: registry)
    }

    public init(rootURL: URL, registry: SettingsRegistry = .shared) throws {
        let standardized = rootURL.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw SettingsError.insecureStorage
        }
        self.rootURL = standardized
        self.registry = registry
    }

    public func configuredValue(for definition: SettingDefinition) throws -> String? {
        try withLockedValues { values, _ in values[definition.key] }
    }

    public func setConfiguredValue(_ value: String, for definition: SettingDefinition) throws {
        try withLockedValues { values, directory in
            values[definition.key] = value
            try write(values, to: directory)
        }
    }

    public func resetConfiguredValue(for definition: SettingDefinition) throws {
        try withLockedValues { values, directory in
            values.removeValue(forKey: definition.key)
            try write(values, to: directory)
        }
    }

    private func withLockedValues<T>(
        _ body: (inout [String: String], Int32) throws -> T
    ) throws -> T {
        let directory = try Self.openPrivateDirectory(rootURL)
        defer { close(directory) }
        let lock = Self.openLock(in: directory)
        guard lock >= 0 else { throw SettingsError.insecureStorage }
        defer { close(lock) }
        try Self.validatePrivateRegularFile(lock)
        guard flock(lock, LOCK_EX) == 0 else { throw SettingsError.operationFailed("lock") }
        defer { _ = flock(lock, LOCK_UN) }
        var values = try read(from: directory)
        return try body(&values, directory)
    }

    private func read(from directory: Int32) throws -> [String: String] {
        let descriptor = openat(directory, Self.fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return [:] }
            throw SettingsError.insecureStorage
        }
        defer { close(descriptor) }
        try Self.validatePrivateRegularFile(descriptor)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0,
              info.st_size <= Self.maximumFileBytes else { throw SettingsError.corruptStorage }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            #if canImport(Darwin)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            #else
            let count = Glibc.read(descriptor, &buffer, buffer.count)
            #endif
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw SettingsError.operationFailed("read") }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= Self.maximumFileBytes else { throw SettingsError.corruptStorage }
        }
        guard let settings = try? JSONDecoder().decode(SettingsFile.self, from: data),
              settings.schemaVersion == 1 else { throw SettingsError.corruptStorage }
        guard let canonical = try? JSONEncoder.headlessSettingsEncoder.encode(settings),
              canonical == data else { throw SettingsError.corruptStorage }
        guard settings.values.count <= registry.definitions.count else { throw SettingsError.corruptStorage }
        for (key, value) in settings.values {
            guard let definition = try? registry.definition(for: key),
                  (try? definition.validated(value)) != nil else {
                throw SettingsError.corruptStorage
            }
        }
        return settings.values
    }

    private func write(_ values: [String: String], to directoryDescriptor: Int32) throws {
        let data = try JSONEncoder.headlessSettingsEncoder.encode(
            SettingsFile(schemaVersion: 1, values: values)
        )
        guard data.count <= Self.maximumFileBytes else { throw SettingsError.corruptStorage }
        let temporaryName = ".settings.tmp-\(UUID().uuidString)"
        let descriptor = openat(
            directoryDescriptor, temporaryName,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600
        )
        guard descriptor >= 0 else { throw SettingsError.operationFailed("temporary file creation") }
        var removeTemporary = true
        defer {
            close(descriptor)
            if removeTemporary { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
        }
        try Self.validatePrivateRegularFile(descriptor)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                #else
                let count = Glibc.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SettingsError.operationFailed("write") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw SettingsError.operationFailed("sync") }
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, Self.fileName) == 0 else {
            throw SettingsError.operationFailed("activation")
        }
        removeTemporary = false
        guard fsync(directoryDescriptor) == 0 else { throw SettingsError.operationFailed("directory sync") }
    }

    private static func openPrivateDirectory(_ url: URL) throws -> Int32 {
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path, !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw SettingsError.operationFailed("parent directory creation")
            }
        }
        var descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        if descriptor < 0, errno == ENOENT {
            let created = mkdir(url.path, 0o700) == 0
            guard created || errno == EEXIST else {
                throw SettingsError.operationFailed("directory creation")
            }
            descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
            if created, descriptor >= 0, fchmod(descriptor, 0o700) != 0 {
                close(descriptor)
                throw SettingsError.operationFailed("directory permissions")
            }
        }
        guard descriptor >= 0 else { throw SettingsError.insecureStorage }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else {
            close(descriptor)
            throw SettingsError.insecureStorage
        }
        return descriptor
    }

    private static func openLock(in directory: Int32) -> Int32 {
        // A concurrently created directory can be visible before its entries
        // on some filesystems. Retry only the bounded first-use ENOENT case.
        for attempt in 0..<20 {
            let descriptor = openat(
                directory, lockName, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600
            )
            if descriptor >= 0 || errno != ENOENT { return descriptor }
            if attempt < 19 { usleep(1_000) }
        }
        return -1
    }

    private static func validatePrivateRegularFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, (info.st_mode & 0o077) == 0 else {
            throw SettingsError.insecureStorage
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw SettingsError.operationFailed("permissions") }
    }
}

private extension JSONEncoder {
    static let headlessSettingsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
