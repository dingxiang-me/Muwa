//
//  ChatEngineProtocol.swift
//  osaurus
//

import Foundation

protocol ChatEngineProtocol: Sendable {
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error>
    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse
}

/// Classified error thrown by chat-engine implementations so the HTTP
/// layer can emit 4xx/5xx instead of a generic 500. Implementations
/// throw cases here; engine HTTPHandler catches by this type.
struct ChatEngineError: Error, LocalizedError {
    enum Kind {
        case modelNotFound(requested: String)
        case noServiceAvailable(requested: String)
    }

    let kind: Kind

    var errorDescription: String? {
        switch kind {
        case .modelNotFound(let requested):
            return "Model '\(requested)' is not installed or registered with any provider."
        case .noServiceAvailable(let requested):
            return "No service is currently available to handle model '\(requested)'."
        }
    }

    var httpStatus: Int {
        switch kind {
        case .modelNotFound: return 404
        case .noServiceAvailable: return 503
        }
    }
}
