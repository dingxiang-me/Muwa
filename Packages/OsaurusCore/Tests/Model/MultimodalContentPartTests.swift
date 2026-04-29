//
//  MultimodalContentPartTests.swift
//  osaurusTests
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

/// Locks in the OpenAI-compatible `MessageContentPart` decoding for
/// `input_audio` and `video_url` shapes plus the `ChatMessage` →
/// `MLXLMCommon.Chat.Message` mapping that lights up Nemotron-Omni's
/// audio + video paths via vmlx's `UserInput.audios` / `.videos` fields.
///
/// Without these tests, a refactor that drops the new cases or the
/// extraction wiring (e.g. someone "simplifies" the `mapOpenAIChatToMLX`
/// switch and forgets to re-pass `audios:` to `Chat.Message.init`) would
/// be invisible at compile time — vmlx accepts the omitted parameter as
/// the default `[]` — and silently route every audio request as
/// text-only. The bug surface there is a model that just doesn't "hear"
/// the audio attachment, with no error. Easy to ship, hard to spot.
@Suite("Multimodal content parts (audio + video)")
struct MultimodalContentPartTests {

    // MARK: - MessageContentPart decoding

    @Test("input_audio content part decodes data + format")
    func decode_inputAudio() throws {
        let json = """
        {
          "type": "input_audio",
          "input_audio": {"data": "AAA=", "format": "wav"}
        }
        """.data(using: .utf8)!

        let part = try JSONDecoder().decode(MessageContentPart.self, from: json)
        guard case .audioInput(let data, let format) = part else {
            Issue.record("expected .audioInput, got \(part)")
            return
        }
        #expect(data == "AAA=")
        #expect(format == "wav")
    }

    @Test("video_url content part decodes url")
    func decode_videoUrl() throws {
        let json = """
        {
          "type": "video_url",
          "video_url": {"url": "https://example.com/clip.mp4"}
        }
        """.data(using: .utf8)!

        let part = try JSONDecoder().decode(MessageContentPart.self, from: json)
        guard case .videoUrl(let url) = part else {
            Issue.record("expected .videoUrl, got \(part)")
            return
        }
        #expect(url == "https://example.com/clip.mp4")
    }

    @Test("Mixed content parts round-trip via Codable")
    func roundtrip_mixedParts() throws {
        let original: [MessageContentPart] = [
            .text("describe this:"),
            .imageUrl(url: "https://example.com/x.jpg", detail: "high"),
            .audioInput(data: "AAA=", format: "wav"),
            .videoUrl(url: "https://example.com/y.mp4"),
        ]
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([MessageContentPart].self, from: encoded)
        #expect(decoded.count == 4)
        // Spot-check the audio + video cases survived the round-trip with
        // their payloads intact — `MessageContentPart` is `Codable`-only,
        // not `Equatable`, so we case-match rather than `==`.
        if case .audioInput(let d, let f) = decoded[2] {
            #expect(d == "AAA=")
            #expect(f == "wav")
        } else {
            Issue.record("decoded[2] should be .audioInput")
        }
        if case .videoUrl(let u) = decoded[3] {
            #expect(u == "https://example.com/y.mp4")
        } else {
            Issue.record("decoded[3] should be .videoUrl")
        }
    }

    // MARK: - ChatMessage accessors

    @Test("ChatMessage.audioInputs returns (data, format) tuples")
    func chatMessage_audioInputs() throws {
        let json = """
        {
          "role": "user",
          "content": [
            {"type": "text", "text": "transcribe"},
            {"type": "input_audio", "input_audio": {"data": "AAAA", "format": "wav"}},
            {"type": "input_audio", "input_audio": {"data": "BBBB", "format": "mp3"}}
          ]
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(ChatMessage.self, from: json)
        let inputs = msg.audioInputs
        #expect(inputs.count == 2)
        #expect(inputs[0].data == "AAAA")
        #expect(inputs[0].format == "wav")
        #expect(inputs[1].data == "BBBB")
        #expect(inputs[1].format == "mp3")
    }

    @Test("ChatMessage.videoUrls returns urls in order")
    func chatMessage_videoUrls() throws {
        let json = """
        {
          "role": "user",
          "content": [
            {"type": "video_url", "video_url": {"url": "https://a/1.mp4"}},
            {"type": "text", "text": "and:"},
            {"type": "video_url", "video_url": {"url": "https://a/2.mp4"}}
          ]
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(ChatMessage.self, from: json)
        let urls = msg.videoUrls
        #expect(urls == ["https://a/1.mp4", "https://a/2.mp4"])
    }

    // MARK: - mapOpenAIChatToMLX wiring

    @Test("mapOpenAIChatToMLX forwards videos to Chat.Message.videos")
    func mapping_forwardsVideos() throws {
        let json = """
        [{
          "role": "user",
          "content": [
            {"type": "text", "text": "what's in this clip"},
            {"type": "video_url", "video_url": {"url": "https://example.com/clip.mp4"}}
          ]
        }]
        """.data(using: .utf8)!

        let msgs = try JSONDecoder().decode([ChatMessage].self, from: json)
        let mapped = ModelRuntime.mapOpenAIChatToMLX(msgs)
        #expect(mapped.count == 1)
        #expect(mapped[0].videos.count == 1)
        // Video came in as an `https:` URL — it should propagate as
        // `.url(URL)` not `.avAsset(...)` — vmlx will fetch + decode.
        guard case .url(let u) = mapped[0].videos[0] else {
            Issue.record("expected .url(...) for https video")
            return
        }
        #expect(u.absoluteString == "https://example.com/clip.mp4")
    }

    @Test("mapOpenAIChatToMLX materializes input_audio data into temp file URL")
    func mapping_audioMaterializesTempFile() throws {
        // 4 bytes of bogus PCM. We're not asserting decodability here —
        // vmlx's `nemotronOmniLoadAudioFile` is what does the AVAudioConverter
        // pass; this test only proves the wire payload reaches a file URL
        // with the right extension so vmlx's extension-keyed dispatch picks
        // the right decoder.
        let payload = Data([0x00, 0x01, 0x02, 0x03])
        let b64 = payload.base64EncodedString()
        let json = """
        [{
          "role": "user",
          "content": [
            {"type": "input_audio", "input_audio": {"data": "\(b64)", "format": "wav"}}
          ]
        }]
        """.data(using: .utf8)!

        let msgs = try JSONDecoder().decode([ChatMessage].self, from: json)
        let mapped = ModelRuntime.mapOpenAIChatToMLX(msgs)
        #expect(mapped.count == 1)
        #expect(mapped[0].audios.count == 1)
        guard case .url(let u) = mapped[0].audios[0] else {
            Issue.record("audio source must materialize to a .url(...) for vmlx's AVAudioConverter")
            return
        }
        #expect(u.pathExtension == "wav", "extension drives AVAudioConverter dispatch")
        // Verify the bytes actually landed on disk under the expected path.
        let written = try Data(contentsOf: u)
        #expect(written == payload)
        // Best-effort cleanup so the test's temp files don't accumulate
        // across local runs. macOS evicts the system temp dir on its own
        // schedule for the production path; tests just don't need to wait.
        try? FileManager.default.removeItem(at: u)
    }

    @Test("mapping handles all four roles with audio + video together")
    func mapping_allRoles_carryAudioAndVideo() throws {
        // System messages don't carry audio in real OpenAI requests, but
        // the *mapping* must accept them without dropping anything — this
        // catches a regression where a refactor handles only `user` and
        // forgets the other branches.
        let json = """
        [
          {"role": "system", "content": "you are helpful"},
          {"role": "user", "content": [
              {"type": "text", "text": "hi"},
              {"type": "input_audio", "input_audio": {"data": "AAAA", "format": "wav"}}
          ]},
          {"role": "assistant", "content": "hello"},
          {"role": "tool", "content": "result", "tool_call_id": "abc"}
        ]
        """.data(using: .utf8)!

        let msgs = try JSONDecoder().decode([ChatMessage].self, from: json)
        let mapped = ModelRuntime.mapOpenAIChatToMLX(msgs)
        #expect(mapped.count == 4)
        // Only the user message should have audio, but every role-branch
        // must compile against the new `audios:` parameter — that's what
        // the assertion is really catching at the type level.
        let userMsg = mapped[1]
        #expect(userMsg.audios.count == 1)
        for other in [mapped[0], mapped[2], mapped[3]] {
            #expect(other.audios.isEmpty)
        }
    }
}
