//
//  main.swift
//  cinch-mcp
//
//  Entry point: runs the MCP stdio server. All protocol handling is in
//  Server.swift; the archive tools are defined in Tools.swift and
//  ToolsEdit.swift.
//

import Foundation

MCPServer(tools: Tool.allTools).run()
