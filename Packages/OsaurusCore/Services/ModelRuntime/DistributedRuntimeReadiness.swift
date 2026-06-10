// Copyright © 2026 osaurus.

import Foundation

public enum DistributedTensorAddressClass: String, Codable, Sendable, Equatable, Hashable {
    case thunderboltLoopback
    case thunderboltDirect
    case tailscaleControl
    case localLoopback
    case privateOther
    case linkLocal
    case unknown

    public var isAllowedForTensorDataPlane: Bool {
        switch self {
        case .thunderboltLoopback, .thunderboltDirect:
            return true
        case .tailscaleControl, .localLoopback, .privateOther, .linkLocal, .unknown:
            return false
        }
    }
}

public struct DistributedTensorEndpoint: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String
    public let host: String
    public let port: UInt16?
    public let addressClass: DistributedTensorAddressClass

    public init(_ rawValue: String) {
        let parsed = Self.parse(rawValue)
        self.rawValue = rawValue
        self.host = parsed.host
        self.port = parsed.port
        self.addressClass = Self.classify(host: parsed.host)
    }

    public var isAllowedForTensorDataPlane: Bool {
        addressClass.isAllowedForTensorDataPlane
    }

    private static func parse(_ rawValue: String) -> (host: String, port: UInt16?) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        if let components = URLComponents(string: trimmed),
           components.scheme != nil,
           let host = components.host {
            return (host, components.port.flatMap(UInt16.init))
        }

        if trimmed.hasPrefix("["),
           let closeIndex = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIndex])
            let rest = trimmed[trimmed.index(after: closeIndex)...]
            let port = rest.hasPrefix(":") ? UInt16(rest.dropFirst()) : nil
            return (host, port)
        }

        if trimmed.filter({ $0 == ":" }).count == 1,
           let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<colon])
            let port = UInt16(trimmed[trimmed.index(after: colon)...])
            if port != nil {
                return (host, port)
            }
        }

        return (trimmed, nil)
    }

    private static func classify(host: String) -> DistributedTensorAddressClass {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if lower == "localhost" || lower == "::1" {
            return .localLoopback
        }

        let parts = lower.split(separator: ".")
        guard parts.count == 4,
              let a = Int(parts[0]),
              let b = Int(parts[1]),
              let c = Int(parts[2]),
              let d = Int(parts[3]),
              (0...255).contains(a),
              (0...255).contains(b),
              (0...255).contains(c),
              (0...255).contains(d)
        else {
            return .unknown
        }

        switch (a, b, c) {
        case (10, 20, 0):
            return .thunderboltLoopback
        case (10, 10, _):
            return .thunderboltDirect
        case (100, _, _):
            return .tailscaleControl
        case (127, _, _):
            return .localLoopback
        case (169, 254, _):
            return .linkLocal
        default:
            if a == 10
                || (a == 172 && (16...31).contains(b))
                || (a == 192 && b == 168) {
                return .privateOther
            }
            return .unknown
        }
    }
}

public enum DistributedRuntimeReadinessLevel: String, Codable, Sendable, Equatable, Hashable {
    case info
    case warning
    case error
}

public struct DistributedRuntimeFinding: Codable, Sendable, Equatable, Hashable {
    public let level: DistributedRuntimeReadinessLevel
    public let code: String
    public let message: String

    public init(level: DistributedRuntimeReadinessLevel, code: String, message: String) {
        self.level = level
        self.code = code
        self.message = message
    }
}

public struct DistributedRuntimeReadinessReport: Codable, Sendable, Equatable {
    public let endpoints: [DistributedTensorEndpoint]
    public let worldSize: Int
    public let librdmaLoadable: Bool?
    public let jacclAvailable: Bool?
    public let ibvDevicesConfigured: Bool?
    public let findings: [DistributedRuntimeFinding]

    public var isRunnable: Bool {
        findings.allSatisfy { $0.level != .error }
    }
}

public enum DistributedRuntimeReadiness {
    public static func evaluate(
        dataPlaneAddresses: [String],
        worldSize: Int,
        librdmaLoadable: Bool? = nil,
        jacclAvailable: Bool? = nil,
        ibvDevicesConfigured: Bool? = nil
    ) -> DistributedRuntimeReadinessReport {
        let endpoints = orderedUnique(dataPlaneAddresses).map(DistributedTensorEndpoint.init)
        var findings: [DistributedRuntimeFinding] = []

        if worldSize <= 1 {
            findings.append(.init(
                level: .error,
                code: "single_rank_not_tp",
                message: "Tensor-parallel readiness requires at least two ranks; size-1 fallback is not proof."
            ))
        }

        if endpoints.isEmpty {
            findings.append(.init(
                level: .warning,
                code: "missing_data_plane_addresses",
                message: "No tensor data-plane addresses were supplied."
            ))
        }

        for endpoint in endpoints {
            switch endpoint.addressClass {
            case .thunderboltLoopback, .thunderboltDirect:
                findings.append(.init(
                    level: .info,
                    code: "thunderbolt_data_plane_address",
                    message: "\(endpoint.host) is accepted as a Thunderbolt tensor data-plane address."
                ))
            case .tailscaleControl:
                findings.append(.init(
                    level: .error,
                    code: "tailscale_data_plane_forbidden",
                    message: "\(endpoint.host) is Tailscale/control-plane only and must not carry tensor-parallel data."
                ))
            case .localLoopback:
                findings.append(.init(
                    level: .warning,
                    code: "loopback_not_multirank_proof",
                    message: "\(endpoint.host) is local loopback and cannot prove multi-rank tensor parallelism."
                ))
            case .privateOther, .linkLocal, .unknown:
                findings.append(.init(
                    level: .warning,
                    code: "unproven_data_plane_address",
                    message: "\(endpoint.host) is \(endpoint.addressClass.rawValue), not a proven Thunderbolt tensor data-plane address."
                ))
            }
        }

        if librdmaLoadable == false {
            findings.append(.init(
                level: .error,
                code: "librdma_unavailable",
                message: "librdma is not loadable on this host."
            ))
        }

        if jacclAvailable == false {
            findings.append(.init(
                level: .error,
                code: "jaccl_unavailable",
                message: "JACCL is not available; distributed execution must stay disabled."
            ))
        }

        if ibvDevicesConfigured == false {
            findings.append(.init(
                level: .error,
                code: "ibv_devices_missing",
                message: "MLX_IBV_DEVICES is not configured for the tensor-parallel ranks."
            ))
        }

        return DistributedRuntimeReadinessReport(
            endpoints: endpoints,
            worldSize: worldSize,
            librdmaLoadable: librdmaLoadable,
            jacclAvailable: jacclAvailable,
            ibvDevicesConfigured: ibvDevicesConfigured,
            findings: findings
        )
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}
