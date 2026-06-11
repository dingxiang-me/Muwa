//
//  WorkflowContract.swift
//  osaurus
//
//  The workflow argument contract: declared parameters plus the step
//  templates that consume them. One place renders the `workflow_run`
//  invocation example (discover / load / save ack) and one place
//  statically validates that a workflow's steps can actually execute —
//  used as a save-time gate in `workflow_save` and as a run-time
//  preflight in `WorkflowRunner`.
//

import Foundation

public enum WorkflowContract {

    // MARK: - Run invocation example

    /// Concrete `workflow_run` arguments JSON built from the declared
    /// parameters, e.g.
    /// `{"id": "abc", "arguments": {"path": "<string, required — source PDF>"}}`.
    /// Workflows without parameters render as `{"id": "abc"}` so models
    /// don't invent argument keys the runner would reject.
    public static func runExampleJSON(workflowId: String, parameters: [WorkflowParameter]) -> String {
        guard !parameters.isEmpty else {
            return "{\"id\": \"\(workflowId)\"}"
        }
        let args = parameters
            .map { param -> String in
                var hint = param.type.rawValue
                hint += param.required ? ", required" : ", optional"
                if let fallback = param.defaultValue {
                    hint += ", default: \(fallback)"
                }
                if !param.description.isEmpty {
                    hint += " — \(param.description)"
                }
                return "\"\(param.name)\": \"<\(hint)>\""
            }
            .joined(separator: ", ")
        return "{\"id\": \"\(workflowId)\", \"arguments\": {\(args)}}"
    }

    // MARK: - Static step validation

    /// One actionable defect found by `validate`. `stepIndex` is 1-based;
    /// nil for workflow-level issues (e.g. an unused required parameter).
    public struct Issue: Equatable, Sendable {
        public let stepIndex: Int?
        public let message: String

        public var rendered: String {
            if let stepIndex {
                return "Step \(stepIndex): \(message)"
            }
            return message
        }
    }

    /// What part of the workflow a validation pass covers.
    public enum Scope {
        /// All steps plus workflow-level lint (unused required parameters).
        /// Used by `workflow_save` so the authoring model fixes everything.
        case fullWorkflow
        /// Only the steps the runner will actually execute — up to the
        /// first guidance step. Post-handoff tool steps run manually under
        /// model judgment, so they must not block `workflow_run`.
        case executablePrefix
    }

    /// Statically check that every tool step can execute once parameters
    /// are bound: placeholders reference declared parameters and earlier
    /// step outputs, templates render to valid JSON objects, and rendered
    /// arguments satisfy each tool's schema (required properties, types).
    ///
    /// `toolSchemas` maps tool name → argument schema for the tools the
    /// caller could resolve. Steps whose tool is absent from the map skip
    /// the schema check — an unloaded plugin tool must not block a save.
    ///
    /// Returns an empty array when the workflow is runnable.
    public static func validate(
        parameters: [WorkflowParameter],
        steps allSteps: [WorkflowStep],
        toolSchemas: [String: JSONValue],
        scope: Scope = .fullWorkflow
    ) -> [Issue] {
        let steps: [WorkflowStep]
        switch scope {
        case .fullWorkflow:
            steps = allSteps
        case .executablePrefix:
            let prefixEnd = allSteps.firstIndex(where: { $0.kind == .guidance }) ?? allSteps.count
            steps = Array(allSteps.prefix(prefixEnd))
        }

        var issues: [Issue] = []
        let declaredNames = Set(parameters.map(\.name))
        var referencedParams = Set<String>()

        // Type-correct sample values so templates render to JSON that the
        // schema validator can meaningfully check.
        var sampleValues: [String: WorkflowRunner.SubstitutionValue] = [:]
        for param in parameters {
            switch param.type {
            case .string: sampleValues[param.name] = .string(param.defaultValue ?? "sample")
            case .number: sampleValues[param.name] = .literal(param.defaultValue ?? "1")
            case .boolean: sampleValues[param.name] = .literal(param.defaultValue ?? "true")
            }
        }

        for (offset, step) in steps.enumerated() {
            let index = offset + 1

            // Track parameter usage in guidance text too: a parameter that
            // only informs the guidance handoff is legitimate.
            if step.kind == .guidance {
                referencedParams.formUnion(paramPlaceholders(in: step.text ?? ""))
                continue
            }

            guard let toolName = step.toolName, !toolName.isEmpty else {
                issues.append(Issue(stepIndex: index, message: "tool step has no tool name."))
                continue
            }

            let template = step.argsTemplate ?? "{}"
            let paramRefs = paramPlaceholders(in: template)
            referencedParams.formUnion(paramRefs)

            let undeclared = paramRefs.subtracting(declaredNames).sorted()
            if !undeclared.isEmpty {
                let names = undeclared.map { "`\($0)`" }.joined(separator: ", ")
                let example = undeclared.map {
                    "{\"name\": \"\($0)\", \"type\": \"string\", \"description\": \"...\", \"required\": true}"
                }
                .joined(separator: ", ")
                issues.append(
                    Issue(
                        stepIndex: index,
                        message:
                            "args_template references undeclared parameter(s) \(names). "
                            + "Add them to the top-level `parameters` array — e.g. `\"parameters\": [\(example)]` — "
                            + "or replace the placeholder(s) with literal values if they never vary."
                    )
                )
                continue
            }

            var stepSamples: [Int: String] = [:]
            var badStepRef = false
            for ref in stepOutputPlaceholders(in: template) {
                if ref < 1 || ref >= index {
                    issues.append(
                        Issue(
                            stepIndex: index,
                            message:
                                "args_template references `{{steps.\(ref).output}}`, "
                                + "but only steps 1..\(index - 1) run before step \(index)."
                        )
                    )
                    badStepRef = true
                } else {
                    stepSamples[ref] = "sample"
                }
            }
            if badStepRef { continue }

            let rendered = WorkflowRunner.substitute(
                template: template,
                params: sampleValues,
                stepOutputs: stepSamples
            )
            if rendered.contains("{{") {
                issues.append(
                    Issue(
                        stepIndex: index,
                        message:
                            "args_template contains unrecognized placeholder syntax. "
                            + "Only `{{params.<name>}}` and `{{steps.<n>.output}}` are supported."
                    )
                )
                continue
            }

            guard let data = rendered.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: data),
                parsed is [String: Any]
            else {
                issues.append(
                    Issue(
                        stepIndex: index,
                        message: "args_template for `\(toolName)` is not a valid JSON object."
                    )
                )
                continue
            }

            guard let schema = toolSchemas[toolName] else { continue }
            guard let args = parsed as? [String: Any] else { continue }
            let coerced = SchemaValidator.coerceArguments(args, against: schema)
            let result = SchemaValidator.validate(arguments: coerced, against: schema)
            if !result.isValid, let message = result.errorMessage {
                // Value-level failures (enum, pattern, range) on fields the
                // template fills from a placeholder are not static defects —
                // the real value only exists at run time. Structural
                // failures (missing required, unexpected key) still report.
                if let field = result.field,
                    isPlaceholderValued(field: field, template: template, schema: schema)
                {
                    continue
                }
                var fix = message
                if let field = result.field, args[field] == nil {
                    fix +=
                        ". Add it to args_template — promote task-specific values to parameters, "
                        + "e.g. `{\"\(field)\": \"{{params.\(field)}}\"}` with `\(field)` declared in `parameters`."
                }
                issues.append(
                    Issue(stepIndex: index, message: "`\(toolName)` args_template is invalid: \(fix)")
                )
            }
        }

        if scope == .fullWorkflow {
            for param in parameters where param.required && !referencedParams.contains(param.name) {
                issues.append(
                    Issue(
                        stepIndex: nil,
                        message:
                            "Required parameter `\(param.name)` is never referenced by any step. "
                            + "Reference it as `{{params.\(param.name)}}` or remove it."
                    )
                )
            }
        }

        return issues
    }

    /// True when `field` is a declared schema property whose raw template
    /// value is a string carrying a placeholder — its real value is bound
    /// at run time, so static value checks must not reject it.
    private static func isPlaceholderValued(
        field: String,
        template: String,
        schema: JSONValue
    ) -> Bool {
        guard case .object(let schemaObj) = schema,
            case .object(let props)? = schemaObj["properties"],
            props[field] != nil,
            let data = template.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = raw[field] as? String
        else { return false }
        return value.contains("{{")
    }

    /// Resolve argument schemas for the given tool names from the live
    /// registry. Names the registry doesn't know are omitted.
    @MainActor
    public static func registrySchemas(for toolNames: [String]) -> [String: JSONValue] {
        var schemas: [String: JSONValue] = [:]
        for name in Set(toolNames) {
            if let schema = ToolRegistry.shared.parametersForTool(name: name) {
                schemas[name] = schema
            }
        }
        return schemas
    }

    // MARK: - Placeholder scanning

    private static let paramPattern = /\{\{params\.([A-Za-z0-9_\-]+)\}\}/
    private static let stepPattern = /\{\{steps\.([0-9]+)\.output\}\}/

    static func paramPlaceholders(in text: String) -> Set<String> {
        Set(text.matches(of: paramPattern).map { String($0.1) })
    }

    static func stepOutputPlaceholders(in text: String) -> Set<Int> {
        Set(text.matches(of: stepPattern).compactMap { Int($0.1) })
    }
}
