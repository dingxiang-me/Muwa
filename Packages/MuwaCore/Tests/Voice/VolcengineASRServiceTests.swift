import Foundation
import Testing

@testable import MuwaCore

@Suite("Volcengine ASR service")
struct VolcengineASRServiceTests {
    @Test func legacySpeechConfigurationDefaultsToLocalProvider() throws {
        let data = Data(
            """
            {
              "modelVersion": "v3",
              "voiceInputEnabled": true
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(SpeechConfiguration.self, from: data)

        #expect(decoded.transcriptionProvider == .local)
        #expect(decoded.volcengineResourceId == VolcengineASRSettings.defaultResourceId)
        #expect(decoded.volcengineLanguage.isEmpty)
    }

    @Test func settingsBuildsNewConsoleHeaders() {
        let settings = VolcengineASRSettings(
            apiKey: "test-api-key",
            resourceId: "volc.seedasr.sauc.duration"
        )

        let headers = settings.requestHeaders(requestId: "67ee89ba-7050-4c04-a3d7-ac61a63499b3")

        #expect(headers["X-Api-Key"] == "test-api-key")
        #expect(headers["X-Api-Resource-Id"] == "volc.seedasr.sauc.duration")
        #expect(headers["X-Api-Request-Id"] == "67ee89ba-7050-4c04-a3d7-ac61a63499b3")
        #expect(headers["X-Api-Sequence"] == "-1")
        #expect(headers["X-Api-App-Key"] == nil)
        #expect(headers["X-Api-Access-Key"] == nil)
    }

    @Test func buildsSupportedResourceIds() {
        #expect(VolcengineASRSettings.defaultResourceId == "volc.bigasr.sauc.duration")
        #expect(
            VolcengineASRSettings.resourceId(modelService: .bigASR, resourceType: .duration)
                == "volc.bigasr.sauc.duration"
        )
        #expect(
            VolcengineASRSettings.resourceId(modelService: .bigASR, resourceType: .concurrent)
                == "volc.bigasr.sauc.concurrent"
        )
        #expect(
            VolcengineASRSettings.resourceId(modelService: .seedASR, resourceType: .duration)
                == "volc.seedasr.sauc.duration"
        )
        #expect(
            VolcengineASRSettings.resourceId(modelService: .seedASR, resourceType: .concurrent)
                == "volc.seedasr.sauc.concurrent"
        )
    }

    @Test func normalizesResourceIdToSupportedPreset() {
        #expect(VolcengineASRSettings.normalizedResourceId("") == VolcengineASRSettings.defaultResourceId)
        #expect(
            VolcengineASRSettings.normalizedResourceId("volc.bigasr.sauc.duration")
                == "volc.bigasr.sauc.duration"
        )
        #expect(
            VolcengineASRSettings.normalizedResourceId("volc.seedasr.sauc.concurrent")
                == "volc.seedasr.sauc.concurrent"
        )
        #expect(
            VolcengineASRSettings.normalizedResourceId("volc.seedasr.other.concurrent")
                == VolcengineASRSettings.defaultResourceId
        )
        #expect(VolcengineASRSettings.normalizedResourceId("bad-resource") == VolcengineASRSettings.defaultResourceId)
    }

    @Test func clientPacketsDoNotInsertSequenceBytes() {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let fullRequest = VolcASRFrame.packet(
            type: VolcASRFrame.fullClientRequest,
            flags: VolcASRFrame.flagNoSequence,
            serialization: VolcASRFrame.serializationJSON,
            sequence: nil,
            payload: payload
        )
        let audioRequest = VolcASRFrame.packet(
            type: VolcASRFrame.audioOnlyRequest,
            flags: VolcASRFrame.flagNoSequence,
            serialization: VolcASRFrame.serializationNone,
            sequence: nil,
            payload: payload
        )
        let finalRequest = VolcASRFrame.packet(
            type: VolcASRFrame.audioOnlyRequest,
            flags: VolcASRFrame.flagLastPackage,
            serialization: VolcASRFrame.serializationNone,
            sequence: nil,
            payload: payload
        )

        #expect(fullRequest.count == 4 + 4 + payload.count)
        #expect(fullRequest[0] == 0x11)
        #expect(fullRequest[1] == 0x10)
        #expect(fullRequest[2] == 0x11)
        #expect(Array(fullRequest[4..<8]) == [0x00, 0x00, 0x00, 0x03])
        #expect(Data(fullRequest.suffix(payload.count)) == payload)

        #expect(audioRequest.count == 4 + 4 + payload.count)
        #expect(audioRequest[1] == 0x20)
        #expect(Array(audioRequest[4..<8]) == [0x00, 0x00, 0x00, 0x03])

        #expect(finalRequest.count == 4 + 4 + payload.count)
        #expect(finalRequest[1] == 0x22)
        #expect(Array(finalRequest[4..<8]) == [0x00, 0x00, 0x00, 0x03])
    }

    @Test func gzipRoundTripsPayloadAndEmptyFinalPacket() throws {
        let payload = Data(#"{"request":{"model_name":"bigmodel"}}"#.utf8)
        let compressed = VolcGzip.compress(payload)

        #expect(compressed.count > payload.count)
        #expect(compressed.first == 0x1F)
        #expect(compressed.dropFirst().first == 0x8B)
        #expect(try VolcGzip.decompress(compressed) == payload)

        let empty = VolcGzip.compress(Data())
        #expect(!empty.isEmpty)
        #expect(try VolcGzip.decompress(empty).isEmpty)
    }

    @Test func pcm16ConversionClampsAndScalesSamples() {
        let data = VolcengineASRSession.pcm16Data(from: [-2.0, -1.0, 0.0, 0.5, 2.0])
        let values = data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self))
        }

        #expect(values == [-32767, -32767, 0, 16383, 32767])
    }
}
