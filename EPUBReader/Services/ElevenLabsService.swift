import Foundation

final class ElevenLabsService: Sendable {
    static let shared = ElevenLabsService()
    private let baseURL = "https://api.elevenlabs.io/v1"

    struct TTSResponse: Codable {
        let audio_base64: String
        let alignment: TTSAlignment?
        let normalized_alignment: TTSAlignment?
    }

    struct TTSAlignment: Codable {
        let characters: [String]
        let character_start_times_seconds: [Double]
        let character_end_times_seconds: [Double]
    }

    struct Voice: Codable, Identifiable, Hashable {
        let voice_id: String
        let name: String
        let category: String?
        let labels: [String: String]?
        let preview_url: String?

        var id: String { voice_id }

        var subtitle: String {
            guard let labels else { return "" }
            let parts = [labels["gender"], labels["age"], labels["accent"]].compactMap { $0 }
            return parts.joined(separator: " · ")
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(voice_id)
        }

        static func == (lhs: Voice, rhs: Voice) -> Bool {
            lhs.voice_id == rhs.voice_id
        }
    }

    struct VoicesResponse: Codable {
        let voices: [Voice]
    }

    func fetchVoices(apiKey: String) async throws -> [Voice] {
        var request = URLRequest(url: URL(string: "\(baseURL)/voices")!)
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let voicesResponse = try JSONDecoder().decode(VoicesResponse.self, from: data)
        return voicesResponse.voices.sorted { $0.name < $1.name }
    }

    func generateSpeech(text: String, voiceId: String, apiKey: String) async throws -> TTSResponse {
        let url = URL(string: "\(baseURL)/text-to-speech/\(voiceId)/with-timestamps")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "output_format": "mp3_44100_128",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": true
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        return try JSONDecoder().decode(TTSResponse.self, from: data)
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200...299: return
        case 401: throw ElevenLabsError.unauthorized
        case 429: throw ElevenLabsError.rateLimited
        default: throw ElevenLabsError.serverError(httpResponse.statusCode)
        }
    }
}

enum ElevenLabsError: LocalizedError {
    case invalidResponse
    case unauthorized
    case rateLimited
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from ElevenLabs."
        case .unauthorized: return "Invalid API key. Check your ElevenLabs API key in Settings."
        case .rateLimited: return "Rate limited. Please wait a moment and try again."
        case .serverError(let code): return "ElevenLabs error (HTTP \(code))."
        }
    }
}
