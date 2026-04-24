//
//  LocalGenerationDefaultsTests.swift
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("LocalGenerationDefaults parse")
struct LocalGenerationDefaultsTests {

    private static func defaults(fromJSON json: String) -> LocalGenerationDefaults.Defaults {
        LocalGenerationDefaults.parse(data: Data(json.utf8))
    }

    @Test("Gemma-4 26B-A4B-it: temperature=1.0, top_k=64, top_p=0.95")
    func gemma4() {
        // Copied verbatim from
        // models--mlx-community--gemma-4-26b-a4b-it-4bit/snapshots/.../generation_config.json
        let d = Self.defaults(fromJSON: #"""
            {
              "bos_token_id": 2,
              "do_sample": true,
              "eos_token_id": [1, 106, 50],
              "pad_token_id": 0,
              "temperature": 1.0,
              "top_k": 64,
              "top_p": 0.95,
              "transformers_version": "5.5.0.dev0"
            }
            """#)
        #expect(d.temperature == 1.0)
        #expect(d.topK == 64)
        #expect(d.topP == 0.95)
        #expect(d.repetitionPenalty == nil)
    }

    @Test("Qwen 3.5 397B-A17B-JANG_2L: temperature=0.6")
    func qwen35() {
        // Qwen 3.5 specifies LOWER temperature than the 0.7 osaurus used to
        // hardcode; this is the headline reason the feature exists.
        let d = Self.defaults(fromJSON: #"""
            {
              "bos_token_id": 248044,
              "do_sample": true,
              "eos_token_id": [248046, 248044],
              "pad_token_id": 248044,
              "temperature": 0.6,
              "top_k": 20,
              "top_p": 0.95,
              "transformers_version": "4.57.0.dev0"
            }
            """#)
        #expect(d.temperature == 0.6)
        #expect(d.topK == 20)
        #expect(d.topP == 0.95)
    }

    @Test("MiniMax M2.7: top_k=40")
    func minimax() {
        let d = Self.defaults(fromJSON: #"""
            {
              "bos_token_id": 200019,
              "do_sample": true,
              "eos_token_id": 200020,
              "temperature": 1.0,
              "top_p": 0.95,
              "top_k": 40,
              "transformers_version": "4.46.1"
            }
            """#)
        #expect(d.temperature == 1.0)
        #expect(d.topK == 40)
        #expect(d.topP == 0.95)
    }

    @Test("Nemotron-Cascade-2: no sampling fields, only EOS")
    func nemotronNoSamplingFields() {
        // Real Nemotron generation_config.json ships nothing but EOS/BOS/pad.
        // We should return `.empty` sampling defaults so the caller's existing
        // fallback ladder (request → runtime → hardcoded 0.7) kicks in.
        let d = Self.defaults(fromJSON: #"""
            {
              "_from_model_config": true,
              "bos_token_id": 1,
              "eos_token_id": [2, 11],
              "pad_token_id": 0,
              "transformers_version": "4.55.4"
            }
            """#)
        #expect(d.temperature == nil)
        #expect(d.topK == nil)
        #expect(d.topP == nil)
        #expect(d.repetitionPenalty == nil)
    }

    @Test("Mistral-Small-4: sampling fields absent — defaults empty")
    func mistralNoSamplingFields() {
        let d = Self.defaults(fromJSON: #"""
            {
              "bos_token_id": 1,
              "eos_token_id": 2,
              "max_length": 1048576,
              "pad_token_id": 11,
              "transformers_version": "5.3.0.dev0"
            }
            """#)
        #expect(d == .empty)
    }

    @Test("repetition_penalty field honored when present")
    func repetitionPenaltyFieldHonored() {
        // Uncommon but permitted — HF spec allows repetition_penalty in
        // generation_config. Make sure we don't drop it on the floor.
        let d = Self.defaults(fromJSON: #"""
            {"temperature": 0.8, "repetition_penalty": 1.05}
            """#)
        #expect(d.temperature == 0.8)
        #expect(d.repetitionPenalty == 1.05)
    }

    @Test("Integer-typed temperature decodes as Float")
    func integerTemperatureDecodes() {
        // Some generators emit `"temperature": 1` (no decimal). Without the
        // NSNumber conversion helper, Swift's `as? Double` rejects these.
        let d = Self.defaults(fromJSON: #"""
            {"temperature": 1, "top_k": 40}
            """#)
        #expect(d.temperature == 1.0)
        #expect(d.topK == 40)
    }

    @Test("Malformed JSON returns empty defaults, does not throw")
    func malformedJsonReturnsEmpty() {
        let d = Self.defaults(fromJSON: #"not json"#)
        #expect(d == .empty)
    }

    @Test("Empty object returns empty defaults")
    func emptyObject() {
        let d = Self.defaults(fromJSON: #"{}"#)
        #expect(d == .empty)
    }
}
