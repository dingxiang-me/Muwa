//
//  BootstrapSpecCompactionTests.swift
//  osaurusTests
//
//  Pins the first-turn tool-schema compaction (`compactBootstrapSpec`). Two
//  regressions are guarded here:
//   1. A parameter literally named `description` must survive compaction —
//      stripping it while leaving it in `required` produced an impossible
//      schema for `sandbox_secret_set` (required key with no property under
//      `additionalProperties:false`).
//   2. One-line description truncation must not cut inside paths
//      (`~/.venv/`) or abbreviations (`e.g.`) — it ends a sentence only on
//      punctuation followed by whitespace or end-of-string.
//

import Testing

@testable import OsaurusCore

@Suite
struct BootstrapSpecCompactionTests {

    private func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let dict)? = value else { return nil }
        return dict
    }

    // MARK: - #4 parameter named `description`

    @Test func preservesParameterNamedDescription() throws {
        let params: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "key": .object([
                    "type": .string("string"),
                    "description": .string("Secret name."),
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Human-readable description of the secret."),
                ]),
                "value": .object([
                    "type": .string("string"),
                    "description": .string("The secret value."),
                ]),
            ]),
            "required": .array([.string("key"), .string("description")]),
        ])
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "sandbox_secret_set",
                description: "Store a secret for the current agent.",
                parameters: params
            )
        )

        let compact = SystemPromptComposer.compactBootstrapSpec(tool)
        let root = try #require(object(compact.function.parameters))
        let properties = try #require(object(root["properties"]))

        // The `description` PARAMETER survives.
        #expect(properties["description"] != nil, "parameter named 'description' was dropped")
        #expect(properties["key"] != nil)
        #expect(properties["value"] != nil)

        // Its annotation prose inside the property schema is still stripped.
        let descSchema = try #require(object(properties["description"]))
        #expect(descSchema["description"] == nil, "annotation prose should be stripped")
        #expect(descSchema["type"] == .string("string"))

        // `required` is untouched, so it stays consistent with `properties`.
        #expect(root["required"] == .array([.string("key"), .string("description")]))

        // The `additionalProperties:false` flag is preserved.
        #expect(root["additionalProperties"] == .bool(false))
    }

    @Test func stripsAnnotationDescriptionsElsewhere() throws {
        let params: JSONValue = .object([
            "type": .string("object"),
            "description": .string("top-level annotation prose"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("the file path"),
                ])
            ]),
        ])
        let tool = Tool(
            type: "function",
            function: ToolFunction(name: "file_read", description: "Read a file.", parameters: params)
        )

        let compact = SystemPromptComposer.compactBootstrapSpec(tool)
        let root = try #require(object(compact.function.parameters))
        #expect(root["description"] == nil, "top-level annotation prose should be stripped")
        let properties = try #require(object(root["properties"]))
        let pathSchema = try #require(object(properties["path"]))
        #expect(pathSchema["description"] == nil)
        #expect(pathSchema["type"] == .string("string"))
    }

    // MARK: - #5 description truncation

    @Test func keepsPathInFirstSentence() {
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "sandbox_install",
                description:
                    "Install Python packages via pip into the agent's venv at `~/.venv/`. "
                    + "**Use this instead of sandbox_exec.** Example: foo.",
                parameters: nil
            )
        )
        let compact = SystemPromptComposer.compactBootstrapSpec(tool)
        let desc = compact.function.description ?? ""
        #expect(desc.contains("`~/.venv/`"), "path was truncated: \(desc)")
        // Stops at the real sentence end (before the bold "Use this").
        #expect(!desc.contains("Use this instead"))
    }

    @Test func keepsAbbreviationInFirstSentence() {
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: "demo",
                description: "Returns ranked IDs, e.g. tool/foo, for you to load. Second sentence.",
                parameters: nil
            )
        )
        let compact = SystemPromptComposer.compactBootstrapSpec(tool)
        let desc = compact.function.description ?? ""
        #expect(desc.contains("e.g. tool/foo"), "abbreviation truncated: \(desc)")
        #expect(!desc.contains("Second sentence"))
    }

    // MARK: - #6 workflow_save authoring contract survives the bootstrap

    /// Regression from a live session (2026-06-10): the bootstrap skeleton
    /// stripped workflow_save's property descriptions and step-item shape,
    /// so a frontier model invented `{"action": ..., "params": ...}` steps
    /// and then saved a parameterless guidance-only workflow with hardcoded
    /// values. The full parameter schema — placeholder rules and structural
    /// item schemas included — must reach the model on turn 1.
    @Test func workflowSaveKeepsParameterSchemaThroughBootstrap() throws {
        let saveTool = WorkflowSaveTool()
        let tool = Tool(
            type: "function",
            function: ToolFunction(
                name: saveTool.name,
                description: saveTool.description,
                parameters: saveTool.parameters
            )
        )

        let compact = SystemPromptComposer.compactBootstrapSpec(tool)
        let root = try #require(object(compact.function.parameters))
        let properties = try #require(object(root["properties"]))

        // The steps description (placeholder + promote-to-parameters rules)
        // survives.
        let steps = try #require(object(properties["steps"]))
        let stepsDescription: String = {
            if case .string(let s)? = steps["description"] { return s }
            return ""
        }()
        #expect(stepsDescription.contains("{{params.<name>}}"))

        // The structural step-item schema survives: the model sees the
        // allowed keys even if some path strips prose.
        let stepItems = try #require(object(steps["items"]))
        let stepItemProperties = try #require(object(stepItems["properties"]))
        #expect(stepItemProperties["tool"] != nil)
        #expect(stepItemProperties["args_template"] != nil)
        #expect(stepItemProperties["guidance"] != nil)

        let params = try #require(object(properties["parameters"]))
        let paramItems = try #require(object(params["items"]))
        let paramItemProperties = try #require(object(paramItems["properties"]))
        #expect(paramItemProperties["name"] != nil)
        #expect(paramItemProperties["type"] != nil)
    }
}
