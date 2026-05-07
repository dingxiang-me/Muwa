// Copyright © 2026 osaurus.

import Foundation
import Testing

@Suite("Runtime source policy")
struct RuntimePolicySourceTests {
    private static func packageRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Service/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("AppDelegate leaves DSV4 cache topology to vmlx")
    func appDelegateDoesNotForceDSV4DiagnosticCacheMode() throws {
        let source = try Self.source("AppDelegate.swift")

        #expect(
            !source.contains("setenv(\"DSV4_KV_MODE\""),
            "osaurus must not force DSV4_KV_MODE; unset keeps vmlx's SWA+CSA+HSA default"
        )
        #expect(
            !source.contains("DSV4_KV_MODE=full"),
            "full KV mode is diagnostic-only and drops DSV4 hybrid pool cache"
        )
        #expect(source.contains("SWA+CSA+HSA"))
    }

    @Test("vmlx pin includes Ling multi-turn + ZAYA hardening commit")
    func vmlxPinIncludesRuntimeHardening() throws {
        let manifest = try Self.source("Package.swift")

        // Bumped 2026-05-07 from 4a832400 (DSV4 + Laguna) to 88fc352b
        // (BailingHybrid B>1 RoPE/per-slot offsets, ZAYA1 CCA hybrid,
        // ReasoningParser prompt-tail, Gemma4 SWA, audio MediaSalt).
        // The earlier comments still document DSV4Cache and Laguna so
        // those content anchors remain valid as a smoke that the bump
        // narrative wasn't dropped wholesale.
        #expect(manifest.contains("88fc352b932a61ae4cfeb763fffc6547ad9725a4"))
        #expect(manifest.contains("DeepseekV4Cache"))
        #expect(manifest.contains("Laguna include-only bundles"))
    }
}
