//
//  MethodLogger.swift
//  Muwa
//
//  Structured logger for the methods subsystem using os.Logger.
//  Zero-cost when not collected; filterable in Console.app / Instruments.
//

import Foundation
import os

public enum MethodLogger {
    static let service = Logger(subsystem: "ai.muwa", category: "method.service")
    static let search = Logger(subsystem: "ai.muwa", category: "method.search")
    static let database = Logger(subsystem: "ai.muwa", category: "method.database")
}
