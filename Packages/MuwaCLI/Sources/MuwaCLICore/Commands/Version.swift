//
//  Version.swift
//  Muwa
//
//  Command to display the Muwa version and build number from environment variables.
//

import Foundation

public struct VersionCommand: Command {
    public static let name = "version"

    public static func execute(args: [String]) async {
        var versionString: String?
        var buildString: String?

        let env = ProcessInfo.processInfo.environment
        if let v = env["MUWA_VERSION"] ?? env["MUWA_VERSION"] { versionString = v }
        if let b = env["MUWA_BUILD_NUMBER"] ?? env["MUWA_BUILD_NUMBER"] { buildString = b }

        let output: String
        if let v = versionString, let b = buildString, !b.isEmpty {
            output = "Muwa \(v) (\(b))"
        } else if let v = versionString {
            output = "Muwa \(v)"
        } else {
            output = "Muwa dev"
        }
        print(output)
        exit(EXIT_SUCCESS)
    }
}
