//
//  OsrHostAPILayoutTests.swift
//  Muwa Plugin Test KitTests
//
//  Plugins that hand-define a Swift copy of `osr_host_api` must preserve
//  the exact field order from `muwa_plugin.h`. Appending `free_string`
//  immediately after `get_active_agent_id` while omitting `log_structured`
//  shifts every trailing offset and leads to calling the wrong function
//  pointers (production symptom: `free` of a non-heap pointer).
//

import Foundation
import Testing

@testable import MuwaPluginTestKit

struct OsrHostAPILayoutTests {

    @Test func layoutMatchesFrozenCABI() {
        #expect(MemoryLayout<OsrHostAPI>.size == 200)
        #expect(MemoryLayout<OsrHostAPI>.stride == 200)
        #expect(MemoryLayout<OsrHostAPI>.alignment == 8)
        #expect(MemoryLayout<OsrHostAPI>.offset(of: \.version) == 0)
        #expect(MemoryLayout<OsrHostAPI>.offset(of: \.configGet) == 8)
        #expect(MemoryLayout<OsrHostAPI>.offset(of: \.getActiveAgentId) == 176)
        #expect(MemoryLayout<OsrHostAPI>.offset(of: \.logStructured) == 184)
        #expect(MemoryLayout<OsrHostAPI>.offset(of: \.freeString) == 192)
    }
}
