//
//  MemoryLogger.swift
//  Muwa
//
//  Structured logger for the memory subsystem using os.Logger.
//  Zero-cost when not collected; filterable in Console.app / Instruments.
//

import Foundation
import os

public enum MemoryLogger {
    static let service = Logger(subsystem: "ai.muwa", category: "memory.service")
    static let search = Logger(subsystem: "ai.muwa", category: "memory.search")
    static let database = Logger(subsystem: "ai.muwa", category: "memory.database")
    static let config = Logger(subsystem: "ai.muwa", category: "memory.config")
}
