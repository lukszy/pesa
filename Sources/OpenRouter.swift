import Foundation

/// The credit totals OpenRouter reports. `remaining` is computed rather than
/// stored so the two fields can never disagree with the difference.
struct Credits: Equatable {
    let totalCredits: Double
    let totalUsage: Double
    var remaining: Double { totalCredits - totalUsage }
}

/// The per-key usage OpenRouter reports from `/api/v1/key`. This is *per key*
/// whereas `Credits` is account-wide: with more than one key the two do not
/// add up, so the UI must never present them as a single figure.
struct KeyUsage: Equatable {
    let usageDaily: Double
    let usageWeekly: Double
    let usageMonthly: Double
    /// `nil` means no cap is configured, not zero.
    let limit: Double?
    let limitRemaining: Double?
    let limitReset: String?

    /// The limit bar's data, or `nil` when no usable cap is configured. The
    /// bar renders exactly when this is non-nil, so the visibility rule lives
    /// here rather than in the view. A cap of zero or less is not a cap, and a
    /// missing `limit_remaining` cannot fill a bar.
    var limitProgress: (remaining: Double, total: Double)? {
        guard let limit, limit > 0, let limitRemaining else { return nil }
        return (remaining: limitRemaining, total: limit)
    }
}

/// One model's base rates and context window from `/api/v1/models`. The API
/// sends prices as decimal strings; a missing or unparseable price is `nil`,
/// never 0, because a `$0.00` price would read as "free". `pricing.overrides`
/// carries tiered rates, so any single figure here is the base rate only.
struct ModelDetail: Equatable {
    let promptPricePerToken: Double?
    let completionPricePerToken: Double?
    let contextLength: Int?
}

/// One `/models` response: the id/name list the pickers use and the per-model
/// details the harness window shows. Both are parsed from a single body, so
/// the two can never disagree about which models exist.
struct Catalog {
    let models: [(id: String, name: String)]
    let details: [String: ModelDetail]
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

    /// A missing usage field must never be read as zero: the same rule
    /// `parseCredits` follows, and for the same reason — `$0.00` is a
    /// plausible-looking, completely wrong number. `limit`, `limit_remaining`
    /// and `limit_reset` are legitimately null, so they are optionals: `nil`
    /// means "no cap configured", not zero.
    static func parseKeyUsage(_ data: Data) throws -> KeyUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let payload = root["data"] as? [String: Any] else {
            throw OpenRouterError.notJSON
        }
        guard let daily = payload["usage_daily"] as? Double else {
            throw OpenRouterError.missingField("data.usage_daily")
        }
        guard let weekly = payload["usage_weekly"] as? Double else {
            throw OpenRouterError.missingField("data.usage_weekly")
        }
        guard let monthly = payload["usage_monthly"] as? Double else {
            throw OpenRouterError.missingField("data.usage_monthly")
        }
        return KeyUsage(
            usageDaily: daily,
            usageWeekly: weekly,
            usageMonthly: monthly,
            limit: payload["limit"] as? Double,
            limitRemaining: payload["limit_remaining"] as? Double,
            limitReset: payload["limit_reset"] as? String)
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

    /// The per-model details from the same `/models` body `parseCatalog`
    /// reads, keyed by model id. An entry without an id cannot be keyed, so it
    /// is a schema change and throws; a missing price or context window is a
    /// legitimately absent value and parses as `nil`.
    static func parseModelDetails(_ data: Data) throws -> [String: ModelDetail] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw OpenRouterError.notJSON
        }
        var details: [String: ModelDetail] = [:]
        for entry in entries {
            guard let id = entry["id"] as? String else {
                throw OpenRouterError.missingField("data[].id")
            }
            let pricing = entry["pricing"] as? [String: Any]
            details[id] = ModelDetail(
                promptPricePerToken: price(pricing?["prompt"]),
                completionPricePerToken: price(pricing?["completion"]),
                contextLength: entry["context_length"] as? Int)
        }
        return details
    }

    /// The API sends prices as decimal strings. A missing, empty or
    /// non-numeric value is `nil`, never 0: `$0.00` reads as "free".
    private static func price(_ raw: Any?) -> Double? {
        guard let string = raw as? String, let value = Double(string) else { return nil }
        return value
    }

    static func credits(apiKey: String) async throws -> Credits {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/credits")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
        return try parseCredits(body)
    }

    /// The per-key usage from `/api/v1/key`. Modelled on `credits(apiKey:)`:
    /// build the request, inspect the status, hand the body to the pure parser.
    static func keyUsage(apiKey: String) async throws -> KeyUsage {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
        return try parseKeyUsage(body)
    }

    /// Fetches the id/name list and the per-model details in one request, so
    /// the picker and the price line can never disagree. The 24-hour cache is
    /// now a fallback rather than a short-circuit: it is served only when the
    /// fetch fails, so the in-memory details — which are deliberately never
    /// persisted — are populated on the first successful fetch of every
    /// launch instead of once per cache lifetime.
    static func models() async throws -> Catalog {
        do {
            let request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
            let (body, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
            let models = try parseCatalog(body)
            let details = try parseModelDetails(body)
            // Best-effort: the contract is to return models, caching is
            // opportunistic. A failed write degrades to refetching next time
            // rather than failing a caller that already holds a good list.
            try? writeCatalog(models)
            return Catalog(models: models, details: details)
        } catch {
            // Offline fallback: the last good list beats no picker at all.
            // Details are not cached, so they stay empty until a fetch
            // succeeds — which is the documented first-launch behaviour.
            if let cached = try? loadCachedCatalog() {
                return Catalog(models: cached, details: [:])
            }
            throw error
        }
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
