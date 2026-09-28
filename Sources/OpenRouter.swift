import Foundation

/// The credit totals OpenRouter reports. `remaining` is computed rather than
/// stored so the two fields can never disagree with the difference.
struct Credits: Equatable {
    let totalCredits: Double
    let totalUsage: Double
    var remaining: Double { totalCredits - totalUsage }
}

enum OpenRouterError: Error {
    case badStatus(Int)
    case notJSON
    case missingField(String)
}

/// Talks to OpenRouter and caches the model catalog for 24 hours. The network
/// calls are thin: build the request, inspect the status code, hand the body to
/// the pure parser. `loadCachedCatalog` takes its path so the cache rule is
/// testable without touching the real user cache.
enum OpenRouter {
    static let catalogPath: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("ProviderCostController/models-cache.json").path
    }()

    /// A missing field must never be read as zero: a missing `total_usage`
    /// treated as 0 would show the whole balance as remaining.
    static func parseCredits(_ data: Data) throws -> Credits {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let payload = root["data"] as? [String: Any] else {
            throw OpenRouterError.notJSON
        }
        guard let totalCredits = payload["total_credits"] as? Double else {
            throw OpenRouterError.missingField("data.total_credits")
        }
        guard let totalUsage = payload["total_usage"] as? Double else {
            throw OpenRouterError.missingField("data.total_usage")
        }
        return Credits(totalCredits: totalCredits, totalUsage: totalUsage)
    }

    /// Every entry must carry both `id` and `name`; a partial entry is a schema
    /// change, not a nameless model.
    static func parseCatalog(_ data: Data) throws -> [(id: String, name: String)] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw OpenRouterError.notJSON
        }
        return try entries.map { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else {
                throw OpenRouterError.missingField("data[].id/name")
            }
            return (id: id, name: name)
        }
    }

    static func credits(apiKey: String) async throws -> Credits {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/credits")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
        return try parseCredits(body)
    }

    /// Serves the cache when it is younger than 24 hours. A corrupt cache is
    /// replaced by refetching rather than surfacing here: that is this
    /// function's business, not `loadCachedCatalog`'s.
    static func models() async throws -> [(id: String, name: String)] {
        if let cached = try? loadCachedCatalog() { return cached }

        let request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        let (body, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
        let parsed = try parseCatalog(body)
        // Best-effort: the contract is to return models, caching is opportunistic.
        // A failed write degrades to refetching next time rather than failing a
        // caller that already holds a good list.
        try? writeCatalog(parsed)
        return parsed
    }

    /// Returns `nil` when the cache file is absent or older than 24 hours, and
    /// throws when it is present but unreadable or malformed. A corrupt cache
    /// must not read as an empty catalog.
    static func loadCachedCatalog(from path: String = OpenRouter.catalogPath) throws
        -> [(id: String, name: String)]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let fetchedAtString = root["fetchedAt"] as? String,
              let fetchedAt = ISO8601DateFormatter().date(from: fetchedAtString),
              let entries = root["models"] as? [[String: Any]] else {
            throw OpenRouterError.notJSON
        }
        guard Date().timeIntervalSince(fetchedAt) < 24 * 60 * 60 else { return nil }
        return try entries.map { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else {
                throw OpenRouterError.missingField("models[].id/name")
            }
            return (id: id, name: name)
        }
    }

    private static func writeCatalog(_ models: [(id: String, name: String)]) throws {
        let payload: [String: Any] = [
            "fetchedAt": ISO8601DateFormatter().string(from: Date()),
            "models": models.map { ["id": $0.id, "name": $0.name] },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let directory = (catalogPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: catalogPath), options: .atomic)
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.badStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.badStatus(http.statusCode)
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
