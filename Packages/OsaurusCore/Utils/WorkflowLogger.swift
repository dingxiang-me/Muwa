//
//  WorkflowLogger.swift
//  osaurus
//
//  Structured logger for the workflows subsystem using os.Logger.
//  Zero-cost when not collected; filterable in Console.app / Instruments.
//

import Foundation
import os

public enum WorkflowLogger {
    static let service = Logger(subsystem: "ai.osaurus", category: "workflow.service")
    static let search = Logger(subsystem: "ai.osaurus", category: "workflow.search")
    static let database = Logger(subsystem: "ai.osaurus", category: "workflow.database")
    static let runner = Logger(subsystem: "ai.osaurus", category: "workflow.runner")
}
