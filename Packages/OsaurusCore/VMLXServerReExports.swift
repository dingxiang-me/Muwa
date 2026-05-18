//
//  VMLXServerReExports.swift
//  OsaurusCore
//
//  G.3 shim: makes every public symbol from VMLXServer visible to all
//  files in OsaurusCore without per-file `import VMLXServer`. Replaces
//  the in-target Extracted/ engine sources that have moved to
//  vmlx-swift-lm. Decision on whether to keep this shim long-term, or
//  switch to ~50 per-file imports, is part of G.4.
//

@_exported import VMLXServer
