import Foundation

public struct RecordedFlow: Codable, Sendable {
    public let version: Int
    public let createdAt: Double
    public let commands: [RecordedFlowStep]

    public init(commands: [RecordedFlowStep]) {
        version = 1
        createdAt = Date().timeIntervalSince1970
        self.commands = commands
    }
}

public struct RecordedFlowStep: Codable, Sendable {
    public let command: CommandName
    public let parameters: [String: JSONValue]

    public init(command: CommandName, parameters: [String: JSONValue]) {
        self.command = command
        self.parameters = parameters
    }
}

public let replayableFlowCommands: Set<CommandName> = [
    .visit, .click, .press, .scroll, .back, .reload, .wait, .tour,
]

public func flowStepIfSafe(command: CommandName, parameters: [String: JSONValue]) -> RecordedFlowStep? {
    guard replayableFlowCommands.contains(command) else { return nil }
    return RecordedFlowStep(command: command, parameters: parameters)
}
