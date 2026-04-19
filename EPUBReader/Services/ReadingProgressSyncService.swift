import Foundation

struct ReadingProgressSyncConfiguration: Equatable, Sendable {
    let endpoint: URL
    let secret: String
}

struct ReadingProgressSyncService: Sendable {
    func fetchReadingState(
        syncIdentifier: String,
        configuration: ReadingProgressSyncConfiguration
    ) async throws -> ReadingStateRecord? {
        var request = URLRequest(url: makeURL(syncIdentifier: syncIdentifier, endpoint: configuration.endpoint))
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.secret)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try validatedStatusCode(response)

        switch statusCode {
        case 200:
            return try JSONDecoder().decode(ReadingStateRecord.self, from: data)
        case 404:
            return nil
        default:
            throw ReadingProgressSyncError.apiError(statusCode: statusCode, detail: responseDetail(from: data))
        }
    }

    func pushReadingState(
        _ state: ReadingStateRecord,
        syncIdentifier: String,
        configuration: ReadingProgressSyncConfiguration
    ) async throws {
        var request = URLRequest(url: makeURL(syncIdentifier: syncIdentifier, endpoint: configuration.endpoint))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(configuration.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(state)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try validatedStatusCode(response)

        guard (200...299).contains(statusCode) else {
            throw ReadingProgressSyncError.apiError(statusCode: statusCode, detail: responseDetail(from: data))
        }
    }

    private func makeURL(syncIdentifier: String, endpoint: URL) -> URL {
        endpoint
            .appendingPathComponent("v1")
            .appendingPathComponent("reading-state")
            .appendingPathComponent(syncIdentifier)
    }

    private func validatedStatusCode(_ response: URLResponse) throws -> Int {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReadingProgressSyncError.invalidResponse
        }
        return httpResponse.statusCode
    }

    private func responseDetail(from data: Data) -> String {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
    }
}

enum ReadingProgressSyncError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid sync response."
        case .apiError(let statusCode, let detail):
            return "Sync request failed (\(statusCode)): \(detail)"
        }
    }
}
