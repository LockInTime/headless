import Foundation
import HeadlessProtocol

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

func object(_ value: Any?, _ message: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else {
        throw TestFailure(description: message)
    }
    return value
}

func integer(_ value: Any?, _ message: String) throws -> Int {
    guard let number = value as? NSNumber else {
        throw TestFailure(description: message)
    }
    return number.intValue
}

func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw TestFailure(description: "usage: headless-mcp-tests /path/to/headless-mcp")
    }

    try LocalRuntime.preparePrivateDirectory()
    let socketPath = LocalRuntime.directoryURL
        .appendingPathComponent("mcp-test-\(UUID().uuidString).sock").path
    let server = LocalSocketServer(socketPath: socketPath)
    try server.start { request in
        CommandResponse.success(
            id: request.id,
            result: .object(["ready": .bool(true), "command": .string(request.command.rawValue)])
        )
    }
    defer { server.stop() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    var environment = ProcessInfo.processInfo.environment
    environment["HEADLESS_SOCKET"] = socketPath
    process.environment = environment

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors

    let requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["status"]}}}"#,
        "not-json",
        String(repeating: "x", count: headlessMaximumMessageBytes + 1),
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"headless","arguments":{"argv":["start"]}}}"#,
    ]

    try process.run()
    input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try expect(process.terminationStatus == 0, "MCP process failed: \(stderr)")

    let responses = try stdout.split(separator: "\n").map { line -> [String: Any] in
        let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try object(value, "MCP response was not a JSON object")
    }
    try expect(responses.count == 6, "expected six MCP responses, received \(responses.count)")

    let initialize = try object(responses[0]["result"], "initialize result was absent")
    try expect(initialize["protocolVersion"] as? String == "2025-06-18", "initialize protocol version changed")
    let serverInfo = try object(initialize["serverInfo"], "initialize server info was absent")
    try expect(serverInfo["name"] as? String == "headless", "initialize server name changed")

    let list = try object(responses[1]["result"], "tools/list result was absent")
    guard let tools = list["tools"] as? [[String: Any]], tools.count == 1 else {
        throw TestFailure(description: "tools/list did not expose exactly one tool")
    }
    try expect(tools[0]["name"] as? String == "headless", "tools/list exposed the wrong tool")

    let call = try object(responses[2]["result"], "tools/call result was absent")
    try expect(call["isError"] as? Bool == false, "browser tools/call unexpectedly failed")
    guard let content = call["content"] as? [[String: Any]],
          let text = content.first?["text"] as? String else {
        throw TestFailure(description: "browser tools/call content was absent")
    }
    let browserResponse = try object(
        JSONSerialization.jsonObject(with: Data(text.utf8)),
        "browser tools/call content was not a protocol response"
    )
    try expect(browserResponse["ok"] as? Bool == true, "browser protocol response was not successful")
    let browserResult = try object(browserResponse["result"], "browser protocol result was absent")
    try expect(browserResult["ready"] as? Bool == true, "browser command did not reach the local host")

    for index in 3...4 {
        let parseError = try object(responses[index]["error"], "invalid input did not return JSON-RPC error")
        let code = try integer(parseError["code"], "parse error code was absent")
        try expect(code == -32700, "invalid input returned the wrong error code")
    }

    let localCall = try object(responses[5]["result"], "local-command result was absent")
    try expect(localCall["isError"] as? Bool == true, "local CLI command was accepted over MCP")
    guard let localContent = localCall["content"] as? [[String: Any]],
          let localText = localContent.first?["text"] as? String else {
        throw TestFailure(description: "local-command rejection text was absent")
    }
    try expect(localText.contains("browser commands only"), "local-command rejection guidance changed")
}

do {
    try run()
    print("✓ MCP stdio integration")
    print("MCP tests: 1 passed")
} catch {
    fputs("✗ MCP stdio integration: \(error)\n", stderr)
    exit(1)
}
