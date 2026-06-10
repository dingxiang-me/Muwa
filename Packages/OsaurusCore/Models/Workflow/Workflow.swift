//
//  Workflow.swift
//  osaurus
//
//  Models for the workflows subsystem: reusable, parameterized tool-call
//  procedures, scoring events, and computed scores.
//

import Foundation

// MARK: - WorkflowParameterType

public enum WorkflowParameterType: String, Codable, Sendable {
    case string
    case number
    case boolean
}

// MARK: - WorkflowParameter

/// Declared input for a workflow. `workflow_run` validates the caller's
/// arguments against these before any step executes.
public struct WorkflowParameter: Codable, Sendable, Equatable {
    public let name: String
    public let type: WorkflowParameterType
    public let description: String
    public let required: Bool
    /// Textual default substituted when the caller omits the parameter.
    public let defaultValue: String?

    enum CodingKeys: String, CodingKey {
        case name, type, description, required
        case defaultValue = "default"
    }

    public init(
        name: String,
        type: WorkflowParameterType = .string,
        description: String = "",
        required: Bool = true,
        defaultValue: String? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
    }
}

// MARK: - WorkflowStep

/// One step of a workflow. Two kinds:
///   - `tool`: deterministic — `WorkflowRunner` executes `toolName` with
///     `argsTemplate` after substituting `{{params.x}}` and
///     `{{steps.N.output}}` placeholders.
///   - `guidance`: free-text instruction for the calling model. The runner
///     stops here and hands the remaining steps back as context.
public struct WorkflowStep: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case tool
        case guidance
    }

    public let kind: Kind
    /// Tool to execute (tool steps only).
    public let toolName: String?
    /// JSON object template for the tool arguments. Supports
    /// `{{params.<name>}}` and `{{steps.<n>.output}}` placeholders
    /// (steps are 1-based).
    public let argsTemplate: String?
    /// Optional skill whose instructions should be in context for this step.
    public let skillContext: String?
    /// Instruction text (guidance steps only).
    public let text: String?

    public init(
        kind: Kind,
        toolName: String? = nil,
        argsTemplate: String? = nil,
        skillContext: String? = nil,
        text: String? = nil
    ) {
        self.kind = kind
        self.toolName = toolName
        self.argsTemplate = argsTemplate
        self.skillContext = skillContext
        self.text = text
    }

    public static func tool(
        _ name: String,
        argsTemplate: String? = nil,
        skillContext: String? = nil
    ) -> WorkflowStep {
        WorkflowStep(kind: .tool, toolName: name, argsTemplate: argsTemplate, skillContext: skillContext)
    }

    public static func guidance(_ text: String, skillContext: String? = nil) -> WorkflowStep {
        WorkflowStep(kind: .guidance, skillContext: skillContext, text: text)
    }
}

// MARK: - Workflow

public struct Workflow: Identifiable, Codable, Sendable {
    public let id: String
    public var name: String
    public var description: String
    public var triggerText: String?
    /// Human/model-readable body (YAML or markdown). Returned verbatim by
    /// `capabilities_load` for guided (non-executing) use.
    public var body: String
    public var source: WorkflowSource
    public var sourceModel: String?
    public var tier: WorkflowTier
    /// Declared inputs for `workflow_run`. Empty for guidance-only workflows.
    public var parameters: [WorkflowParameter]
    /// Structured steps for `WorkflowRunner`. Empty for legacy/body-only
    /// workflows, which can still be loaded as guided context.
    public var steps: [WorkflowStep]
    public var toolsUsed: [String]
    public var skillsUsed: [String]
    public var tokenCount: Int
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String,
        triggerText: String? = nil,
        body: String,
        source: WorkflowSource,
        sourceModel: String? = nil,
        tier: WorkflowTier = .active,
        parameters: [WorkflowParameter] = [],
        steps: [WorkflowStep] = [],
        toolsUsed: [String] = [],
        skillsUsed: [String] = [],
        tokenCount: Int = 0,
        version: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.triggerText = triggerText
        self.body = body
        self.source = source
        self.sourceModel = sourceModel
        self.tier = tier
        self.parameters = parameters
        self.steps = steps
        self.toolsUsed = toolsUsed
        self.skillsUsed = skillsUsed
        self.tokenCount = tokenCount
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - WorkflowSource

public enum WorkflowSource: String, Codable, Sendable {
    case user
    /// Saved from chat by a model via `workflow_save`.
    case agent
}

// MARK: - WorkflowTier

public enum WorkflowTier: String, Codable, Sendable {
    case active
}

// MARK: - WorkflowEventType

public enum WorkflowEventType: String, Codable, Sendable {
    case loaded
    case succeeded
    case failed
}

// MARK: - WorkflowEvent

public struct WorkflowEvent: Identifiable, Sendable {
    public let id: Int
    public let workflowId: String
    public let eventType: WorkflowEventType
    public let modelUsed: String?
    /// For `.loaded` events this stores the issue ID, linking the workflow to the work session.
    public let agentId: String?
    public let notes: String?
    public let createdAt: Date

    public init(
        id: Int = 0,
        workflowId: String,
        eventType: WorkflowEventType,
        modelUsed: String? = nil,
        agentId: String? = nil,
        notes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workflowId = workflowId
        self.eventType = eventType
        self.modelUsed = modelUsed
        self.agentId = agentId
        self.notes = notes
        self.createdAt = createdAt
    }
}

// MARK: - WorkflowScore

public struct WorkflowScore: Sendable {
    public let workflowId: String
    public var timesLoaded: Int
    public var timesSucceeded: Int
    public var timesFailed: Int
    public var successRate: Double
    public var lastUsedAt: Date?
    public var score: Double

    public init(
        workflowId: String,
        timesLoaded: Int = 0,
        timesSucceeded: Int = 0,
        timesFailed: Int = 0,
        successRate: Double = 0.0,
        lastUsedAt: Date? = nil,
        score: Double = 0.0
    ) {
        self.workflowId = workflowId
        self.timesLoaded = timesLoaded
        self.timesSucceeded = timesSucceeded
        self.timesFailed = timesFailed
        self.successRate = successRate
        self.lastUsedAt = lastUsedAt
        self.score = score
    }

    /// Recomputes `successRate` and `score` from the current counts and `lastUsedAt`.
    public mutating func recalculate() {
        let total = timesSucceeded + timesFailed
        successRate = total > 0 ? Double(timesSucceeded) / Double(total) : 0.0

        let daysSinceUsed: Double
        if let last = lastUsedAt {
            daysSinceUsed = max(0, Date().timeIntervalSince(last) / 86400.0)
        } else {
            daysSinceUsed = 365
        }
        let recencyWeight = 1.0 / (1.0 + daysSinceUsed / 30.0)
        score = successRate * recencyWeight
    }
}

// MARK: - WorkflowSearchResult

public struct WorkflowSearchResult: Sendable {
    public let workflow: Workflow
    public let searchScore: Float
    public let score: Double

    public init(workflow: Workflow, searchScore: Float, score: Double) {
        self.workflow = workflow
        self.searchScore = searchScore
        self.score = score
    }
}
