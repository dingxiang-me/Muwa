//
//  WorkflowRunner.swift
//  osaurus
//
//  Deterministic executor for parameterized workflows. Validates the
//  caller's arguments against the workflow's declared parameters, runs
//  `tool` steps sequentially through `ToolRegistry`, and hands control
//  back to the calling model at the first `guidance` step or failure.
//  Outcomes feed the existing workflow scoring (loaded/succeeded/failed).
//

import Foundation

// MARK: - Errors

public enum WorkflowRunnerError: Error, LocalizedError, Equatable {
    case missingRequiredParameter(String)
    case invalidParameterType(name: String, expected: String)
    case invalidStep(index: Int, reason: String)
    case unknownArguments(provided: [String], declared: [String])
    case preflightFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .missingRequiredParameter(let name):
            return "Missing required parameter `\(name)`."
        case .invalidParameterType(let name, let expected):
            return "Parameter `\(name)` must be a \(expected)."
        case .invalidStep(let index, let reason):
            return "Step \(index) is invalid: \(reason)"
        case .unknownArguments(let provided, let declared):
            let providedList = provided.map { "`\($0)`" }.joined(separator: ", ")
            if declared.isEmpty {
                return "Unknown argument(s) \(providedList) — this workflow takes no arguments. "
                    + "Call `workflow_run` with just the `id`."
            }
            return "Unknown argument(s) \(providedList). This workflow's declared parameters are: "
                + declared.joined(separator: ", ") + "."
        case .preflightFailed(let message):
            return message
        }
    }
}

// MARK: - Result

public struct WorkflowRunResult: Sendable {
    public enum Status: String, Sendable {
        /// Every tool step executed successfully.
        case completed
        /// Execution stopped at a `guidance` step; the calling model
        /// continues with the guidance text plus remaining steps.
        case handedOff
        /// A tool step returned an error envelope; execution stopped.
        case failed
    }

    public struct StepOutput: Sendable {
        /// 1-based step index within the workflow.
        public let index: Int
        public let toolName: String
        public let output: String
    }

    public let status: Status
    public let stepOutputs: [StepOutput]
    /// Guidance text when `status == .handedOff`.
    public let guidance: String?
    /// Steps that did not run (handoff or failure).
    public let remainingSteps: [WorkflowStep]
    /// Failure description when `status == .failed`.
    public let failureMessage: String?
}

// MARK: - WorkflowRunner

public enum WorkflowRunner {

    /// Hard cap on executed steps per run so a malformed workflow can't
    /// monopolize the agent loop.
    static let maxSteps = 50

    /// Run a workflow's structured steps with the given arguments
    /// (JSON object string). Throws `WorkflowRunnerError` for argument
    /// validation failures; step execution failures are reported in the
    /// returned result, not thrown.
    ///
    /// `recordOutcome` lets tests exercise the runner without mutating
    /// the shared scoring tables.
    public static func run(
        workflow: Workflow,
        argumentsJSON: String,
        recordOutcome: Bool = true
    ) async throws -> WorkflowRunResult {
        let params = try resolveParameters(workflow: workflow, argumentsJSON: argumentsJSON)
        try await preflight(workflow: workflow)

        var outputs: [WorkflowRunResult.StepOutput] = []
        var stepOutputsByIndex: [Int: String] = [:]

        let steps = Array(workflow.steps.prefix(Self.maxSteps))
        for (offset, step) in steps.enumerated() {
            let index = offset + 1
            switch step.kind {
            case .guidance:
                let remaining = Array(workflow.steps.dropFirst(offset + 1))
                let result = WorkflowRunResult(
                    status: .handedOff,
                    stepOutputs: outputs,
                    guidance: step.text ?? "",
                    remainingSteps: remaining,
                    failureMessage: nil
                )
                await report(.loaded, workflow: workflow, recordOutcome: recordOutcome)
                return result

            case .tool:
                guard let toolName = step.toolName, !toolName.isEmpty else {
                    throw WorkflowRunnerError.invalidStep(index: index, reason: "tool step has no tool name")
                }
                let args = substitute(
                    template: step.argsTemplate ?? "{}",
                    params: params,
                    stepOutputs: stepOutputsByIndex
                )
                let result: String
                do {
                    result = try await ToolRegistry.shared.execute(name: toolName, argumentsJSON: args)
                } catch {
                    let message =
                        "Step \(index) (`\(toolName)`) threw: \(error.localizedDescription)"
                        + contractHint(for: workflow)
                    await report(.failed, workflow: workflow, recordOutcome: recordOutcome, notes: message)
                    return WorkflowRunResult(
                        status: .failed,
                        stepOutputs: outputs,
                        guidance: nil,
                        remainingSteps: Array(workflow.steps.dropFirst(offset)),
                        failureMessage: message
                    )
                }
                if ToolEnvelope.isError(result) {
                    let message =
                        "Step \(index) (`\(toolName)`) failed: \(result)"
                        + contractHint(for: workflow)
                    await report(.failed, workflow: workflow, recordOutcome: recordOutcome, notes: message)
                    return WorkflowRunResult(
                        status: .failed,
                        stepOutputs: outputs,
                        guidance: nil,
                        remainingSteps: Array(workflow.steps.dropFirst(offset)),
                        failureMessage: message
                    )
                }
                outputs.append(.init(index: index, toolName: toolName, output: result))
                stepOutputsByIndex[index] = result
            }
        }

        let result = WorkflowRunResult(
            status: .completed,
            stepOutputs: outputs,
            guidance: nil,
            remainingSteps: [],
            failureMessage: nil
        )
        await report(.succeeded, workflow: workflow, recordOutcome: recordOutcome)
        return result
    }

    // MARK: - Preflight

    /// Statically validate every tool step before executing anything: a
    /// workflow whose templates can't satisfy its tools' schemas (e.g.
    /// saved before contract validation existed) fails fast with no side
    /// effects and a recovery path, instead of dying mid-run on the
    /// first tool error.
    static func preflight(workflow: Workflow) async throws {
        let toolSchemas = await MainActor.run {
            WorkflowContract.registrySchemas(for: workflow.steps.compactMap(\.toolName))
        }
        let issues = WorkflowContract.validate(
            parameters: workflow.parameters,
            steps: workflow.steps,
            toolSchemas: toolSchemas,
            scope: .executablePrefix
        )
        guard !issues.isEmpty else { return }
        let detail = issues.map { "- \($0.rendered)" }.joined(separator: "\n")
        throw WorkflowRunnerError.preflightFailed(
            message:
                "Workflow '\(workflow.name)' cannot run as saved:\n\(detail)\n"
                + "No steps were executed. Load it as guided context with `capabilities_load` "
                + "(`{\"ids\": [\"workflow/\(workflow.id)\"]}`) and perform the steps manually, "
                + "or ask a capable model to re-save it with valid parameters and args_template values."
        )
    }

    /// `Workflow argument contract: ...` line appended to mid-run failure
    /// text so the model sees what it could have passed.
    private static func contractHint(for workflow: Workflow) -> String {
        let example = WorkflowContract.runExampleJSON(
            workflowId: workflow.id,
            parameters: workflow.parameters
        )
        return "\nWorkflow argument contract: `workflow_run \(example)`."
    }

    // MARK: - Parameter resolution

    /// Validate the raw arguments against the workflow's declared
    /// parameters: unknown-key rejection, required check, type check,
    /// default backfill. Returns the textual substitution value per
    /// parameter name.
    static func resolveParameters(
        workflow: Workflow,
        argumentsJSON: String
    ) throws -> [String: SubstitutionValue] {
        let raw: [String: Any]
        if let data = argumentsJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            raw = object
        } else {
            raw = [:]
        }

        // Undeclared keys used to be silently ignored, which left small
        // models looping: they'd pass `{"path": ...}` to a workflow with
        // no parameters and never learn the actual contract.
        let declaredNames = Set(workflow.parameters.map(\.name))
        let unknown = raw.keys.filter { !declaredNames.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw WorkflowRunnerError.unknownArguments(
                provided: unknown,
                declared: workflow.parameters.map(\.name)
            )
        }

        var resolved: [String: SubstitutionValue] = [:]
        for param in workflow.parameters {
            if let value = raw[param.name], !(value is NSNull) {
                resolved[param.name] = try coerce(value, for: param)
            } else if let fallback = param.defaultValue {
                resolved[param.name] = .string(fallback)
            } else if param.required {
                throw WorkflowRunnerError.missingRequiredParameter(param.name)
            }
        }
        return resolved
    }

    /// A validated parameter value carrying enough type information for
    /// JSON-aware template substitution: strings are escaped, numbers
    /// and booleans substitute as literals.
    enum SubstitutionValue: Equatable {
        case string(String)
        case literal(String)

        /// Replacement text when the placeholder sits inside a JSON
        /// string (already-escaped content, no surrounding quotes).
        var jsonEscapedText: String {
            switch self {
            case .string(let s): return Self.jsonEscape(s)
            case .literal(let s): return s
            }
        }

        static func jsonEscape(_ s: String) -> String {
            var out = ""
            out.reserveCapacity(s.count)
            for ch in s.unicodeScalars {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if ch.value < 0x20 {
                        out += String(format: "\\u%04x", ch.value)
                    } else {
                        out.unicodeScalars.append(ch)
                    }
                }
            }
            return out
        }
    }

    private static func coerce(_ value: Any, for param: WorkflowParameter) throws -> SubstitutionValue {
        switch param.type {
        case .string:
            if let s = value as? String { return .string(s) }
            if let n = value as? NSNumber { return .string(n.stringValue) }
            throw WorkflowRunnerError.invalidParameterType(name: param.name, expected: "string")
        case .number:
            if let n = value as? NSNumber, !Self.isBoolean(n) {
                return .literal(n.stringValue)
            }
            if let s = value as? String, Double(s) != nil { return .literal(s) }
            throw WorkflowRunnerError.invalidParameterType(name: param.name, expected: "number")
        case .boolean:
            if let n = value as? NSNumber, Self.isBoolean(n) {
                return .literal(n.boolValue ? "true" : "false")
            }
            if let s = value as? String, s == "true" || s == "false" { return .literal(s) }
            throw WorkflowRunnerError.invalidParameterType(name: param.name, expected: "boolean")
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Template substitution

    /// Replace `{{params.<name>}}` and `{{steps.<n>.output}}` in an
    /// args template. Values are substituted JSON-escaped so templates
    /// that interpolate inside string literals stay valid JSON; number
    /// and boolean parameters substitute as bare literals so templates
    /// like `"count": {{params.count}}` also work.
    static func substitute(
        template: String,
        params: [String: SubstitutionValue],
        stepOutputs: [Int: String]
    ) -> String {
        var out = template
        for (name, value) in params {
            out = out.replacingOccurrences(of: "{{params.\(name)}}", with: value.jsonEscapedText)
        }
        for (index, output) in stepOutputs {
            out = out.replacingOccurrences(
                of: "{{steps.\(index).output}}",
                with: SubstitutionValue.jsonEscape(output)
            )
        }
        return out
    }

    // MARK: - Scoring

    private static func report(
        _ outcome: WorkflowEventType,
        workflow: Workflow,
        recordOutcome: Bool,
        notes: String? = nil
    ) async {
        guard recordOutcome else { return }
        let sessionId = ChatExecutionContext.currentSessionId
        do {
            try await WorkflowService.shared.reportOutcome(
                workflowId: workflow.id,
                outcome: outcome,
                agentId: sessionId,
                notes: notes
            )
        } catch {
            WorkflowLogger.runner.error(
                "Failed to record \(outcome.rawValue) outcome for workflow \(workflow.id): \(error)"
            )
        }
    }
}
