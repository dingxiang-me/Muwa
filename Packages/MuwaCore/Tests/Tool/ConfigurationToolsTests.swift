//
//  ConfigurationToolsTests.swift
//  MuwaCoreTests
//
//  Per-tool contract for the configure surface:
//
//   * Every `muwa_*` write tool routes through
//     `ConfigurationToolBase.defaultAgentGateFailure` *before* parsing
//     arguments. We assert this by calling each tool without a
//     `currentAgentId` binding — the response must be an `unavailable`
//     envelope regardless of how malformed the JSON is.
//   * Calling from a non-default agent yields the same gate rejection
//     ("only available to the Default agent").
//   * Calling from the Default agent with empty / malformed JSON falls
//     through to the argument validator and returns an `invalidArgs`
//     envelope (NOT an exception, NOT a silent no-op).
//
//  These tests deliberately avoid touching `AgentManager`,
//  `RemoteProviderManager`, `ModelManager`, etc. — the gate runs first
//  so the manager-side code is never reached when arguments are
//  invalid or the caller is on the wrong agent.
//

import Foundation
import Testing

@testable import MuwaCore

@Suite(.serialized)
struct ConfigurationToolsGateContractTests {

    /// Run the tool with no `currentAgentId` binding (the most
    /// hostile invocation path — e.g. an HTTP / plugin tool call that
    /// somehow reached the configure surface).
    private func executeWithoutAgentContext(
        _ tool: any MuwaTool,
        args: String = "{}"
    ) async throws -> String {
        try await tool.execute(argumentsJSON: args)
    }

    private func executeAsCustomAgent(
        _ tool: any MuwaTool,
        args: String = "{}"
    ) async throws -> String {
        try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await tool.execute(argumentsJSON: args)
        }
    }

    // MARK: - muwa_agent_create

    @Test
    func agentCreate_refusesWithoutAgentContext() async throws {
        let result = try await executeWithoutAgentContext(MuwaAgentCreateTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("chat session context"))
    }

    @Test
    func agentCreate_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(MuwaAgentCreateTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    // MARK: - muwa_provider_add

    @Test
    func providerAdd_refusesWithoutAgentContext() async throws {
        let result = try await executeWithoutAgentContext(MuwaProviderAddTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("chat session context"))
    }

    @Test
    func providerAdd_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(MuwaProviderAddTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    // MARK: - muwa_model_download

    @Test
    func modelDownload_refusesWithoutAgentContext() async throws {
        let result = try await executeWithoutAgentContext(MuwaModelDownloadTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("chat session context"))
    }

    @Test
    func modelDownload_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(MuwaModelDownloadTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    // MARK: - muwa_plugin_install

    @Test
    func pluginInstall_refusesWithoutAgentContext() async throws {
        let result = try await executeWithoutAgentContext(MuwaPluginInstallTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("chat session context"))
    }

    @Test
    func pluginInstall_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(MuwaPluginInstallTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    // MARK: - muwa_schedule_create

    @Test
    func scheduleCreate_refusesWithoutAgentContext() async throws {
        let result = try await executeWithoutAgentContext(MuwaScheduleCreateTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("chat session context"))
    }

    @Test
    func scheduleCreate_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(MuwaScheduleCreateTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    // MARK: - muwa_mcp_add

    @Test
    func mcpAdd_refusesWithoutAgentContext() async throws {
        let result = try await executeWithoutAgentContext(MuwaMCPAddTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("chat session context"))
    }

    @Test
    func mcpAdd_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(MuwaMCPAddTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    // MARK: - muwa_mcp_remove / muwa_mcp_enable

    @Test
    func mcpRemove_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(MuwaMCPRemoveTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    @Test
    func mcpEnable_refusesWithoutAgentContext() async throws {
        let result = try await executeWithoutAgentContext(MuwaMCPEnableTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("chat session context"))
    }

    // MARK: - muwa_status (read tool — same gate applies)

    @Test
    func status_refusesWithoutAgentContext() async throws {
        let result = try await executeWithoutAgentContext(MuwaStatusTool())
        #expect(ToolEnvelope.isError(result))
    }

    @Test
    func status_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(MuwaStatusTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    // MARK: - muwa_list (read tool — same gate applies)

    @Test
    func list_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(
            MuwaListTool(),
            args: "{\"scope\": \"providers\"}"
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }
}
