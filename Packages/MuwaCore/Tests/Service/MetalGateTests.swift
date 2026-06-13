//
//  MetalGateTests.swift
//  Muwa
//
//  Embeddings-only after the MLX runtime moved off `MetalGate.enterGeneration`.
//

import Foundation
import Testing

@testable import MuwaCore

@Suite(.serialized)
struct MetalGateTests {

    @Test func embeddingProceedsWhenIdle() async {
        await MetalGate.shared.enterEmbedding()
        await MetalGate.shared.exitEmbedding()
    }

    @Test func multipleEmbeddingsConcurrently() async {
        await MetalGate.shared.enterEmbedding()
        await MetalGate.shared.enterEmbedding()
        await MetalGate.shared.exitEmbedding()
        await MetalGate.shared.exitEmbedding()
    }
}
