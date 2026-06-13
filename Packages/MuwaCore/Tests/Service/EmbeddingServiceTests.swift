//
//  EmbeddingServiceTests.swift
//  Muwa
//

import Foundation
import Testing

@testable import MuwaCore

struct EmbeddingServiceTests {

    @Test func embeddingDimensionIs128() {
        #expect(EmbeddingService.embeddingDimension == 128)
    }

    @Test func modelNameIsPotion() {
        #expect(EmbeddingService.modelName == "potion-base-4M")
    }
}
