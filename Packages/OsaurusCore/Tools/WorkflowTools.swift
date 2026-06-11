//
//  WorkflowTools.swift
//  osaurus
//
//  Chat tools for the workflows subsystem:
//    - `workflow_save` lets a model distill a completed task's tool-call
//      trace into a reusable, parameterized workflow.
//    - `workflow_run` executes a saved workflow's deterministic steps via
//      `WorkflowRunner`, handing control back at guidance steps.
//

import Foundation

// MARK: - Feature gate

/// Single source of truth for the per-agent workflows feature gate.
/// Used by the `workflow_save` / `workflow_run` tools and by the
/// workflow lane in `capabilities_discover` / `capabilities_load`.
enum WorkflowFeatureGate {
    /// Rejection copy shared by every gated surface, so the model gets
    /// the same self-correction hint regardless of entry point.
    static let disabledMessage =
        "Workflows are disabled for this agent. "
        + "The user can enable them in the agent's Features settings."

    /// Whether the workflows feature is on for the given agent context.
    /// `nil` (direct utility calls with no task-local context) keeps the
    /// historical unscoped behavior and allows the call. The default
    /// agent resolves to off via `effectiveCapabilities`.
    static func isEnabled(for agentId: UUID?) async -> Bool {
        guard let agentId else { return true }
        return await MainActor.run {
            AgentManager.shared.effectiveCapabilities(for: agentId).workflowsEnabled
        }
    }
}

/// Returns a failure envelope when the calling agent may not use the
/// workflow tools; nil when the call may proceed.
private func workflowToolRejection(tool: String) async -> String? {
    let agentId = ChatExecutionContext.currentAgentId
    if agentId == Agent.defaultId {
        return ToolEnvelope.failure(
            kind: .rejected,
            message:
                "Workflow tools are disabled for the configuration agent. "
                + "Use `capabilities_discover` to find a configuration tool (osaurus_*_<verb>) instead.",
            tool: tool
        )
    }
    guard await !WorkflowFeatureGate.isEnabled(for: agentId) else { return nil }
    return ToolEnvelope.failure(
        kind: .rejected,
        message: WorkflowFeatureGate.disabledMessage,
        tool: tool
    )
}

// MARK: - workflow_save

final class WorkflowSaveTool: OsaurusTool, @unchecked Sendable {
    let name = "workflow_save"
    let description =
        "Save a reusable workflow distilled from a task you just completed successfully. "
        + "Propose this to the user first and only call it after they confirm. Capture the exact tool "
        + "sequence that worked as `steps`; promote anything task-specific (paths, queries, names) to "
        + "`parameters` and reference them as `{{params.<name>}}` inside step `args_template` values. "
        + "Every tool step's `args_template` must satisfy that tool's required arguments — saves that "
        + "would fail at run time are rejected with per-step errors so you can correct and retry. "
        + "Use `guidance` steps for parts that need judgment. Saved workflows are discoverable via "
        + "`capabilities_discover` and runnable by any model via `workflow_run`."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Short snake_case name, e.g. 'summarize_pdf'"),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("One or two sentences describing what the workflow does and when to use it"),
            ]),
            "trigger_text": .object([
                "type": .string("string"),
                "description": .string("Optional example user phrasings that should surface this workflow in search"),
            ]),
            // `steps` and `parameters` carry STRUCTURAL item schemas, not just
            // prose: the first-turn bootstrap ships tool specs as compact
            // skeletons with every `description` stripped (see
            // `SystemPromptComposer.compactBootstrapSpec`), and a live model
            // invented `{"action": ..., "params": ...}` steps when all it saw
            // was `items: {type: object}`. Shape, required keys, and enums
            // survive compaction — descriptions don't.
            "parameters": .object([
                "type": .string("array"),
                "description": .string(
                    "Declared inputs. Reference each as {{params.<name>}} inside step args_template values."
                ),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "type": .object([
                            "type": .string("string"),
                            "enum": .array([.string("string"), .string("number"), .string("boolean")]),
                        ]),
                        "description": .object(["type": .string("string")]),
                        "required": .object(["type": .string("boolean")]),
                        "default": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("name")]),
                ]),
            ]),
            "steps": .object([
                "type": .string("array"),
                "description": .string(
                    "Ordered steps. Each step is EITHER a tool step ({\"tool\": ..., \"args_template\": {...}}) "
                        + "OR a guidance step ({\"guidance\": ...}). Promote task-specific values (paths, queries, "
                        + "names) to `parameters` and reference them as {{params.<name>}} in args_template strings; "
                        + "{{steps.<n>.output}} carries an earlier step's output (1-based)."
                ),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "tool": .object([
                            "type": .string("string"),
                            "description": .string("Tool name to execute (tool steps only)"),
                        ]),
                        "args_template": .object([
                            "type": .string("object"),
                            "description": .string(
                                "Arguments for the tool; string values may embed {{params.<name>}} "
                                    + "and {{steps.<n>.output}} placeholders"
                            ),
                        ]),
                        "skill_context": .object([
                            "type": .string("string"),
                            "description": .string("Optional skill whose instructions apply to this step"),
                        ]),
                        "guidance": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Free-text instruction for the running model (guidance steps only); "
                                    + "execution hands off here"
                            ),
                        ]),
                    ]),
                ]),
            ]),
            "source_model": .object([
                "type": .string("string"),
                "description": .string("Optional: the model identifier that authored this workflow"),
            ]),
        ]),
        "required": .array([.string("name"), .string("description"), .string("steps")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let rejection = await workflowToolRejection(tool: name) { return rejection }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let nameReq = requireString(args, "name", expected: "short snake_case workflow name", tool: name)
        guard case .value(let workflowName) = nameReq else { return nameReq.failureEnvelope ?? "" }

        let descReq = requireString(args, "description", expected: "one or two sentence description", tool: name)
        guard case .value(let description) = descReq else { return descReq.failureEnvelope ?? "" }

        let triggerText = args["trigger_text"] as? String

        let parameters: [WorkflowParameter]
        do {
            parameters = try Self.parseParameters(args["parameters"])
        } catch let error as ParseError {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: error.message,
                field: "parameters",
                tool: name
            )
        }

        let steps: [WorkflowStep]
        do {
            steps = try Self.parseSteps(args["steps"])
        } catch let error as ParseError {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: error.message,
                field: "steps",
                tool: name
            )
        }
        guard !steps.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `steps` must contain at least one step.",
                field: "steps",
                expected: "non-empty array of tool/guidance step objects",
                tool: name
            )
        }

        // Contract validation: reject saves that would fail at run time,
        // while the authoring model is still in the loop to self-correct.
        let toolSchemas = await MainActor.run {
            WorkflowContract.registrySchemas(for: steps.compactMap(\.toolName))
        }
        let issues = WorkflowContract.validate(
            parameters: parameters,
            steps: steps,
            toolSchemas: toolSchemas
        )
        if !issues.isEmpty {
            let detail = issues.map { "- \($0.rendered)" }.joined(separator: "\n")
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Workflow not saved — it would fail at run time:\n\(detail)\n"
                    + "Fix the steps/parameters and call `workflow_save` again.",
                field: "steps",
                tool: name
            )
        }

        let body = Self.renderBody(description: description, parameters: parameters, steps: steps)
        let sourceModel = args["source_model"] as? String

        do {
            let workflow = try await WorkflowService.shared.create(
                name: workflowName,
                description: description,
                triggerText: triggerText,
                body: body,
                source: .agent,
                sourceModel: sourceModel,
                parameters: parameters,
                steps: steps
            )
            var text = "Saved workflow '\(workflow.name)' (id: workflow/\(workflow.id)).\n"
            text += "Steps: \(steps.count)"
            if !parameters.isEmpty {
                text += " | Parameters: \(parameters.map(\.name).joined(separator: ", "))"
            }
            let example = WorkflowContract.runExampleJSON(
                workflowId: workflow.id,
                parameters: parameters
            )
            text += "\nAny model can now discover it via `capabilities_discover` and run it with "
            text += "`workflow_run` using `\(example)`."
            return ToolEnvelope.success(tool: name, text: text)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Failed to save workflow: \(error.localizedDescription)",
                tool: name
            )
        }
    }

    // MARK: - Parsing

    struct ParseError: Error {
        let message: String
    }

    static func parseParameters(_ raw: Any?) throws -> [WorkflowParameter] {
        guard let raw else { return [] }
        guard let array = coerceObjectArray(raw) else {
            throw ParseError(message: "Argument `parameters` must be an array of parameter objects.")
        }
        return try array.map { item in
            guard let name = item["name"] as? String, !name.isEmpty else {
                throw ParseError(message: "Each parameter needs a non-empty `name`.")
            }
            let typeRaw = (item["type"] as? String) ?? "string"
            guard let type = WorkflowParameterType(rawValue: typeRaw) else {
                throw ParseError(
                    message: "Parameter `\(name)` has unknown type '\(typeRaw)' (expected string, number, or boolean)."
                )
            }
            return WorkflowParameter(
                name: name,
                type: type,
                description: (item["description"] as? String) ?? "",
                required: (item["required"] as? Bool) ?? true,
                defaultValue: Self.stringValue(item["default"])
            )
        }
    }

    static func parseSteps(_ raw: Any?) throws -> [WorkflowStep] {
        guard let raw else { return [] }
        guard let array = coerceObjectArray(raw) else {
            throw ParseError(message: "Argument `steps` must be an array of step objects.")
        }
        return try array.enumerated().map { index, item in
            if let guidance = item["guidance"] as? String {
                return WorkflowStep.guidance(guidance, skillContext: item["skill_context"] as? String)
            }
            guard let tool = item["tool"] as? String, !tool.isEmpty else {
                throw ParseError(
                    message:
                        "Step \(index + 1) needs either a `tool` name or a `guidance` text. "
                        + "Tool step shape: {\"tool\": \"file_write\", \"args_template\": {\"path\": \"...\", \"content\": \"...\"}}. "
                        + "Guidance step shape: {\"guidance\": \"instruction text\"}."
                )
            }
            var argsTemplate: String?
            if let templateObject = item["args_template"] {
                if let s = templateObject as? String {
                    argsTemplate = s
                } else if JSONSerialization.isValidJSONObject(templateObject),
                    let data = try? JSONSerialization.data(
                        withJSONObject: templateObject,
                        options: [.sortedKeys]
                    )
                {
                    argsTemplate = String(data: data, encoding: .utf8)
                }
            }
            return WorkflowStep.tool(
                tool,
                argsTemplate: argsTemplate,
                skillContext: item["skill_context"] as? String
            )
        }
    }

    /// Accept a real `[[String: Any]]` or a JSON-encoded string of one
    /// (quantized models routinely stringify nested arrays).
    private static func coerceObjectArray(_ raw: Any) -> [[String: Any]]? {
        if let array = raw as? [[String: Any]] { return array }
        if let s = raw as? String,
            let data = s.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            return array
        }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// Human/model-readable YAML body for the guided-context load path
    /// (`capabilities_load` with `workflow/<id>`).
    static func renderBody(
        description: String,
        parameters: [WorkflowParameter],
        steps: [WorkflowStep]
    ) -> String {
        var out = "description: \(description)\n"
        if !parameters.isEmpty {
            out += "parameters:\n"
            for p in parameters {
                out += "  - name: \(p.name)\n"
                out += "    type: \(p.type.rawValue)\n"
                if !p.description.isEmpty { out += "    description: \(p.description)\n" }
                out += "    required: \(p.required)\n"
                if let d = p.defaultValue { out += "    default: \(d)\n" }
            }
        }
        out += "steps:\n"
        for step in steps {
            switch step.kind {
            case .tool:
                out += "  - tool: \(step.toolName ?? "")\n"
                if let template = step.argsTemplate, !template.isEmpty {
                    out += "    args: \(template)\n"
                }
                if let skill = step.skillContext, !skill.isEmpty {
                    out += "    skill_context: \(skill)\n"
                }
            case .guidance:
                out += "  - guidance: \(step.text ?? "")\n"
                if let skill = step.skillContext, !skill.isEmpty {
                    out += "    skill_context: \(skill)\n"
                }
            }
        }
        return out
    }
}

// MARK: - workflow_run

final class WorkflowRunTool: OsaurusTool, @unchecked Sendable {
    let name = "workflow_run"
    let description =
        "Execute a saved workflow by id. Deterministic tool steps run automatically in order; "
        + "execution stops at the first guidance step (or failure) and returns the completed step "
        + "outputs plus remaining instructions for you to continue with judgment. Workflow IDs come "
        + "from `capabilities_discover` results (`workflow/<id>`), which also show the exact "
        + "`arguments` each workflow takes — pass only its declared parameters. "
        + "Example: `{\"id\": \"abc-123\", \"arguments\": {\"path\": \"report.pdf\"}}`."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "id": .object([
                "type": .string("string"),
                "description": .string("Workflow id (the part after `workflow/` in discover results)"),
            ]),
            "arguments": .object([
                "type": .string("object"),
                "description": .string("Values for the workflow's declared parameters"),
                // Intentionally open: keys are the per-workflow declared
                // parameter names, which the runner validates itself.
                "additionalProperties": .bool(true),
            ]),
        ]),
        "required": .array([.string("id")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        if let rejection = await workflowToolRejection(tool: name) { return rejection }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let idReq = requireString(args, "id", expected: "workflow id from capabilities_discover", tool: name)
        guard case .value(var workflowId) = idReq else { return idReq.failureEnvelope ?? "" }
        // Tolerate the fully-qualified capability id.
        if workflowId.hasPrefix("workflow/") {
            workflowId = String(workflowId.dropFirst("workflow/".count))
        }

        let workflow: Workflow?
        do {
            workflow = try await WorkflowService.shared.load(id: workflowId)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Error loading workflow '\(workflowId)': \(error.localizedDescription)",
                tool: name
            )
        }
        guard let workflow else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message: "Workflow '\(workflowId)' not found.",
                tool: name
            )
        }
        guard !workflow.steps.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Workflow '\(workflow.name)' has no structured steps to execute. "
                    + "Load it as guided context instead with `capabilities_load` "
                    + "(`{\"ids\": [\"workflow/\(workflow.id)\"]}`).",
                tool: name,
                retryable: false
            )
        }

        let runArgumentsJSON: String
        if let argumentsObject = args["arguments"],
            JSONSerialization.isValidJSONObject(argumentsObject),
            let data = try? JSONSerialization.data(withJSONObject: argumentsObject),
            let s = String(data: data, encoding: .utf8)
        {
            runArgumentsJSON = s
        } else if let s = args["arguments"] as? String {
            runArgumentsJSON = s
        } else {
            runArgumentsJSON = "{}"
        }

        let result: WorkflowRunResult
        do {
            result = try await WorkflowRunner.run(workflow: workflow, argumentsJSON: runArgumentsJSON)
        } catch let error as WorkflowRunnerError {
            if case .preflightFailed = error {
                // The workflow itself is broken — retrying with different
                // arguments cannot help.
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: name,
                    retryable: false
                )
            }
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: error.localizedDescription,
                field: "arguments",
                tool: name
            )
        }

        var text = "# Workflow: \(workflow.name) — \(statusLabel(result.status))\n\n"
        for step in result.stepOutputs {
            text += "## Step \(step.index): \(step.toolName)\n"
            text += step.output
            text += "\n\n"
        }
        switch result.status {
        case .completed:
            text += "All \(result.stepOutputs.count) step(s) completed successfully."
        case .handedOff:
            text += "## Continue manually\n"
            if let guidance = result.guidance, !guidance.isEmpty {
                text += guidance + "\n"
            }
            if !result.remainingSteps.isEmpty {
                text += "\nRemaining steps:\n"
                text += WorkflowSaveTool.renderBody(
                    description: "",
                    parameters: [],
                    steps: result.remainingSteps
                )
            }
        case .failed:
            text += "## Failed\n"
            text += result.failureMessage ?? "A step failed."
            text += "\nThe remaining steps did not run. Recover manually or report the failure to the user."
        }

        if result.status == .failed {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: text,
                tool: name,
                retryable: true
            )
        }
        return ToolEnvelope.success(tool: name, text: text)
    }

    private func statusLabel(_ status: WorkflowRunResult.Status) -> String {
        switch status {
        case .completed: return "completed"
        case .handedOff: return "handed off"
        case .failed: return "failed"
        }
    }
}
