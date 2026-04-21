import Foundation

// HTTP client for OpenAI API endpoints with adaptive rate limit handling.
// Reads x-ratelimit-remaining-requests and x-ratelimit-reset-requests headers
// to dynamically adjust concurrency and pacing without hitting 429 errors.
actor OpenAIClient {
    private let session: URLSession
    private let baseURL = "https://api.openai.com/v1"
    private var apiKey: String

    // Fixed model names per CTO decision (009).
    static let embeddingModel = "text-embedding-3-small"
    static let embeddingDimensions = 1536
    static let completionModel = "gpt-4o-mini"
    static let tokenLimit = 8000

    // Rate limit state tracked from response headers.
    private var remainingRequests: Int = 60
    private var resetInterval: TimeInterval = 60.0
    private var lastRequestTime: Date = .distantPast

    // Computed optimal concurrency based on current rate limit headroom.
    var recommendedConcurrency: Int {
        // Reserve 20% of remaining quota as safety margin.
        let usable = max(1, Int(Double(remainingRequests) * 0.8))
        // Cap at 20 to avoid overwhelming the connection pool.
        return min(usable, 20)
    }

    // Computed per-request delay to spread requests across the reset window.
    var recommendedDelay: TimeInterval {
        guard remainingRequests > 0 else { return resetInterval }
        // Spread remaining requests evenly across the reset window.
        return max(0, resetInterval / Double(remainingRequests))
    }

    init(apiKey: String) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: configuration)
    }

    func updateAPIKey(_ newKey: String) {
        apiKey = newKey
    }

    // Validate the current API key with a lightweight embedding request.
    // Returns nil on success, or a human-readable error message on failure.
    func validateKey() async -> String? {
        guard !apiKey.isEmpty else { return "APIキーが設定されていません" }
        do {
            _ = try await fetchEmbedding(for: "test")
            return nil
        } catch OpenAIError.apiError(let code, let message) where code == 401 {
            return "APIキーが無効です (401 Unauthorized)"
        } catch OpenAIError.apiError(let code, _) where code == 403 {
            return "APIキーに権限がありません (403 Forbidden)"
        } catch OpenAIError.rateLimited {
            // Rate limit means the key is valid but throttled — treat as valid.
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Embedding

    // Request an embedding vector for the given text.
    // Truncates input to 8K chars (as token proxy) using rear truncation.
    func fetchEmbedding(for text: String) async throws -> [Float] {
        let truncatedText = truncateText(text, limit: Self.tokenLimit)

        let requestBody: [String: Any] = [
            "model": Self.embeddingModel,
            "input": truncatedText
        ]

        let data = try await postJSON(endpoint: "/embeddings", body: requestBody)
        let response = try JSONDecoder().decode(EmbeddingResponse.self, from: data)

        guard let firstEmbedding = response.data.first else {
            throw OpenAIError.emptyResponse
        }
        return firstEmbedding.embedding
    }

    // MARK: - Chat Completion

    // Request a chat completion from gpt-4o-mini for topic generation.
    func fetchCompletion(systemPrompt: String, userPrompt: String) async throws -> String {
        let requestBody: [String: Any] = [
            "model": Self.completionModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.7,
            "max_tokens": 500
        ]

        let data = try await postJSON(endpoint: "/chat/completions", body: requestBody)
        let response = try JSONDecoder().decode(CompletionResponse.self, from: data)

        guard let firstChoice = response.choices.first else {
            throw OpenAIError.emptyResponse
        }
        return firstChoice.message.content
    }

    // MARK: - Private Helpers

    // Truncate text to the given character limit (rear truncation).
    private func truncateText(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit))
    }

    // Send a POST request and update rate limit state from response headers.
    private func postJSON(endpoint: String, body: [String: Any]) async throws -> Data {
        let url = URL(string: baseURL + endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        // Update rate limit state from response headers on every request.
        updateRateLimitState(from: httpResponse)

        // Handle rate limiting: wait for the reset interval and retry once.
        if httpResponse.statusCode == 429 {
            let waitTime = parseRetryAfter(from: httpResponse)
            try await Task.sleep(for: .seconds(waitTime))
            throw OpenAIError.rateLimited
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OpenAIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        lastRequestTime = Date()
        return data
    }

    // Parse rate limit headers from the OpenAI response.
    //   x-ratelimit-remaining-requests: number of requests left in the current window
    //   x-ratelimit-reset-requests: time until the quota resets (e.g. "2s", "1m30s", "200ms")
    private func updateRateLimitState(from response: HTTPURLResponse) {
        if let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining-requests"),
           let value = Int(remaining) {
            remainingRequests = value
        }

        if let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset-requests") {
            resetInterval = parseDuration(reset)
        }
    }

    // Parse the Retry-After header or fall back to the reset interval.
    private func parseRetryAfter(from response: HTTPURLResponse) -> Double {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(retryAfter) {
            return seconds
        }
        if let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset-requests") {
            return parseDuration(reset)
        }
        return resetInterval
    }

    // Parse OpenAI's duration format: "200ms", "2s", "1m30s", "6m0s", etc.
    private func parseDuration(_ raw: String) -> TimeInterval {
        var total: TimeInterval = 0
        var numberBuffer = ""

        for ch in raw {
            if ch.isNumber || ch == "." {
                numberBuffer.append(ch)
            } else {
                guard let value = Double(numberBuffer) else { numberBuffer = ""; continue }
                switch ch {
                case "h": total += value * 3600
                case "m" where !raw.contains("ms"): total += value * 60
                case "s": total += value
                default: break
                }
                numberBuffer = ""
            }
        }

        // Handle bare "ms" suffix: e.g. "200ms".
        if raw.hasSuffix("ms"), let msValue = Double(raw.dropLast(2)) {
            return msValue / 1000.0
        }

        return max(total, 0.1)
    }
}

// MARK: - Error Types

enum OpenAIError: Error, LocalizedError {
    case emptyResponse
    case invalidResponse
    case rateLimited
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "API returned an empty response"
        case .invalidResponse: return "Invalid HTTP response"
        case .rateLimited: return "Rate limited (429). Waiting for reset..."
        case .apiError(let code, let message): return "API error (\(code)): \(message)"
        }
    }
}

// MARK: - Response Models

private struct EmbeddingResponse: Codable {
    let data: [EmbeddingData]
    struct EmbeddingData: Codable {
        let embedding: [Float]
    }
}

private struct CompletionResponse: Codable {
    let choices: [Choice]
    struct Choice: Codable {
        let message: Message
    }
    struct Message: Codable {
        let content: String
    }
}
