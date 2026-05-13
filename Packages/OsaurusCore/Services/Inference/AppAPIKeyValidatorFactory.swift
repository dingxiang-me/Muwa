import Foundation
import LocalAuthentication

enum AppAPIKeyValidatorFactory {
    /// Returns `.empty` when no master key exists yet (first launch / dev
    /// builds without identity provisioned). Catches identity errors and
    /// returns `.empty` so server startup never fails on auth setup.
    static func build(agentIndex: UInt32?) -> APIKeyValidator {
        guard MasterKey.exists() else { return .empty }

        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300

        do {
            var masterKeyData = try MasterKey.getPrivateKey(context: context)
            defer { masterKeyData.zeroOut() }

            let masterAddress = try deriveOsaurusId(from: masterKeyData)
            let agentAddress: OsaurusID =
                if let idx = agentIndex {
                    try AgentKey.deriveAddress(masterKey: masterKeyData, index: idx)
                } else {
                    masterAddress
                }

            return APIKeyValidator(
                agentAddress: agentAddress,
                masterAddress: masterAddress,
                effectiveWhitelist: WhitelistStore.shared.effectiveWhitelist(
                    forAgent: agentAddress,
                    masterAddress: masterAddress
                ),
                revocationSnapshot: RevocationStore.shared.snapshot(),
                hasKeys: !APIKeyManager.shared.listKeys().isEmpty
            )
        } catch {
            print("[Osaurus] Failed to build validator: \(error). Falling back to empty validator.")
            return .empty
        }
    }
}
