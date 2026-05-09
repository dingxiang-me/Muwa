//
//  ChatMode.swift
//  OsaurusCore
//
//  Defines the operating mode for the chat interface.
//

import Foundation

/// Operating mode for the chat window
public enum ChatMode: String, Codable, Sendable {
    case dashboard
    case chat

    public var displayName: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .chat: return "Chat"
        }
    }

    public var icon: String {
        switch self {
        case .dashboard: return "rectangle.grid.3x1.fill"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }
}
