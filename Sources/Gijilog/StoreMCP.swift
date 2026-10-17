import AVFoundation
import AppKit
import Combine
import CryptoKit
import IOKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - MCP

extension Store {
    /// Opens or closes the local MCP socket to match the setting. Only the app itself (not tests) serves it.
    func updateMCPServer() {
        guard persistsSettings else { return }
        if mcpEnabled, mcpServer == nil {
            let server = MCPSocketServer(path: MCPPaths.socket.path) { [unowned self] in MCPHandler(store: self) }
            server.onConnectionsChanged = { [weak self] count in self?.mcpConnections = count }
            do {
                try server.start()
                mcpServer = server
                mcpProblem = nil
            } catch {
                mcpProblem = error.localizedDescription
            }
        } else if !mcpEnabled, let server = mcpServer {
            server.stop()
            mcpServer = nil
            mcpConnections = 0
        }
    }
    func stopMCPServer() {
        mcpServer?.stop()
        mcpServer = nil
    }
    func recordMCPAccess(client: String, tool: String, detail: String) {
        mcpAccesses.insert(MCPAccess(date: Date(), client: client, tool: tool, detail: detail), at: 0)
        if mcpAccesses.count > 50 { mcpAccesses.removeLast(mcpAccesses.count - 50) }
    }
    func toggleMCPHiddenTag(_ tag: String) {
        if MeetingTags.contains(mcpHiddenTags, tag) {
            mcpHiddenTags.removeAll { MeetingTags.key($0) == MeetingTags.key(tag) }
        } else {
            mcpHiddenTags.append(tag)
        }
    }
}
