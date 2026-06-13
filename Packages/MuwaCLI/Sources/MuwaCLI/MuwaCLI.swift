//
//  MuwaCLI.swift
//  Muwa
//
//  Main entry point for the Muwa CLI. Parses command-line arguments and routes to appropriate command handlers.
//

import Foundation
import MuwaCLICore

@main
struct MuwaCLI {
    private enum CommandType {
        case status
        case serve([String])
        case stop
        case list
        case show(String)
        case run(String)
        case pull(String)
        case mcp
        case ui
        case tools([String])
        case manifest([String])
        case bundle([String])
        case coord([String])
        case version
        case help
    }

    private static func parseCommand(_ args: ArraySlice<String>) -> CommandType? {
        guard let command = args.first else { return nil }
        let rest = Array(args.dropFirst())
        switch command {
        case "status": return .status
        case "serve": return .serve(rest)
        case "stop": return .stop
        case "list": return .list
        case "show":
            if let modelId = rest.first, !modelId.isEmpty { return .show(modelId) }
            return nil
        case "run":
            if let modelId = rest.first, !modelId.isEmpty { return .run(modelId) }
            return nil
        case "pull":
            if let modelId = rest.first, !modelId.isEmpty { return .pull(modelId) }
            return nil
        case "mcp": return .mcp
        case "ui": return .ui
        case "tools": return .tools(rest)
        case "manifest": return .manifest(rest)
        case "bundle": return .bundle(rest)
        case "coord": return .coord(rest)
        case "version", "--version", "-v": return .version
        case "help", "-h", "--help": return .help
        default: return nil
        }
    }

    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        guard let cmd = parseCommand(arguments) else {
            if let first = arguments.first { fputs("Unknown or invalid command: \(first)\n\n", stderr) }
            printUsage()
            exit(EXIT_FAILURE)
        }

        switch cmd {
        case .status:
            await StatusCommand.execute(args: [])
        case .serve(let args):
            await ServeCommand.execute(args: args)
        case .stop:
            await StopCommand.execute(args: [])
        case .list:
            await ListCommand.execute(args: [])
        case .show(let modelId):
            await ShowCommand.execute(args: [modelId])
        case .run(let modelId):
            await RunCommand.execute(args: [modelId])
        case .pull(let modelId):
            await PullCommand.execute(args: [modelId])
        case .mcp:
            await MCPCommand.execute(args: [])
        case .ui:
            await UICommand.execute(args: [])
        case .tools(let args):
            await ToolsCommand.execute(args: args)
        case .manifest(let args):
            await ManifestCommand.execute(args: args)
        case .bundle(let args):
            await BundleCommand.execute(args: args)
        case .coord(let args):
            await CoordCommand.execute(args: args)
        case .version:
            await VersionCommand.execute(args: [])
        case .help:
            printUsage()
            exit(EXIT_SUCCESS)
        }
    }

    private static func printUsage() {
        let usage = """
            muwa - CLI for Muwa

            Usage:
              muwa serve [--port N] [--expose] [--yes|-y]
                                      Start the server (default: localhost only). If --expose
                                      is set, a warning prompt will appear unless --yes is provided.
              muwa stop            Stop the server
              muwa mcp             Run MCP stdio server proxying to local HTTP
              muwa version         Show version (also: --version or -v)
              muwa status          Check if the Muwa server is running
              muwa list            List available model IDs
              muwa show <model_id> Show metadata for a model
              muwa pull <model_id> Download a model from Hugging Face
              muwa run <model_id>  Chat with a downloaded model (interactive)
              muwa ui              Show the Muwa menu popover in the menu bar
              muwa tools list      List installed tools
              muwa tools install <plugin_id|url-or-path>
                                      Install a tool from registry or local/URL
              muwa tools search <query>
                                      Search for tools in the registry
              muwa tools outdated  Check for outdated tools
              muwa tools upgrade   Upgrade installed tools
              muwa tools uninstall <tool_name>
                                      Uninstall a tool
              muwa tools verify    Verify dylib integrity of installed tools
              muwa tools create <name> [--language swift|rust]
                                      Scaffold a v2 plugin project
              muwa tools package <plugin_id> <version> [dylib_path]
                                      Package plugin into a zip (includes web/, docs)
              muwa tools reload    Ask the app to rescan tools
              muwa tools rollback <plugin_id>
                                      Roll back a tool to its previous version
              muwa tools dev <plugin_id> [--web-proxy <url>]
                                      Dev mode with hot reload and optional web proxy
              muwa manifest extract <dylib>
                                      Extract manifest JSON from built plugin
              muwa manifest validate <manifest.json>
                                      Validate a plugin manifest's structure (run before packaging)
              muwa bundle load <path.mcpb> [--name "Display Name"]
                                      Load and run an MCP Bundle (.mcpb file)
              muwa coord <subcommand>
                                      Local coordinator orchestration foundation
              muwa help            Show this help

            """
        print(usage)
    }
}
