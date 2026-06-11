//
//  WorkflowRunnerTests.swift
//  osaurus
//
//  Unit tests for WorkflowRunner: parameter validation and coercion,
//  template substitution (params + step outputs, JSON escaping), and
//  the guidance handoff path. Tool-step execution is integration-level
//  (it dispatches through the live ToolRegistry) and is exercised by
//  the guidance-first cases here without touching real tools.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowRunnerParameterTests {

    private func workflow(parameters: [WorkflowParameter]) -> Workflow {
        Workflow(
            name: "test",
            description: "test",
            body: "",
            source: .user,
            parameters: parameters,
            steps: [.guidance("noop")]
        )
    }

    @Test func missingRequiredParameterThrows() {
        let wf = workflow(parameters: [WorkflowParameter(name: "path", required: true)])
        #expect(throws: WorkflowRunnerError.missingRequiredParameter("path")) {
            _ = try WorkflowRunner.resolveParameters(workflow: wf, argumentsJSON: "{}")
        }
    }

    @Test func optionalParameterMayBeOmitted() throws {
        let wf = workflow(parameters: [WorkflowParameter(name: "path", required: false)])
        let resolved = try WorkflowRunner.resolveParameters(workflow: wf, argumentsJSON: "{}")
        #expect(resolved["path"] == nil)
    }

    @Test func defaultBackfillsMissingParameter() throws {
        let wf = workflow(
            parameters: [WorkflowParameter(name: "count", type: .number, required: true, defaultValue: "3")]
        )
        let resolved = try WorkflowRunner.resolveParameters(workflow: wf, argumentsJSON: "{}")
        #expect(resolved["count"]?.jsonEscapedText == "3")
    }

    @Test func stringParameterAccepted() throws {
        let wf = workflow(parameters: [WorkflowParameter(name: "path", type: .string)])
        let resolved = try WorkflowRunner.resolveParameters(
            workflow: wf,
            argumentsJSON: "{\"path\": \"report.pdf\"}"
        )
        #expect(resolved["path"]?.jsonEscapedText == "report.pdf")
    }

    @Test func numberParameterRejectsNonNumericString() {
        let wf = workflow(parameters: [WorkflowParameter(name: "count", type: .number)])
        #expect(throws: WorkflowRunnerError.invalidParameterType(name: "count", expected: "number")) {
            _ = try WorkflowRunner.resolveParameters(
                workflow: wf,
                argumentsJSON: "{\"count\": \"lots\"}"
            )
        }
    }

    @Test func numberParameterAcceptsNumericLiteral() throws {
        let wf = workflow(parameters: [WorkflowParameter(name: "count", type: .number)])
        let resolved = try WorkflowRunner.resolveParameters(
            workflow: wf,
            argumentsJSON: "{\"count\": 7}"
        )
        #expect(resolved["count"]?.jsonEscapedText == "7")
    }

    @Test func booleanParameterAcceptsBool() throws {
        let wf = workflow(parameters: [WorkflowParameter(name: "verbose", type: .boolean)])
        let resolved = try WorkflowRunner.resolveParameters(
            workflow: wf,
            argumentsJSON: "{\"verbose\": true}"
        )
        #expect(resolved["verbose"]?.jsonEscapedText == "true")
    }

    @Test func booleanParameterRejectsNumber() {
        let wf = workflow(parameters: [WorkflowParameter(name: "verbose", type: .boolean)])
        #expect(throws: WorkflowRunnerError.invalidParameterType(name: "verbose", expected: "boolean")) {
            _ = try WorkflowRunner.resolveParameters(
                workflow: wf,
                argumentsJSON: "{\"verbose\": 2}"
            )
        }
    }
}

struct WorkflowRunnerSubstitutionTests {

    @Test func substitutesParams() {
        let result = WorkflowRunner.substitute(
            template: "{\"command\": \"cat {{params.path}}\"}",
            params: ["path": .string("report.pdf")],
            stepOutputs: [:]
        )
        #expect(result == "{\"command\": \"cat report.pdf\"}")
    }

    @Test func substitutesStepOutputs() {
        let result = WorkflowRunner.substitute(
            template: "{\"text\": \"{{steps.1.output}}\"}",
            params: [:],
            stepOutputs: [1: "hello"]
        )
        #expect(result == "{\"text\": \"hello\"}")
    }

    @Test func jsonEscapesStringValues() {
        let result = WorkflowRunner.substitute(
            template: "{\"text\": \"{{params.message}}\"}",
            params: ["message": .string("line1\nline2 \"quoted\"")],
            stepOutputs: [:]
        )
        #expect(result == "{\"text\": \"line1\\nline2 \\\"quoted\\\"\"}")
        // The substituted template must remain parseable JSON.
        let data = result.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["text"] as? String == "line1\nline2 \"quoted\"")
    }

    @Test func numberLiteralsSubstituteUnquoted() {
        let result = WorkflowRunner.substitute(
            template: "{\"count\": {{params.count}}}",
            params: ["count": .literal("7")],
            stepOutputs: [:]
        )
        let data = result.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["count"] as? Int == 7)
    }
}

struct WorkflowRunnerHandoffTests {

    @Test func guidanceStepHandsOffWithRemainingSteps() async throws {
        let workflow = Workflow(
            name: "handoff",
            description: "stops at guidance",
            body: "",
            source: .user,
            steps: [
                .guidance("Inspect the data manually."),
                .tool("terminal", argsTemplate: "{}"),
            ]
        )
        let result = try await WorkflowRunner.run(
            workflow: workflow,
            argumentsJSON: "{}",
            recordOutcome: false
        )
        #expect(result.status == .handedOff)
        #expect(result.guidance == "Inspect the data manually.")
        #expect(result.stepOutputs.isEmpty)
        #expect(result.remainingSteps == [WorkflowStep.tool("terminal", argsTemplate: "{}")])
    }

    @Test func invalidArgumentsThrowBeforeAnyStepRuns() async {
        let workflow = Workflow(
            name: "validation",
            description: "requires a parameter",
            body: "",
            source: .user,
            parameters: [WorkflowParameter(name: "path", required: true)],
            steps: [.guidance("noop")]
        )
        await #expect(throws: WorkflowRunnerError.missingRequiredParameter("path")) {
            _ = try await WorkflowRunner.run(
                workflow: workflow,
                argumentsJSON: "{}",
                recordOutcome: false
            )
        }
    }

    @Test func toolStepWithoutNameFailsPreflight() async {
        let workflow = Workflow(
            name: "bad-step",
            description: "tool step missing name",
            body: "",
            source: .user,
            steps: [WorkflowStep(kind: .tool)]
        )
        do {
            _ = try await WorkflowRunner.run(
                workflow: workflow,
                argumentsJSON: "{}",
                recordOutcome: false
            )
            Issue.record("Expected preflightFailed to be thrown")
        } catch let error as WorkflowRunnerError {
            guard case .preflightFailed(let message) = error else {
                Issue.record("Expected preflightFailed, got \(error)")
                return
            }
            #expect(message.contains("tool step has no tool name"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
