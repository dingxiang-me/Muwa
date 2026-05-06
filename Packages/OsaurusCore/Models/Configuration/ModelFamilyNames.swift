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
}
