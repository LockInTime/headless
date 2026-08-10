import Foundation

public enum LocalCommand: Equatable, Sendable {
    case help
    case capabilities
    case runtime
    case start
}

public struct CLIInvocation: Equatable, Sendable {
    public let local: LocalCommand?
    public let request: CommandRequest?
    public let jsonOutput: Bool

    public init(local: LocalCommand? = nil, request: CommandRequest? = nil, jsonOutput: Bool = false) {
        self.local = local
        self.request = request
        self.jsonOutput = jsonOutput
    }
}

public func requestTimeout(for request: CommandRequest) -> TimeInterval {
    if let milliseconds = request.parameters["timeoutMs"]?.numberValue {
        return min(125, max(10, milliseconds / 1_000 + 5))
    }
    if request.command == .tour || request.command == .flowRun { return 125 }
    if request.command == .recordStop { return 30 }
    if request.command == .screenshot {
        return request.parameters["series"]?.stringValue == nil ? 30 : 125
    }
    return 15
}

public enum CLIParseError: Error, Equatable, CustomStringConvertible {
    case missingCommand
    case unknownCommand(String)
    case missingArgument(String)
    case invalidOption(String)
    case invalidNumber(String)
    case conflictingTarget

    public var description: String {
        switch self {
        case .missingCommand: return "Missing command. Run `headless help`."
        case .unknownCommand(let command): return "Unknown command: \(command)"
        case .missingArgument(let value): return "Missing argument: \(value)"
        case .invalidOption(let option): return "Unknown or misplaced option: \(option)"
        case .invalidNumber(let value): return "Expected a number, received: \(value)"
        case .conflictingTarget: return "Use either an element ref or --role/--name, not both"
        }
    }
}

public struct CLIParser {
    public init() {}

    public func parse(_ rawArguments: [String]) throws -> CLIInvocation {
        var arguments = rawArguments
        let literalArguments: [String]
        if let sentinel = arguments.firstIndex(of: "--") {
            literalArguments = Array(arguments[arguments.index(after: sentinel)...])
            arguments.removeSubrange(sentinel...)
        } else {
            literalArguments = []
        }
        let jsonOutput = removeFlag("--json", from: &arguments)
        let session = try removeOption("--session", from: &arguments)
        if let session { try validateIdentifier(session, field: "session") }
        arguments.append(contentsOf: literalArguments)
        guard let command = arguments.first else { throw CLIParseError.missingCommand }
        arguments.removeFirst()

        switch command {
        case "help", "--help", "-h":
            try requireEmpty(arguments)
            return CLIInvocation(local: .help, jsonOutput: jsonOutput)
        case "capabilities":
            try requireEmpty(arguments)
            return CLIInvocation(local: .capabilities, jsonOutput: true)
        case "runtime":
            try requireEmpty(arguments)
            return CLIInvocation(local: .runtime, jsonOutput: true)
        case "start":
            try requireEmpty(arguments)
            return CLIInvocation(local: .start, jsonOutput: jsonOutput)
        case "status":
            try requireEmpty(arguments)
            return remote(.ping, session: session, jsonOutput: jsonOutput)
        case "stop":
            try requireEmpty(arguments)
            return remote(.shutdown, session: session, jsonOutput: jsonOutput)
        case "session":
            return try parseSession(arguments, jsonOutput: jsonOutput)
        case "visit":
            guard arguments.count == 1 else { throw CLIParseError.missingArgument("URL") }
            let url = try normalizedWebURL(arguments[0])
            return remote(.visit, session: session, parameters: ["url": .string(url.absoluteString)], jsonOutput: jsonOutput)
        case "inspect":
            return try parseInspect(arguments, session: session, jsonOutput: jsonOutput)
        case "click":
            return try parseTargeted(.click, arguments: arguments, session: session, jsonOutput: jsonOutput)
        case "fill":
            guard arguments.count == 2 else { throw CLIParseError.missingArgument("TARGET TEXT") }
            return remote(.fill, session: session, parameters: [
                "target": .string(arguments[0]), "value": .string(arguments[1]),
            ], jsonOutput: jsonOutput)
        case "press":
            guard arguments.count == 1 else { throw CLIParseError.missingArgument("KEY") }
            return remote(.press, session: session, parameters: ["key": .string(arguments[0])], jsonOutput: jsonOutput)
        case "scroll":
            return try parseScroll(arguments, session: session, jsonOutput: jsonOutput)
        case "back":
            try requireEmpty(arguments)
            return remote(.back, session: session, jsonOutput: jsonOutput)
        case "reload":
            try requireEmpty(arguments)
            return remote(.reload, session: session, jsonOutput: jsonOutput)
        case "wait":
            return try parseWait(arguments, session: session, jsonOutput: jsonOutput)
        case "tour":
            return try parseTour(arguments, session: session, jsonOutput: jsonOutput)
        case "capture-info":
            try requireEmpty(arguments)
            return remote(.captureInfo, session: session, jsonOutput: jsonOutput)
        case "screenshot":
            return try parseScreenshot(arguments, session: session, jsonOutput: jsonOutput)
        case "artifacts":
            guard arguments == ["list"] else { throw CLIParseError.missingArgument("artifacts list") }
            return remote(.artifactList, session: session, jsonOutput: jsonOutput)
        case "record":
            return try parseRecord(arguments, session: session, jsonOutput: jsonOutput)
        case "qa":
            guard let subcommand = arguments.first else { throw CLIParseError.missingArgument("qa report|clear") }
            let trailing = Array(arguments.dropFirst())
            switch subcommand {
            case "report":
                try requireEmpty(trailing)
                return remote(.qaReport, session: session, jsonOutput: jsonOutput)
            case "clear":
                try requireEmpty(trailing)
                return remote(.qaClear, session: session, jsonOutput: jsonOutput)
            default:
                throw CLIParseError.unknownCommand("qa \(subcommand)")
            }
        case "console":
            return try parseConsole(arguments, session: session, jsonOutput: jsonOutput)
        case "network":
            return try parseNetwork(arguments, session: session, jsonOutput: jsonOutput)
        case "styles":
            return try parseStyles(arguments, session: session, jsonOutput: jsonOutput)
        case "cookies":
            return try parseCookies(arguments, session: session, jsonOutput: jsonOutput)
        case "storage":
            return try parseStorage(arguments, session: session, jsonOutput: jsonOutput)
        case "visual":
            return try parseVisual(arguments, session: session, jsonOutput: jsonOutput)
        case "performance":
            guard arguments == ["get"] else { throw CLIParseError.missingArgument("performance get") }
            return remote(.performanceGet, session: session, jsonOutput: jsonOutput)
        case "animations":
            guard arguments == ["list"] else { throw CLIParseError.missingArgument("animations list") }
            return remote(.animationList, session: session, jsonOutput: jsonOutput)
        case "report":
            return try parseReport(arguments, session: session, jsonOutput: jsonOutput)
        case "flow":
            return try parseFlow(arguments, session: session, jsonOutput: jsonOutput)
        default:
            throw CLIParseError.unknownCommand(command)
        }
    }

    private func parseSession(_ arguments: [String], jsonOutput: Bool) throws -> CLIInvocation {
        guard let subcommand = arguments.first else { throw CLIParseError.missingArgument("session subcommand") }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "create":
            let name = rest.first ?? "default"
            guard rest.count <= 1 else { throw CLIParseError.invalidOption(rest[1]) }
            try validateIdentifier(name, field: "session")
            return remote(.sessionCreate, parameters: ["name": .string(name)], jsonOutput: jsonOutput)
        case "list":
            try requireEmpty(rest)
            return remote(.sessionList, jsonOutput: jsonOutput)
        case "close":
            guard rest.count == 1 else { throw CLIParseError.missingArgument("session name") }
            try validateIdentifier(rest[0], field: "session")
            return remote(.sessionClose, session: rest[0], jsonOutput: jsonOutput)
        default:
            throw CLIParseError.unknownCommand("session \(subcommand)")
        }
    }

    private func parseInspect(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        var args = arguments
        let interactive = removeFlag("--interactive", from: &args)
        let includeText = removeFlag("--text", from: &args)
        let context = try removeOption("--context", from: &args)
        let task = try removeOption("--task", from: &args)
        let within = try removeOption("--within", from: &args)
        let limit = try removeOption("--limit", from: &args)
        let budget = try removeOption("--budget", from: &args)
        let depth = try removeOption("--depth", from: &args)
        try requireEmpty(args)

        if let context, !["summary", "outline", "text", "actions", "full"].contains(context) {
            throw CLIParseError.invalidOption(context)
        }
        if let task, task.isEmpty || task.utf8.count > 512 {
            throw CLIParseError.invalidOption("--task")
        }
        if let within {
            guard within.hasPrefix("@r"), !within.dropFirst(2).isEmpty,
                  within.dropFirst(2).allSatisfy(\.isNumber) else {
                throw CLIParseError.invalidOption("--within")
            }
        }

        let mode = context ?? (interactive ? "actions" : "full")
        var parameters: [String: JSONValue] = [
            "interactive": .bool(interactive || mode == "actions"),
            "text": .bool(includeText),
            "context": .string(mode),
        ]
        if let task { parameters["task"] = .string(task) }
        if let within { parameters["within"] = .string(within) }
        if let limit { parameters["limit"] = .number(try inspectNumber(limit, option: "--limit", minimum: 1, maximum: 250)) }
        if let budget { parameters["budget"] = .number(try inspectNumber(budget, option: "--budget", minimum: 256, maximum: 16_000)) }
        if let depth { parameters["depth"] = .number(try inspectNumber(depth, option: "--depth", minimum: 0, maximum: 8)) }
        return remote(.inspect, session: session, parameters: parameters, jsonOutput: jsonOutput)
    }

    private func inspectNumber(
        _ value: String, option: String, minimum: Double, maximum: Double
    ) throws -> Double {
        guard let number = Double(value), number.isFinite, number.rounded() == number,
              number >= minimum, number <= maximum else {
            throw CLIParseError.invalidOption(option)
        }
        return number
    }

    private func parseTargeted(
        _ command: CommandName,
        arguments: [String],
        session: String?,
        jsonOutput: Bool
    ) throws -> CLIInvocation {
        var args = arguments
        let role = try removeOption("--role", from: &args)
        let name = try removeOption("--name", from: &args)
        if let target = args.first {
            guard args.count == 1 else { throw CLIParseError.invalidOption(args[1]) }
            guard role == nil, name == nil else { throw CLIParseError.conflictingTarget }
            return remote(command, session: session, parameters: ["target": .string(target)], jsonOutput: jsonOutput)
        }
        guard role != nil || name != nil else { throw CLIParseError.missingArgument("element ref or --role/--name") }
        var parameters: [String: JSONValue] = [:]
        if let role { parameters["role"] = .string(role) }
        if let name { parameters["name"] = .string(name) }
        return remote(command, session: session, parameters: parameters, jsonOutput: jsonOutput)
    }

    private func parseScroll(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        var args = arguments
        let amountText = try removeOption("--amount", from: &args)
        let direction = args.first ?? "down"
        guard ["up", "down", "top", "bottom"].contains(direction) else {
            throw CLIParseError.invalidOption(direction)
        }
        guard args.count <= 1 else { throw CLIParseError.invalidOption(args[1]) }
        var parameters: [String: JSONValue] = ["direction": .string(direction)]
        if let amountText {
            guard let amount = Double(amountText), amount.isFinite,
                  ProtocolBounds.scrollAmount.contains(amount) else {
                throw CLIParseError.invalidNumber(amountText)
            }
            parameters["amount"] = .number(amount)
        }
        return remote(.scroll, session: session, parameters: parameters, jsonOutput: jsonOutput)
    }

    private func parseWait(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        var args = arguments
        let url = try removeOption("--url", from: &args)
        let text = try removeOption("--text", from: &args)
        let timeoutText = try removeOption("--timeout", from: &args)
        let settled = removeFlag("--settled", from: &args)
        try requireEmpty(args)
        var parameters: [String: JSONValue] = ["settled": .bool(settled || (url == nil && text == nil))]
        if let url { parameters["url"] = .string(url) }
        if let text { parameters["text"] = .string(text) }
        if let timeoutText {
            guard let timeout = Double(timeoutText), timeout >= 100, timeout <= 120_000 else {
                throw CLIParseError.invalidNumber(timeoutText)
            }
            parameters["timeoutMs"] = .number(timeout)
        }
        return remote(.wait, session: session, parameters: parameters, jsonOutput: jsonOutput)
    }

    private func parseTour(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        var args = arguments
        let fullPage = removeFlag("--full-page", from: &args)
        let paceText = try removeOption("--pace", from: &args)
        try requireEmpty(args)
        var parameters: [String: JSONValue] = ["fullPage": .bool(fullPage || arguments.isEmpty)]
        if let paceText {
            guard let pace = Double(paceText), pace >= 100, pace <= 5_000 else {
                throw CLIParseError.invalidNumber(paceText)
            }
            parameters["pace"] = .number(pace)
        }
        return remote(.tour, session: session, parameters: parameters, jsonOutput: jsonOutput)
    }

    private func parseScreenshot(
        _ arguments: [String], session: String?, jsonOutput: Bool
    ) throws -> CLIInvocation {
        var args = arguments
        let fullPage = removeFlag("--full-page", from: &args)
        let everyViewport = removeFlag("--every-viewport", from: &args)
        let bySection = removeFlag("--by-section", from: &args)
        let role = try removeOption("--role", from: &args)
        let name = try removeOption("--name", from: &args)
        let output = try removeOption("--output", from: &args)
        let formatText = try removeOption("--format", from: &args)
        let clipboard = removeFlag("--clipboard", from: &args)
        let format = try screenshotFormat(explicit: formatText, output: output)
        if everyViewport && bySection { throw CLIParseError.conflictingTarget }
        if everyViewport || bySection {
            try requireEmpty(args)
            guard !fullPage, role == nil, name == nil else { throw CLIParseError.conflictingTarget }
            guard format.isImage else { throw CLIParseError.invalidOption("--format pdf") }
            guard !clipboard else { throw CLIParseError.invalidOption("--clipboard") }
            var parameters: [String: JSONValue] = [
                "fullPage": .bool(false),
                "series": .string(everyViewport ? "viewport" : "section"),
                "format": .string(format.rawValue),
            ]
            if let output {
                let prefix = try screenshotSeriesPrefix(output)
                parameters["outputPrefix"] = .string(prefix)
            }
            return remote(.screenshot, session: session, parameters: parameters, jsonOutput: jsonOutput)
        }
        if format == .pdf && (!fullPage || role != nil || name != nil || !args.isEmpty) {
            throw CLIParseError.invalidOption("PDF screenshots require --full-page without an element target")
        }
        var parameters: [String: JSONValue] = ["fullPage": .bool(fullPage)]
        parameters["format"] = .string(format.rawValue)
        if clipboard { parameters["clipboard"] = .bool(true) }
        if let output {
            try validateArtifactName(output, expectedExtensions: format.artifactExtensions)
            parameters["output"] = .string(output)
        }
        if let target = args.first {
            guard args.count == 1 else { throw CLIParseError.invalidOption(args[1]) }
            guard role == nil, name == nil, !fullPage else { throw CLIParseError.conflictingTarget }
            parameters["target"] = .string(target)
        } else {
            guard !fullPage || (role == nil && name == nil) else { throw CLIParseError.conflictingTarget }
            if let role { parameters["role"] = .string(role) }
            if let name { parameters["name"] = .string(name) }
        }
        return remote(.screenshot, session: session, parameters: parameters, jsonOutput: jsonOutput)
    }

    private func screenshotSeriesPrefix(_ value: String) throws -> String {
        let lower = value.lowercased()
        let prefix: String
        if lower.hasSuffix(".png") {
            prefix = String(value.dropLast(4))
        } else if lower.hasSuffix(".jpg") {
            prefix = String(value.dropLast(4))
        } else if lower.hasSuffix(".jpeg") {
            prefix = String(value.dropLast(5))
        } else {
            prefix = value
        }
        try validateArtifactPrefix(prefix)
        return prefix
    }

    private func parseRecord(
        _ arguments: [String], session: String?, jsonOutput: Bool
    ) throws -> CLIInvocation {
        guard let subcommand = arguments.first else {
            throw CLIParseError.missingArgument("record start|status|stop")
        }
        var args = Array(arguments.dropFirst())
        switch subcommand {
        case "start":
            let output = try removeOption("--output", from: &args)
            let fpsText = try removeOption("--fps", from: &args)
            let formatText = try removeOption("--format", from: &args)
            let qualityText = try removeOption("--quality", from: &args)
            try requireEmpty(args)
            var parameters: [String: JSONValue] = [:]
            let format = try recordingFormat(explicit: formatText, output: output)
            if let output {
                try validateArtifactName(output, expectedExtensions: [format.fileExtension])
                parameters["output"] = .string(output)
            }
            parameters["format"] = .string(format.rawValue)
            if let fpsText {
                guard let fps = Double(fpsText), fps >= 1, fps <= 30 else {
                    throw CLIParseError.invalidNumber(fpsText)
                }
                parameters["fps"] = .number(fps)
            }
            if let qualityText {
                let quality = try RecordingQuality.parse(qualityText)
                parameters["quality"] = .string(quality.rawValue)
            }
            return remote(.recordStart, session: session, parameters: parameters, jsonOutput: jsonOutput)
        case "status":
            try requireEmpty(args)
            return remote(.recordStatus, session: session, jsonOutput: jsonOutput)
        case "stop":
            let output = try removeOption("--output", from: &args)
            try requireEmpty(args)
            var parameters: [String: JSONValue] = [:]
            if let output {
                try validateArtifactName(output, expectedExtensions: RecordingFormat.artifactExtensions)
                parameters["output"] = .string(output)
            }
            return remote(.recordStop, session: session, parameters: parameters, jsonOutput: jsonOutput)
        default:
            throw CLIParseError.unknownCommand("record \(subcommand)")
        }
    }

    private func parseConsole(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        guard arguments.first == "list" else { throw CLIParseError.missingArgument("console list") }
        var args = Array(arguments.dropFirst())
        let level = try removeOption("--level", from: &args) ?? "all"
        let limit = try removeOption("--limit", from: &args)
        try requireEmpty(args)
        guard ["all", "log", "info", "debug", "warn", "error", "assert"].contains(level) else {
            throw CLIParseError.invalidOption(level)
        }
        var parameters: [String: JSONValue] = ["level": .string(level)]
        if let limit { parameters["limit"] = .number(try diagnosticLimit(limit)) }
        return remote(.consoleList, session: session, parameters: parameters, jsonOutput: jsonOutput)
    }

    private func parseNetwork(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        guard let subcommand = arguments.first else { throw CLIParseError.missingArgument("network list|get REQUEST_ID") }
        var args = Array(arguments.dropFirst())
        switch subcommand {
        case "list":
            let failed = removeFlag("--failed", from: &args)
            let status = try removeOption("--status", from: &args)
            let limit = try removeOption("--limit", from: &args)
            try requireEmpty(args)
            var parameters: [String: JSONValue] = ["failed": .bool(failed)]
            if let status {
                guard let code = Double(status), code >= 100, code <= 599 else { throw CLIParseError.invalidNumber(status) }
                parameters["status"] = .number(code)
            }
            if let limit { parameters["limit"] = .number(try diagnosticLimit(limit)) }
            return remote(.networkList, session: session, parameters: parameters, jsonOutput: jsonOutput)
        case "get":
            guard args.count == 1 else { throw CLIParseError.missingArgument("network get REQUEST_ID") }
            return remote(.networkGet, session: session, parameters: ["requestId": .string(args[0])], jsonOutput: jsonOutput)
        case "emulate":
            let offline = removeFlag("--offline", from: &args)
            let latency = try removeOption("--latency", from: &args)
            let down = try removeOption("--download-kbps", from: &args)
            let up = try removeOption("--upload-kbps", from: &args)
            try requireEmpty(args)
            var parameters: [String: JSONValue] = ["offline": .bool(offline)]
            for (option, value, range) in [
                ("latencyMs", latency, ProtocolBounds.networkLatencyMilliseconds),
                ("downloadKbps", down, ProtocolBounds.networkThroughputKbps),
                ("uploadKbps", up, ProtocolBounds.networkThroughputKbps),
            ] {
                if let value {
                    guard let number = Double(value), number.isFinite, range.contains(number) else {
                        throw CLIParseError.invalidNumber(value)
                    }
                    parameters[option] = .number(number)
                }
            }
            return remote(.networkEmulate, session: session, parameters: parameters, jsonOutput: jsonOutput)
        case "mock":
            guard let action = args.first else { throw CLIParseError.missingArgument("network mock set|clear") }
            args.removeFirst()
            if action == "clear" {
                try requireEmpty(args)
                return remote(.networkMockClear, session: session, jsonOutput: jsonOutput)
            }
            guard action == "set" else { throw CLIParseError.unknownCommand("network mock \(action)") }
            guard let url = args.first else { throw CLIParseError.missingArgument("URL") }
            args.removeFirst()
            let status = try removeOption("--status", from: &args)
            let body = try removeOption("--body", from: &args)
            let contentType = try removeOption("--content-type", from: &args)
            try requireEmpty(args)
            guard let body else { throw CLIParseError.missingArgument("--body") }
            var parameters: [String: JSONValue] = ["url": .string(try normalizedWebURL(url).absoluteString), "body": .string(body)]
            if let status {
                guard let code = Double(status), code >= 100, code <= 599 else { throw CLIParseError.invalidNumber(status) }
                parameters["status"] = .number(code)
            }
            if let contentType { parameters["contentType"] = .string(contentType) }
            return remote(.networkMockSet, session: session, parameters: parameters, jsonOutput: jsonOutput)
        default:
            throw CLIParseError.unknownCommand("network \(subcommand)")
        }
    }

    private func parseStyles(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        guard arguments.first == "get" else { throw CLIParseError.missingArgument("styles get TARGET") }
        var args = Array(arguments.dropFirst())
        let properties = try removeOptions("--property", from: &args)
        let invocation = try parseTargeted(.stylesGet, arguments: args, session: session, jsonOutput: jsonOutput)
        var parameters = invocation.request?.parameters ?? [:]
        if !properties.isEmpty { parameters["properties"] = .array(properties.map(JSONValue.string)) }
        return remote(.stylesGet, session: session, parameters: parameters, jsonOutput: jsonOutput)
    }

    private func parseCookies(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        guard arguments.first == "list" else { throw CLIParseError.missingArgument("cookies list") }
        var args = Array(arguments.dropFirst())
        let includeValues = removeFlag("--values", from: &args)
        try requireEmpty(args)
        return remote(.cookiesList, session: session, parameters: ["includeValues": .bool(includeValues)], jsonOutput: jsonOutput)
    }

    private func parseStorage(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        guard arguments.first == "list" else { throw CLIParseError.missingArgument("storage list") }
        var args = Array(arguments.dropFirst())
        let scope = try removeOption("--scope", from: &args) ?? "all"
        let includeValues = removeFlag("--values", from: &args)
        try requireEmpty(args)
        guard ["local", "session", "all"].contains(scope) else { throw CLIParseError.invalidOption(scope) }
        return remote(.storageList, session: session,
                      parameters: ["scope": .string(scope), "includeValues": .bool(includeValues)], jsonOutput: jsonOutput)
    }

    private func parseVisual(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        guard arguments.first == "compare", arguments.count >= 3 else { throw CLIParseError.missingArgument("visual compare BEFORE.png AFTER.png") }
        var args = Array(arguments.dropFirst())
        let output = try removeOption("--output", from: &args)
        guard args.count == 2 else { throw CLIParseError.missingArgument("visual compare BEFORE.png AFTER.png") }
        try validateArtifactName(args[0], expectedExtension: "png"); try validateArtifactName(args[1], expectedExtension: "png")
        var parameters: [String: JSONValue] = ["before": .string(args[0]), "after": .string(args[1])]
        if let output { try validateArtifactName(output, expectedExtension: "png"); parameters["output"] = .string(output) }
        return remote(.visualCompare, session: session, parameters: parameters, jsonOutput: jsonOutput)
    }

    private func parseReport(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        guard arguments.first == "create" else { throw CLIParseError.missingArgument("report create") }
        var args = Array(arguments.dropFirst())
        let output = try removeOption("--output", from: &args)
        try requireEmpty(args)
        var parameters: [String: JSONValue] = [:]
        if let output { try validateArtifactName(output, expectedExtension: "json"); parameters["output"] = .string(output) }
        return remote(.reportCreate, session: session, parameters: parameters, jsonOutput: jsonOutput)
    }

    private func parseFlow(_ arguments: [String], session: String?, jsonOutput: Bool) throws -> CLIInvocation {
        guard let action = arguments.first else { throw CLIParseError.missingArgument("flow start|stop|run") }
        var args = Array(arguments.dropFirst())
        switch action {
        case "start": try requireEmpty(args); return remote(.flowStart, session: session, jsonOutput: jsonOutput)
        case "stop":
            let output = try removeOption("--output", from: &args); try requireEmpty(args)
            var parameters: [String: JSONValue] = [:]
            if let output { try validateArtifactName(output, expectedExtension: "json"); parameters["output"] = .string(output) }
            return remote(.flowStop, session: session, parameters: parameters, jsonOutput: jsonOutput)
        case "run":
            guard args.count == 1 else { throw CLIParseError.missingArgument("flow run FLOW.json") }
            try validateArtifactName(args[0], expectedExtension: "json")
            return remote(.flowRun, session: session, parameters: ["input": .string(args[0])], jsonOutput: jsonOutput)
        default: throw CLIParseError.unknownCommand("flow \(action)")
        }
    }

    private func diagnosticLimit(_ value: String) throws -> Double {
        guard let number = Double(value), number >= 1, number <= 200 else { throw CLIParseError.invalidNumber(value) }
        return number
    }

    private func remote(
        _ command: CommandName,
        session: String? = nil,
        parameters: [String: JSONValue] = [:],
        jsonOutput: Bool
    ) -> CLIInvocation {
        CLIInvocation(
            request: CommandRequest(command: command, session: session, parameters: parameters),
            jsonOutput: jsonOutput
        )
    }

    private func removeFlag(_ flag: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else { return false }
        arguments.remove(at: index)
        return true
    }

    private func removeOption(_ option: String, from arguments: inout [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: option) else { return nil }
        guard index + 1 < arguments.count else { throw CLIParseError.missingArgument(option) }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    private func removeOptions(_ option: String, from arguments: inout [String]) throws -> [String] {
        var values: [String] = []
        while let index = arguments.firstIndex(of: option) {
            guard index + 1 < arguments.count else { throw CLIParseError.missingArgument(option) }
            values.append(arguments[index + 1])
            arguments.removeSubrange(index...(index + 1))
        }
        return values
    }

    private func requireEmpty(_ arguments: [String]) throws {
        if let first = arguments.first { throw CLIParseError.invalidOption(first) }
    }
}

public let agentHelp = """
headless — deterministic browser control for agents

Core workflow:
  headless start
  headless session create qa
  headless --session qa visit localhost:3000/designers/dashboard
  headless --session qa inspect --context summary --task "click Continue"
  headless --session qa tour --full-page
  headless --session qa click --role button --name Continue
  headless --session qa wait --settled
  headless --session qa capture-info

Commands:
  start | status | stop | runtime
  session create [NAME] | session list | session close NAME
  visit URL
  inspect [--context summary|outline|text|actions|full] [--task TEXT]
          [--within @rN] [--limit N] [--budget TOKENS] [--depth N] [--text]
  click REF | click --role ROLE [--name NAME]
  fill REF TEXT | fill REF -- TEXT_WITH_LITERAL_FLAGS | press KEY
  scroll [up|down|top|bottom] [--amount PX]
  back | reload
  wait [--settled] [--url PATTERN] [--text TEXT] [--timeout MS]
  tour [--full-page] [--pace PX_PER_SECOND]
  capture-info
  screenshot [REF | --role ROLE --name NAME | --full-page] [--format png|jpg|jpeg] [--output FILE] [--clipboard]
  screenshot --full-page --format pdf [--output FILE.pdf]
  screenshot --every-viewport|--by-section [--format png|jpg|jpeg] [--output PREFIX]
  artifacts list
  record start [--fps N] [--format mp4|mov|webm|gif] [--quality fast|balanced|high] [--output FILE]
  record status | record stop [--output FILE]
  qa report | qa clear
  console list [--level LEVEL] [--limit N]
  network list [--failed] [--status CODE] [--limit N]
  network get REQUEST_ID
  network emulate [--offline] [--latency MS] [--download-kbps N] [--upload-kbps N]
  network mock set URL --body BODY [--status CODE] [--content-type MIME]
  network mock clear
  styles get REF | styles get --role ROLE [--name NAME] [--property CSS_PROPERTY]
  cookies list [--values]
  storage list [--scope local|session|all] [--values]
  visual compare BEFORE.png AFTER.png [--output DIFF.png]
  performance get | animations list
  flow start | flow stop [--output FLOW.json] | flow run FLOW.json
  report create [--output REPORT.json]
  capabilities

Global options:
  --session NAME   target a named browser session
  --               stop parsing global options; quote multi-word fill values
"""

public let capabilitiesDocument: JSONValue = .object([
    "protocolVersion": .string(headlessProtocolVersion),
    "transport": .array([.string("local-unix-socket")]),
    "commands": .array(CommandName.allCases.map { .string($0.rawValue) }),
    "artifacts": .array([.string("png"), .string("jpg"), .string("jpeg"), .string("pdf"), .string("mp4"), .string("mov"), .string("webm"), .string("gif"), .string("json")]),
    "screenshotFormats": .array([.string("png"), .string("jpg"), .string("jpeg"), .string("pdf")]),
    "pdfScreenshots": .string("full-page only"),
    "screenshotClipboard": .string("macOS image screenshots only"),
    "recordingFormats": .array([.string("mp4"), .string("mov"), .string("webm"), .string("gif")]),
    "recordingQuality": .array([.string("fast"), .string("balanced"), .string("high")]),
    "recordingProviders": .array([.string("browser-ffmpeg")]),
    "inspectContexts": .array([.string("summary"), .string("outline"), .string("text"), .string("actions"), .string("full")]),
    "inspectPruning": .object([
        "regionReferences": .string("@rN"),
        "maximumItems": .number(250),
        "budgetRangeEstimatedTokens": .array([.number(256), .number(16_000)]),
        "maximumOutlineDepth": .number(8),
    ]),
    "screenshotSeries": .array([.string("viewport"), .string("section")]),
    "security": .object([
        "tcpListener": .bool(false),
        "arbitraryJavaScript": .bool(false),
        "allowedNavigationSchemes": .array([.string("http"), .string("https")]),
        "blockedRemoteResourceExtensions": .array(blockedRemoteResourceExtensions.sorted().map(JSONValue.string)),
        "cautionRemoteResourceExtensions": .array(cautionRemoteResourceExtensions.sorted().map(JSONValue.string)),
        "downloadsDenied": .bool(true),
        "remoteControl": .string("stdio MCP bridge or SSH forwarding only; no TCP listener"),
        "networkSimulation": .string("Chromium CDP host on Linux; explicitly unsupported on WebKit"),
        "sensitiveDiagnostics": .object([
            "default": .string("redacted"),
            "enableEnvironment": .string("HEADLESS_ALLOW_SENSITIVE_DIAGNOSTICS=1"),
        ]),
        "maximumMessageBytes": .number(Double(headlessMaximumMessageBytes)),
    ]),
])
