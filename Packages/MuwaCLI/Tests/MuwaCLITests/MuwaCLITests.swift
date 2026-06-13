//
//  MuwaCLITests.swift
//  Muwa
//
//  Unit tests for the Muwa CLI core functionality.
//

import XCTest
@testable import MuwaCLICore

final class MuwaCLITests: XCTestCase {
    func testConfiguration() {
        // Just a smoke test to ensure things link
        let root = Configuration.toolsRootDirectory()
        XCTAssertFalse(root.path.isEmpty)
    }
}
