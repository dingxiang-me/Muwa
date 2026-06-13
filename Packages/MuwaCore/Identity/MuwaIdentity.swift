//
//  MuwaIdentity.swift
//  Muwa
//
//  Public entry point for the Muwa Identity system.
//  Orchestrates Master Key, Device Key, counter, and recovery code
//  to produce two-layer signed tokens for every API request.
//

import CryptoKit
import Foundation
import LocalAuthentication

public struct MuwaIdentity: Sendable {

    // MARK: - Setup

    /// Full identity setup: generates Master Key, attests device, generates
    /// recovery code, and persists the 24-word BIP39 backup into iCloud
    /// Keychain (alongside the seed). The mnemonic is no longer surfaced to
    /// the caller — it lives in `MasterMnemonicStore` and is fetched on
    /// demand (e.g. from Settings → "View recovery phrase").
    ///
    /// If an identity already exists, this short-circuits and returns the
    /// existing identity.
    public static func setup() async throws -> IdentityInfo {
        if MasterKey.exists() {
            return try await loadExistingIdentity()
        }

        let result = try MasterKey.generate(allowReplace: false)
        var seed = result.seed
        defer { seed.zeroOut() }
        let mnemonic = try MasterKeyMnemonic.mnemonic(forKey: seed)
        try MasterMnemonicStore.store(mnemonic)

        let deviceId = try await DeviceKey.attest()
        let recovery = RecoveryManager.configure(address: result.muwaId)

        return IdentityInfo(
            muwaId: result.muwaId,
            deviceId: deviceId,
            recovery: recovery
        )
    }

    /// Build an `IdentityInfo` from the already-installed master key. Triggers a
    /// biometric prompt to read the master and re-attest the device.
    private static func loadExistingIdentity() async throws -> IdentityInfo {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300
        let muwaId = try MasterKey.getMuwaId(context: context)
        let deviceId = try DeviceKey.currentDeviceId()
        return IdentityInfo(
            muwaId: muwaId,
            deviceId: deviceId,
            recovery: RecoveryInfo(code: "")
        )
    }

    /// Whether an identity already exists (no biometric prompt).
    public static func exists() -> Bool {
        MasterKey.exists()
    }

    // MARK: - Wipe

    /// Full identity wipe used by the "Reset Identity" flow. Deletes the master
    /// key, clears every non-built-in agent's derived address, and removes every
    /// stored osk-v1 access key. The revocation store is intentionally kept.
    @MainActor
    public static func wipe() {
        MasterKey.delete()
        MasterMnemonicStore.delete()
        APIKeyManager.shared.deleteAll()

        for agent in AgentManager.shared.agents where !agent.isBuiltIn {
            guard agent.agentIndex != nil || agent.agentAddress != nil else { continue }
            var cleared = agent
            cleared.agentIndex = nil
            cleared.agentAddress = nil
            AgentManager.shared.update(cleared)
        }

        UserDefaults.standard.set(false, forKey: IdentityDefaultsKey.masterMnemonicAcknowledged)
    }

    // MARK: - Request Signing

    /// Sign an API request as the user identity.
    /// Returns a URLRequest with `Authorization: Bearer <token>`.
    public static func signRequest(
        method: String,
        path: String,
        audience: String
    ) async throws -> URLRequest {
        let context = MuwaIdentityContext.biometric()
        let muwaId = try MasterKey.getMuwaId(context: context)

        return try await buildSignedRequest(
            muwaId: muwaId,
            method: method,
            path: path,
            audience: audience,
            context: context
        )
    }

    // MARK: - Private

    private static func buildSignedRequest(
        muwaId: MuwaID,
        method: String,
        path: String,
        audience: String,
        context: LAContext
    ) async throws -> URLRequest {
        let deviceId = try DeviceKey.currentDeviceId()
        let counter = CounterStore.shared.next()
        let now = Int(Date().timeIntervalSince1970)

        let payload = TokenPayload(
            iss: muwaId,
            dev: deviceId,
            cnt: counter,
            iat: now,
            exp: now + 60,
            aud: audience,
            act: "\(method) \(path)",
            par: nil,
            idx: nil
        )

        let payloadData = try JSONEncoder().encode(payload)

        // Layer 1: Identity signature (secp256k1)
        let identitySig = try MasterKey.sign(payload: payloadData, context: context)

        // Layer 2: Device assertion (App Attest)
        let payloadHash = Data(SHA256.hash(data: payloadData))
        let deviceAssertion = try await DeviceKey.assert(payloadHash: payloadHash)

        // Assemble 4-part token
        let headerData = try JSONEncoder().encode(TokenHeader.current)
        let token = [
            headerData.base64urlEncoded,
            payloadData.base64urlEncoded,
            identitySig.hexEncodedString,
            deviceAssertion.base64urlEncoded,
        ].joined(separator: ".")

        let urlString = "https://\(audience)\(path)"
        guard let url = URL(string: urlString) else {
            throw MuwaIdentityError.invalidEndpointURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
