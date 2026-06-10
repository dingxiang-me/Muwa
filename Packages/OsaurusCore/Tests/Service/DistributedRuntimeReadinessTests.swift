// Copyright © 2026 osaurus.

import Testing

@testable import OsaurusCore

@Suite("Distributed runtime readiness")
struct DistributedRuntimeReadinessTests {
    @Test("Thunderbolt loopback and direct addresses are accepted")
    func thunderboltAddressesAreAccepted() {
        let loopback = DistributedTensorEndpoint("10.20.0.1:29500")
        let direct = DistributedTensorEndpoint("10.10.6.2")

        #expect(loopback.addressClass == .thunderboltLoopback)
        #expect(loopback.isAllowedForTensorDataPlane)
        #expect(direct.addressClass == .thunderboltDirect)
        #expect(direct.isAllowedForTensorDataPlane)
    }

    @Test("Tailscale addresses are control-plane only")
    func tailscaleAddressesAreRejected() {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["10.20.0.1:29500", "100.93.216.67:29500"],
            worldSize: 4,
            librdmaLoadable: true,
            jacclAvailable: true,
            ibvDevicesConfigured: true
        )

        #expect(!report.isRunnable)
        #expect(report.endpoints.map(\.addressClass).contains(.tailscaleControl))
        #expect(report.findings.contains { $0.code == "tailscale_data_plane_forbidden" && $0.level == .error })
    }

    @Test("Size one fallback is not tensor-parallel proof")
    func sizeOneFallbackIsRejected() {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["10.20.0.1:29500"],
            worldSize: 1,
            librdmaLoadable: true,
            jacclAvailable: true,
            ibvDevicesConfigured: true
        )

        #expect(!report.isRunnable)
        #expect(report.findings.contains { $0.code == "single_rank_not_tp" })
    }

    @Test("JACCL and IBV gates stay separate from librdma")
    func jacclAndIBVGatesStaySeparate() {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["10.20.0.1:29500", "10.20.0.2:29500"],
            worldSize: 4,
            librdmaLoadable: true,
            jacclAvailable: false,
            ibvDevicesConfigured: false
        )

        #expect(!report.isRunnable)
        #expect(!report.findings.contains { $0.code == "librdma_unavailable" })
        #expect(report.findings.contains { $0.code == "jaccl_unavailable" })
        #expect(report.findings.contains { $0.code == "ibv_devices_missing" })
    }

    @Test("Unknown private addresses are warnings, not proof")
    func unknownPrivateAddressesAreWarnings() {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["192.168.1.20"],
            worldSize: 4,
            librdmaLoadable: true,
            jacclAvailable: true,
            ibvDevicesConfigured: true
        )

        #expect(report.isRunnable)
        #expect(report.endpoints.first?.addressClass == .privateOther)
        #expect(report.findings.contains { $0.code == "unproven_data_plane_address" && $0.level == .warning })
    }
}
