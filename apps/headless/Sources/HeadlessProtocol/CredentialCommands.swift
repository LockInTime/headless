import Foundation

public struct CredentialOrigin: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.allSatisfy(\.isASCII),
              let url = try? normalizedWebURL(trimmed) else {
            throw CredentialCommandError.invalidOrigin
        }
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              !host.contains("%"), host.unicodeScalars.allSatisfy(\.isASCII),
              url.path.isEmpty || url.path == "/",
              url.query == nil, url.fragment == nil else {
            throw CredentialCommandError.invalidOrigin
        }
        guard scheme == "https" || (scheme == "http" && isCredentialDevelopmentHost(host)) else {
            throw CredentialCommandError.invalidOrigin
        }
        guard url.user == nil, url.password == nil else {
            throw CredentialCommandError.invalidOrigin
        }

        var canonical = "\(scheme)://"
        canonical += host.contains(":") ? "[\(host)]" : host
        if let port = url.port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            canonical += ":\(port)"
        }
        self.rawValue = canonical
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private func isCredentialDevelopmentHost(_ host: String) -> Bool {
    ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
}

public struct CredentialAlias: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty, bytes.count <= 64,
              bytes.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122) || [45, 46, 95].contains(byte)
              }), bytes[0] != 45, bytes[0] != 46, bytes[0] != 95 else {
            throw CredentialCommandError.invalidAlias
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum CredentialCommandError: Error, Equatable, CustomStringConvertible {
    case invalidOrigin
    case invalidAlias
    case invalidArguments

    public var description: String {
        switch self {
        case .invalidOrigin:
            return "Credential origins must be exact HTTPS origins; HTTP is limited to localhost loopback development."
        case .invalidAlias:
            return "Credential aliases must be 1-64 letters, numbers, periods, underscores, or hyphens."
        case .invalidArguments:
            return "Invalid credential command arguments. Password values are accepted only by the interactive prompt."
        }
    }
}

public enum CredentialCLICommand: Equatable, Sendable {
    case list(origin: CredentialOrigin?)
    case add(origin: CredentialOrigin, alias: CredentialAlias)
    case rename(origin: CredentialOrigin, alias: CredentialAlias, newAlias: CredentialAlias)
    case remove(origin: CredentialOrigin, alias: CredentialAlias)

    public var brokerArguments: [String] {
        switch self {
        case .list(let origin):
            return ["list"] + (origin.map { ["--origin", $0.rawValue] } ?? [])
        case .add(let origin, let alias):
            return ["add", "--origin", origin.rawValue, "--alias", alias.rawValue, "--interactive"]
        case .rename(let origin, let alias, let newAlias):
            return [
                "rename", "--origin", origin.rawValue, "--alias", alias.rawValue,
                "--to", newAlias.rawValue,
            ]
        case .remove(let origin, let alias):
            return ["remove", "--origin", origin.rawValue, "--alias", alias.rawValue]
        }
    }
}
