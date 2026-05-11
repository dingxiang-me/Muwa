//
//  ModelFamilyNames.swift
//  osaurus
//
//  Small, exact family-name helpers shared by catalog/profile/runtime code.
//

enum ModelFamilyNames {
    static func isLingFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.hasPrefix("ling-") || lower.contains("/ling-")
    }

    /// MiniMax M2/M2.7 bundles are always-reasoning at the template level:
    /// the generation prompt opens `<think>` and the model may complete with
    /// only that rail populated. Treat dash, underscore, dot, and owner/repo
    /// forms as the same family while rejecting unrelated names like
    /// `notminimax` or `minimaxed`.
    static func isMiniMaxFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.range(
            of: #"(^|/|[\-_])minimax($|[\-_/\.])"#,
            options: .regularExpression
        ) != nil
    }

    /// Match Zyphra ZAYA bundles (`model_type=zaya`). Matches the bare
    /// repo form (`Zaya1-…`, `Zaya2-…`, `Zaya-S-…`) and any
    /// `<owner>/Zaya…` path. The required digit-or-dash boundary after
    /// `zaya` rejects unrelated names like `dataset/zayasaurus`,
    /// `lazyaardvark`, or `dazaya-llm` — mirror of `isLingFamily`'s
    /// dash-boundary trick, adjusted for ZAYA's digit-suffix naming.
    static func isZayaFamily(_ modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.range(
            of: #"(^|/)zaya[\-0-9]"#,
            options: .regularExpression
        ) != nil
    }
}
