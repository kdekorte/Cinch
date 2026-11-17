//
//  Server.swift
//  cinch-mcp
//
//  Minimal MCP server: JSON-RPC 2.0 over newline-delimited UTF-8 messages
//  on stdin/stdout (the MCP "stdio" transport). Diagnostics go to stderr;
//  nothing else may ever be written to stdout.
//

import Foundation

final class MCPServer {
    private let tools: [Tool]
    private let out = FileHandle.standardOutput

    init(tools: [Tool]) {
        self.tools = tools
    }

    func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            handleMessage(trimmed)
        }
    }

    // MARK: - Dispatch

    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            send(error: nil, code: -32700, message: "parse error")
            return
        }

        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) are never answered.
        guard id != nil else {
            log("notification: \(method)")
            return
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18"]
            let version = requested.flatMap { supported.contains($0) ? $0 : nil } ?? "2024-11-05"
            send(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "cinch-mcp", "version": "1.0.0"],
            ])
        case "ping":
            send(id: id, result: [:])
        case "tools/list":
            send(id: id, result: ["tools": tools.map(toolDescriptor)])
        case "tools/call":
            handleToolCall(id: id, params: params)
        default:
            send(error: id, code: -32601, message: "method not found: \(method)")
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        guard let tool = tools.first(where: { $0.name == name }) else {
            send(error: id, code: -32602, message: "unknown tool: \(name)")
            return
        }

        do {
            let text = try tool.handler(arguments)
            send(id: id, result: [
                "content": [["type": "text", "text": text]],
                "isError": false,
            ])
        } catch {
            send(id: id, result: [
                "content": [["type": "text", "text": "error: \(error.localizedDescription)"]],
                "isError": true,
            ])
        }
    }

    private func toolDescriptor(_ tool: Tool) -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "inputSchema": tool.schema,
        ]
    }

    // MARK: - Writing

    private func send(id: Any?, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func send(error id: Any?, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(),
               "error": ["code": code, "message": message]])
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        out.write(data)
        out.write(Data("\n".utf8))
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
