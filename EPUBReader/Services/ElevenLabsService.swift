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
        try validateResponse(response, data: data)

        let voicesResponse = try JSONDecoder().decode(VoicesResponse.self, from: data)
        return voicesResponse.voices.sorted { $0.name < $1.name }
    }

    func generateSpeech(text: String, voiceId: String, apiKey: String) async throws -> TTSResponse {
        var components = URLComponents(string: "\(baseURL)/text-to-speech/\(voiceId)/with-timestamps")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": true
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        return try JSONDecoder().decode(TTSResponse.self, from: data)
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = extractErrorDetail(from: data)
            throw ElevenLabsError.apiError(statusCode: httpResponse.statusCode, detail: detail)
        }
    }

    private func extractErrorDetail(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        if let detail = json["detail"] as? [String: Any], let message = detail["message"] as? String {
            return message
        }
        if let detail = json["detail"] as? String {
            return detail
        }
        if let message = json["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum ElevenLabsError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from ElevenLabs."
        case .apiError(let code, let detail):
            if !detail.isEmpty { return detail }
            switch code {
            case 401: return "Authentication failed (HTTP 401)."
            case 429: return "Rate limited. Please wait and try again."
            default: return "ElevenLabs error (HTTP \(code))."
            }
        }
    }
}
