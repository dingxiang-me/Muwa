//
//  SQLCipherVendorGuardTests.swift
//  MuwaTests
//
//  CI safety net for the vendored SQLCipher amalgamation.
//
//  These tests do NOT exercise SQLCipher behavior — that's covered
//  in `SQLCipherIntegrationTests` and `FTS5MemorySearchTests`.
//  Instead they assert invariants that *must* hold whenever a
//  maintainer bumps the SQLCipher version (which overwrites
//  `SQLCipher/sqlite3.h` with a fresh upstream copy):
//
//  - The MUWA LOCAL MODIFICATION wrapping the `_FTS5_H` block in
//    `#ifndef MUWA_OMIT_FTS5_HEADERS` must be present, otherwise
//    the build will succeed locally but break inside Xcode the
//    moment another module imports the system `SQLite3` (e.g.
//    vmlx-swift-lm's `DiskCache`).
//
//  - `Package.swift` must define `MUWA_OMIT_FTS5_HEADERS` in
//    cSettings — the guard is useless without the flag.
//
//  Each assertion has a long descriptive failure message so the
//  next person grepping their CI failure can find the README
//  recovery instructions in one click.
//

import Foundation
import Testing

@testable import MuwaCore

@Suite
struct SQLCipherVendorGuardTests {

    /// Locate `SQLCipher/include/sqlite3.h` regardless of the
    /// working directory the test was launched from. We walk up from
    /// `#filePath` until we find the package directory; this works
    /// for `swift test`, `xcodebuild test`, and the in-Xcode runner.
    private static func sqlite3HeaderURL() -> URL? {
        let here = URL(fileURLWithPath: #filePath)
        // Tests/Storage/SQLCipherVendorGuardTests.swift → walk up to
        // `Packages/MuwaCore/`.
        var cursor = here.deletingLastPathComponent()  // Storage/
        cursor.deleteLastPathComponent()  // Tests/
        let pkg = cursor.deletingLastPathComponent()  // MuwaCore/
        let header =
            pkg
            .appendingPathComponent("SQLCipher", isDirectory: true)
            .appendingPathComponent("include", isDirectory: true)
            .appendingPathComponent("sqlite3.h")
        return FileManager.default.fileExists(atPath: header.path) ? header : nil
    }

    private static func sqlCipherHeaderURL(named name: String) -> URL? {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Storage/
        cursor.deleteLastPathComponent()  // Tests/
        let pkg = cursor.deletingLastPathComponent()  // MuwaCore/
        let header =
            pkg
            .appendingPathComponent("SQLCipher", isDirectory: true)
            .appendingPathComponent("include", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: header.path) ? header : nil
    }

    @Test
    func sqlite3Header_containsFts5OmitGuard() throws {
        guard let url = Self.sqlite3HeaderURL() else {
            Issue.record(
                "Could not locate Packages/MuwaCore/SQLCipher/include/sqlite3.h. If the path moved, update this test."
            )
            return
        }
        let contents = try String(contentsOf: url, encoding: .utf8)

        let openGuard = "#ifndef MUWA_OMIT_FTS5_HEADERS"
        let closeGuard = "#endif /* MUWA_OMIT_FTS5_HEADERS"

        #expect(
            contents.contains(openGuard),
            """
            sqlite3.h is missing the MUWA_OMIT_FTS5_HEADERS open guard.

            This almost certainly means a SQLCipher amalgamation bump
            overwrote the MUWA LOCAL MODIFICATION block. Without
            this guard, `import MuwaSQLCipher` collides with Apple's
            system `SQLite3` module the moment another dep (e.g.
            vmlx-swift-lm's DiskCache) imports it in the same Swift
            unit, with errors like:

              'Fts5ExtensionApi' has different definitions in different modules
              'fts5_api'         has different definitions in different modules

            Re-apply the guard per the "Re-applying the FTS5 header
            guard" section of Packages/MuwaCore/SQLCipher/README.md.
            """
        )

        #expect(
            contents.contains(closeGuard),
            """
            sqlite3.h has the MUWA_OMIT_FTS5_HEADERS open guard
            but not the matching close. The wrap is incomplete; FTS5
            typedefs will still leak. Re-read the README "Re-applying
            the FTS5 header guard" section.
            """
        )
    }

    @Test
    func umbrellaHeader_definesSqliteHasCodec() throws {
        guard
            let umbrella = Self.sqlCipherHeaderURL(named: "MuwaSQLCipher.h"),
            let contents = try? String(contentsOf: umbrella, encoding: .utf8)
        else {
            Issue.record(
                """
                MuwaSQLCipher.h umbrella header is missing. Despite
                its short length, this file is LOAD-BEARING — it
                force-defines SQLITE_HAS_CODEC before including
                sqlite3.h, which is the only way to expose
                `sqlite3_key_v2` etc. to Swift's Clang importer. The
                C target's cSettings.define does not propagate.
                Restore from git history.
                """
            )
            return
        }
        #expect(
            contents.contains("SQLITE_HAS_CODEC"),
            """
            MuwaSQLCipher.h exists but no longer defines
            SQLITE_HAS_CODEC. Without it `sqlite3_key_v2` etc. are
            invisible to Swift and EncryptedSQLiteOpener.swift will
            fail to compile.
            """
        )
        #expect(
            contents.contains("MUWA_OMIT_FTS5_HEADERS"),
            """
            MuwaSQLCipher.h must define MUWA_OMIT_FTS5_HEADERS
            before including sqlite3.h. The target cSettings flag
            protects the C compilation, but Swift's Clang module
            import parses this umbrella header separately.
            """
        )
        #expect(
            contents.contains("#include \"sqlite3.h\""),
            "MuwaSQLCipher.h must #include \"sqlite3.h\" so the codec define applies in the same translation unit."
        )
    }

    @Test
    func sqlite3ExtHeader_omitsLoadableExtensionApiFromSwiftImport() throws {
        guard let url = Self.sqlCipherHeaderURL(named: "sqlite3ext.h") else {
            Issue.record(
                "Could not locate Packages/MuwaCore/SQLCipher/include/sqlite3ext.h. If the path moved, update this test."
            )
            return
        }
        let contents = try String(contentsOf: url, encoding: .utf8)

        #expect(
            contents.contains("#ifndef MUWA_OMIT_SQLITE_EXTENSION_API"),
            """
            sqlite3ext.h is missing the MUWA_OMIT_SQLITE_EXTENSION_API open guard.

            Newer macOS SDKs can append fields to sqlite3_api_routines
            before this pinned SQLCipher version adopts the same SQLite
            version. Without this guard, Swift's Clang importer can
            reject MuwaSQLCipher when another dependency imports
            Apple's system SQLite3 module in the same build.
            """
        )
        #expect(
            contents.contains("#endif /* MUWA_OMIT_SQLITE_EXTENSION_API"),
            """
            sqlite3ext.h has the MUWA_OMIT_SQLITE_EXTENSION_API open guard
            but not the matching close. Re-read the README
            "Re-applying the sqlite3ext import guard" section.
            """
        )
    }

    @Test
    func umbrellaHeader_definesOmitExtensionApi() throws {
        guard
            let umbrella = Self.sqlCipherHeaderURL(named: "MuwaSQLCipher.h"),
            let contents = try? String(contentsOf: umbrella, encoding: .utf8)
        else {
            Issue.record("Could not read MuwaSQLCipher.h")
            return
        }
        #expect(
            contents.contains("MUWA_OMIT_SQLITE_EXTENSION_API"),
            """
            MuwaSQLCipher.h must define MUWA_OMIT_SQLITE_EXTENSION_API
            before including sqlite3ext.h. Otherwise the vendored
            sqlite3_api_routines struct can collide with the system
            SQLite3 module on newer macOS SDKs.
            """
        )
    }

    @Test
    func packageManifest_definesOmitFts5HeadersFlag() throws {
        // Walk up from `#filePath` to `Packages/MuwaCore/Package.swift`.
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Storage/
        cursor.deleteLastPathComponent()  // Tests/
        let pkg = cursor.deletingLastPathComponent()  // MuwaCore/
        let manifest = pkg.appendingPathComponent("Package.swift")
        guard let contents = try? String(contentsOf: manifest, encoding: .utf8) else {
            Issue.record("Could not read Package.swift at \(manifest.path)")
            return
        }
        #expect(
            contents.contains("MUWA_OMIT_FTS5_HEADERS"),
            """
            Package.swift no longer defines MUWA_OMIT_FTS5_HEADERS
            in the MuwaSQLCipher target's cSettings. The header
            guard is useless without this flag — Xcode will start
            failing with FTS5 typedef collision errors. Add it back:

                .define("MUWA_OMIT_FTS5_HEADERS"),
            """
        )
    }
}
