//
//  WorkflowContractTests.swift
//  osaurus
//
//  Unit tests for the workflow argument contract: the static validation
//  shared by `workflow_save` (save gate) and `WorkflowRunner` (run
//  preflight), the run-example renderer, and the runner's unknown-key /
//  preflight fail-fast paths.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Fixtures

/// Schema mirroring the live failure: a tool with one required `path`.
private let pathRequiredSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
        "path": .object(["type": .string("string")]),
        "limit": .object(["type": .string("number")]),
    ]),
    "required": .array([.string("path")]),
])

private func issuesText(_ issues: [WorkflowContract.Issue]) -> String {
    issues.map(\.rendered).joined(separator: "\n")
}

// MARK: - Run example rendering

struct WorkflowContractRunExampleTests {

    @Test func parameterlessWorkflowRendersIdOnly() {
        let example = WorkflowContract.runExampleJSON(workflowId: "abc-123", parameters: [])
        #expect(example == "{\"id\": \"abc-123\"}")
    }

    @Test func parametersRenderTypeRequirednessAndDescription() {
        let example = WorkflowContract.runExampleJSON(
            workflowId: "abc-123",
            parameters: [
                WorkflowParameter(
                    name: "path",
                    type: .string,
                    description: "path to the source PDF",
                    required: true
                ),
                WorkflowParameter(
                    name: "count",
                    type: .number,
                    required: false,
                    defaultValue: "3"
                ),
            ]
        )
        #expect(example.contains("\"id\": \"abc-123\""))
        #expect(example.contains("\"path\": \"<string, required — path to the source PDF>\""))
        #expect(example.contains("\"count\": \"<number, optional, default: 3>\""))
    }
}

// MARK: - Static validation (save gate)

struct WorkflowContractValidationTests {

    @Test func argLessStepMissingRequiredPropertyIsRejected() {
        // The live failure: `{"tool": "file_read"}` with no args_template
        // and no parameters saved fine, then died at run time.
        let issues = WorkflowContract.validate(
            parameters: [],
            steps: [.tool("file_read")],
            toolSchemas: ["file_read": pathRequiredSchema]
        )
        #expect(issues.count == 1)
        #expect(issues[0].stepIndex == 1)
        #expect(issuesText(issues).contains("Missing required property: path"))
        #expect(issuesText(issues).contains("{{params.path}}"))
    }

    @Test func undeclaredPlaceholderIsRejected() {
        let issues = WorkflowContract.validate(
            parameters: [],
            steps: [.tool("file_read", argsTemplate: "{\"path\": \"{{params.path}}\"}")],
            toolSchemas: ["file_read": pathRequiredSchema]
        )
        #expect(issues.count == 1)
        #expect(issuesText(issues).contains("undeclared parameter(s) `path`"))
    }

    @Test func unusedRequiredParameterIsRejected() {
        let issues = WorkflowContract.validate(
            parameters: [WorkflowParameter(name: "query", required: true)],
            steps: [.tool("file_read", argsTemplate: "{\"path\": \"/tmp/report.pdf\"}")],
            toolSchemas: ["file_read": pathRequiredSchema]
        )
        #expect(issues.count == 1)
        #expect(issues[0].stepIndex == nil)
        #expect(issuesText(issues).contains("Required parameter `query` is never referenced"))
    }

    @Test func invalidTemplateJSONIsRejected() {
        let issues = WorkflowContract.validate(
            parameters: [],
            steps: [.tool("file_read", argsTemplate: "not json at all")],
            toolSchemas: [:]
        )
        #expect(issues.count == 1)
        #expect(issuesText(issues).contains("not a valid JSON object"))
    }

    @Test func forwardStepOutputReferenceIsRejected() {
        let issues = WorkflowContract.validate(
            parameters: [],
            steps: [
                .tool("file_read", argsTemplate: "{\"path\": \"{{steps.2.output}}\"}"),
                .tool("file_read", argsTemplate: "{\"path\": \"/tmp/a\"}"),
            ],
            toolSchemas: [:]
        )
        #expect(issues.count == 1)
        #expect(issuesText(issues).contains("{{steps.2.output}}"))
    }

    @Test func validParameterizedWorkflowPasses() {
        let issues = WorkflowContract.validate(
            parameters: [WorkflowParameter(name: "path", type: .string, required: true)],
            steps: [
                .tool("file_read", argsTemplate: "{\"path\": \"{{params.path}}\"}"),
                .tool("file_read", argsTemplate: "{\"path\": \"{{steps.1.output}}\"}"),
                .guidance("Summarize the contents."),
            ],
            toolSchemas: ["file_read": pathRequiredSchema]
        )
        #expect(issues.isEmpty)
    }

    @Test func unresolvableToolSkipsSchemaCheck() {
        // Unloaded plugin tools must not block a save.
        let issues = WorkflowContract.validate(
            parameters: [],
            steps: [.tool("some_unloaded_plugin_tool")],
            toolSchemas: [:]
        )
        #expect(issues.isEmpty)
    }

    @Test func parameterReferencedOnlyInGuidancePasses() {
        let issues = WorkflowContract.validate(
            parameters: [WorkflowParameter(name: "topic", required: true)],
            steps: [.guidance("Research {{params.topic}} and summarize.")],
            toolSchemas: [:]
        )
        #expect(issues.isEmpty)
    }

    @Test func placeholderValuedEnumFieldIsNotAFalsePositive() {
        // The sample value "sample" would fail the enum check, but the
        // real value is only bound at run time — must not block the save.
        let enumSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("fast"), .string("slow")]),
                ])
            ]),
            "required": .array([.string("mode")]),
        ])
        let issues = WorkflowContract.validate(
            parameters: [WorkflowParameter(name: "mode", required: true)],
            steps: [.tool("enum_tool", argsTemplate: "{\"mode\": \"{{params.mode}}\"}")],
            toolSchemas: ["enum_tool": enumSchema]
        )
        #expect(issues.isEmpty)
    }

    @Test func executablePrefixScopeIgnoresStepsAfterGuidance() {
        // Tool steps after the first guidance step run manually under
        // model judgment — they must not block `workflow_run`.
        let issues = WorkflowContract.validate(
            parameters: [],
            steps: [
                .guidance("Inspect the data manually."),
                .tool("file_read"),  // would fail the schema check
            ],
            toolSchemas: ["file_read": pathRequiredSchema],
            scope: .executablePrefix
        )
        #expect(issues.isEmpty)
    }

    @Test func executablePrefixScopeStillChecksPreGuidanceSteps() {
        let issues = WorkflowContract.validate(
            parameters: [],
            steps: [
                .tool("file_read"),
                .guidance("Then summarize."),
            ],
            toolSchemas: ["file_read": pathRequiredSchema],
            scope: .executablePrefix
        )
        #expect(issues.count == 1)
        #expect(issuesText(issues).contains("Missing required property: path"))
    }

    @Test func executablePrefixScopeSkipsUnusedParameterLint() {
        let issues = WorkflowContract.validate(
            parameters: [WorkflowParameter(name: "topic", required: true)],
            steps: [.guidance("Research the topic.")],
            toolSchemas: [:],
            scope: .executablePrefix
        )
        #expect(issues.isEmpty)
    }
}

// MARK: - Save gate (tool-level)

struct WorkflowSaveToolContractTests {

    @Test func saveRejectsUnrunnableWorkflowWithPerStepErrors() async throws {
        let tool = WorkflowSaveTool()
        let args = """
            {"name": "test_wf", "description": "test", "steps": \
            [{"tool": "some_unloaded_tool", "args_template": {"path": "{{params.path}}"}}]}
            """
        let result = try await tool.execute(argumentsJSON: args)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Workflow not saved"))
        #expect(result.contains("undeclared parameter"))
        #expect(result.contains("workflow_save"))
    }
}

// MARK: - Runner fail-fast

struct WorkflowRunnerFailFastTests {

    @Test func unknownArgumentKeyOnParameterlessWorkflowIsRejected() {
        let wf = Workflow(
            name: "no-params",
            description: "takes no arguments",
            body: "",
            source: .user,
            steps: [.guidance("noop")]
        )
        #expect(
            throws: WorkflowRunnerError.unknownArguments(provided: ["path"], declared: [])
        ) {
            _ = try WorkflowRunner.resolveParameters(
                workflow: wf,
                argumentsJSON: "{\"path\": \"report.pdf\"}"
            )
        }
    }

    @Test func unknownArgumentKeyListsDeclaredParameters() {
        let wf = Workflow(
            name: "typo",
            description: "declared parameter is `path`",
            body: "",
            source: .user,
            parameters: [WorkflowParameter(name: "path", required: true)],
            steps: [.guidance("noop")]
        )
        #expect(
            throws: WorkflowRunnerError.unknownArguments(provided: ["file"], declared: ["path"])
        ) {
            _ = try WorkflowRunner.resolveParameters(
                workflow: wf,
                argumentsJSON: "{\"file\": \"report.pdf\", \"path\": \"report.pdf\"}"
            )
        }
    }

    @Test @MainActor func preflightFailsFastOnLegacyArgLessWorkflow() async throws {
        // A workflow saved before contract validation existed: tool step
        // with no template against a tool whose schema requires `path`.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-workflow-contract-\(UUID().uuidString)",
            isDirectory: true
        )
        let previousOverride = ToolConfigurationStore.overrideDirectory
        ToolConfigurationStore.overrideDirectory = tempDir
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { ToolConfigurationStore.overrideDirectory = previousOverride }

        let fixture = ContractPreflightFixtureTool()
        ToolRegistry.shared.registerPluginTool(fixture)
        defer { ToolRegistry.shared.unregister(names: [fixture.name]) }

        let wf = Workflow(
            name: "legacy",
            description: "saved without args",
            body: "",
            source: .agent,
            steps: [.tool(fixture.name)]
        )
        do {
            _ = try await WorkflowRunner.run(workflow: wf, argumentsJSON: "{}", recordOutcome: false)
            Issue.record("Expected preflightFailed to be thrown")
        } catch let error as WorkflowRunnerError {
            guard case .preflightFailed(let message) = error else {
                Issue.record("Expected preflightFailed, got \(error)")
                return
            }
            #expect(message.contains("cannot run as saved"))
            #expect(message.contains("No steps were executed"))
            #expect(message.contains("capabilities_load"))
        }
    }
}

/// Plugin-style fixture so the preflight resolves a real schema from the
/// live registry without depending on which built-ins are loaded.
private final class ContractPreflightFixtureTool: OsaurusTool, @unchecked Sendable {
    let name = "contract_preflight_fixture"
    let description = "Fixture tool requiring `path`, for preflight tests."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object(["type": .string("string")])
        ]),
        "required": .array([.string("path")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        ToolEnvelope.success(tool: name, text: "ok")
    }
}
