//
//  LoadConfiguration+Muwa.swift
//  Muwa
//
//  Compatibility alias while the bundled vmlx-swift package still exposes the
//  production preset under its historical Osaurus name.
//

@preconcurrency import MLXLMCommon

extension LoadConfiguration {
    public static let muwaProduction = LoadConfiguration.osaurusProduction
}
