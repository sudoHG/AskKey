import Foundation

/// Planner-captured CLI output from Claude Code 2.1.282 with an empty temporary HOME.
/// These are protocol samples, not reads of the maintainer's configuration.
enum ClaudeCodeMCPOutputSamples {
    static let absentWithoutServers = "No MCP server named \"askkey\". Run `claude mcp add` to add one."
    static let absentWithServers = "No MCP server named \"nothere\". Configured servers: askkey"
    static let emptyList = "No MCP servers configured. Use `claude mcp add` to add a server."
    static let listedServer = """
    Checking MCP server health…

    askkey: /usr/bin/true mcp - ✘ Failed to connect — CONNECTION_CLOSED: Connection closed
    """
    static let failedServer = """
    askkey:
      Scope: User config (available in all your projects)
      Status: ✘ Failed to connect
      Issue: CONNECTION_CLOSED: Connection closed
      Type: stdio
      Command: /usr/bin/true
      Args: mcp

    To remove this server, run: claude mcp remove askkey -s user
    """
    static let connectedServer = """
    askkey:
      Scope: User config (available in all your projects)
      Status: ✔ Connected
      Type: stdio
      Command: /usr/bin/python3
      Args: <TMP>/srv.py

    To remove this server, run: claude mcp remove askkey -s user
    """
}
