import Foundation

public let agentRuntimeJavaScript: String = {
    if let resourceURL = Bundle.main.resourceURL?
        .appendingPathComponent("Headless_HeadlessProtocol.bundle", isDirectory: true)
        .appendingPathComponent("AgentRuntime.js", isDirectory: false),
       let source = try? String(contentsOf: resourceURL, encoding: .utf8) {
        return source
    }

    guard let url = Bundle.module.url(forResource: "AgentRuntime", withExtension: "js"),
          let source = try? String(contentsOf: url, encoding: .utf8) else {
        fatalError("HeadlessProtocol is missing its compiled AgentRuntime.js resource")
    }
    return source
}()
