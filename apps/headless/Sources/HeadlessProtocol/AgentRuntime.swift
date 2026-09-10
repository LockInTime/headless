import Foundation

public let agentRuntimeJavaScript: String = {
    let source: String
    if let resourceURL = Bundle.main.resourceURL?
        .appendingPathComponent("Headless_HeadlessProtocol.bundle", isDirectory: true)
        .appendingPathComponent("AgentRuntime.js", isDirectory: false),
       let loaded = try? String(contentsOf: resourceURL, encoding: .utf8) {
        source = loaded
    } else if let url = Bundle.module.url(forResource: "AgentRuntime", withExtension: "js"),
              let loaded = try? String(contentsOf: url, encoding: .utf8) {
        source = loaded
    } else {
        fatalError("HeadlessProtocol is missing its compiled AgentRuntime.js resource")
    }
    return processNavigationAllowlist.agentRuntimePreamble + source
}()
