import Foundation

final class OpenAITTSService: Sendable {
    static let shared = OpenAITTSService()
    private let baseURL = "https://api.openai.com/v1"

    func generateSpeech(
        text: String,
        voiceId: String,
        apiKey: String
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(baseURL)/audio/speech")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": voiceId,
            "response_format": "mp3",
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        return data
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITTSError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = extractErrorDetail(from: data)
            throw OpenAITTSError.apiError(statusCode: httpResponse.statusCode, detail: detail)
        }
    }

    private func extractErrorDetail(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return message
    }
}

enum OpenAITTSError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from OpenAI."
        case .apiError(let code, let detail):
            if !detail.isEmpty { return detail }
            switch code {
            case 401: return "Invalid OpenAI API key (HTTP 401)."
            case 429: return "Rate limited. Please wait and try again."
            default: return "OpenAI error (HTTP \(code))."
            }
        }
    }
}
