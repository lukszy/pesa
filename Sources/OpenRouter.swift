import Foundation

/// The credit totals OpenRouter reports. `remaining` is computed rather than
/// stored so the two fields can never disagree with the difference.
struct Credits: Equatable {
    let totalCredits: Double
    let totalUsage: Double
    var remaining: Double { totalCredits - totalUsage }
}

/// Free-model (`:free` variant) daily request quota reported for the key's
/// account. `used`/`limit`/`remaining` reset at UTC midnight.
struct FreeModelQuota: Equatable {
    let used: Int
    let limit: Int
    let remaining: Int
}

/// The per-key usage OpenRouter reports from `/api/v1/key`. This is *per key*
/// whereas `Credits` is account-wide: with more than one key the two do not
/// add up, so the UI must never present them as a single figure.
///
/// The fields after the three required usage windows are optional because the
/// endpoint adds to itself over time: an absent `byok_usage` or
/// `free_model_daily_requests` means "not reported", and must render as omitted,
/// never as 0.
struct KeyUsage: Equatable {
    let usageDaily: Double
    let usageWeekly: Double
    let usageMonthly: Double
    /// Defaults keep the memberwise initializer source-compatible for the
    /// limit-bar checks, which care only about `limit`.
    var usageTotal: Double? = nil
    /// External BYOK (your own provider key) usage, all time.
    var byokUsage: Double? = nil
    var isFreeTier: Bool? = nil
    var freeModelQuota: FreeModelQuota? = nil
    /// The key's human-readable label, so "This key" can be identified.
    var label: String? = nil
    /// When the key expires, parsed from `expires_at`; nil when it does not.
    var expiresAt: Date? = nil
    /// `nil` means no cap is configured, not zero.
    var limit: Double? = nil
    var limitRemaining: Double? = nil
    var limitReset: String? = nil

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

/// One upstream provider serving a model, from
/// `GET /models/{author}/{slug}/endpoints` joined with the ZDR and provider
/// lists. Every price/speed/context field is optional because the API omits it
/// for some endpoints; a missing datum must render as omitted, never as zero.
/// `providerSlug` is the API `tag` (the key the ZDR list and `/providers` use).
struct EndpointInfo: Equatable {
    let providerSlug: String
    let providerName: String
    let promptPricePerToken: Double?
    let completionPricePerToken: Double?
    let throughputP50: Double?
    let latencyP50: Double?
    let contextLength: Int?
    let quantization: String?
    let zdr: Bool
    let privacyPolicyURL: String?
    let termsOfServiceURL: String?
}

/// `Identifiable` and the sort keys the editor's SwiftUI `Table` needs. A
/// `TableColumn` sorts through a `KeyPathComparator` on a `Comparable` value,
/// and `Optional` is not `Comparable`, so a missing numeric datum maps to the
/// largest finite value: ascending puts it last, which is the same "missing is
/// not zero" rule the rest of the app follows.
extension EndpointInfo: Identifiable {
    var id: String { providerSlug }
    var promptOrder: Double { promptPricePerToken ?? .greatestFiniteMagnitude }
    var completionOrder: Double { completionPricePerToken ?? .greatestFiniteMagnitude }
    var speedOrder: Double { throughputP50 ?? .greatestFiniteMagnitude }
    /// ZDR first when ascending: a policy flag, not a missing value.
    var zdrOrder: Int { zdr ? 0 : 1 }
    /// Unquantized sorts after a named quantization when ascending.
    var quantOrder: String { quantization ?? "\u{10FFFF}" }
}

/// One `/models` response: the id/name list the pickers use and the per-model
/// details the harness window shows. Both are parsed from a single body, so
/// the two can never disagree about which models exist.
struct Catalog {
    let models: [(id: String, name: String)]
    let details: [String: ModelDetail]

    /// Whether the details carry any real datum. A catalog whose every entry is
    /// the all-nil placeholder adds nothing a fetch would not, so it must not
    /// satisfy the cache short-circuit. This is also the guard that keeps a
    /// detail-less cache from wiping prices already shown (see `refresh`).
    static func hasData(_ details: [String: ModelDetail]) -> Bool {
        details.values.contains {
            $0.promptPricePerToken != nil
                || $0.completionPricePerToken != nil
                || $0.contextLength != nil
        }
    }

    var hasModelDetails: Bool { Catalog.hasData(details) }
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
    /// `~/.pesa-app/models-cache.json`, alongside the settings file.
    static let catalogPath: String = "\(AppConfig.directory)/models-cache.json"

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
        // The free-model quota object is all-or-nothing: a half-reported quota
        // is treated as absent rather than as a partial (and misleading) bar.
        let quota: FreeModelQuota? = {
            guard let raw = payload["free_model_daily_requests"] as? [String: Any],
                  let used = raw["used"] as? Int,
                  let limit = raw["limit"] as? Int,
                  let remaining = raw["remaining"] as? Int else { return nil }
            return FreeModelQuota(used: used, limit: limit, remaining: remaining)
        }()
        return KeyUsage(
            usageDaily: daily,
            usageWeekly: weekly,
            usageMonthly: monthly,
            usageTotal: payload["usage"] as? Double,
            byokUsage: payload["byok_usage"] as? Double,
            isFreeTier: payload["is_free_tier"] as? Bool,
            freeModelQuota: quota,
            label: payload["label"] as? String,
            expiresAt: (payload["expires_at"] as? String)
                .flatMap { ISO8601DateFormatter().date(from: $0) },
            limit: payload["limit"] as? Double,
            limitRemaining: payload["limit_remaining"] as? Double,
            limitReset: payload["limit_reset"] as? String)
    }

    /// The `data` array of a `/models` response (or of the cache file's
    /// equivalent list). Shared by both parsers so the two can never read a
    /// different set of entries.
    private static func modelEntries(in data: Data) throws -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw OpenRouterError.notJSON
        }
        return entries
    }

    /// One `id`/`name` pair. Every entry must carry both; a partial entry is a
    /// schema change, not a nameless model.
    private static func catalogEntry(_ entry: [String: Any]) throws -> (id: String, name: String) {
        guard let id = entry["id"] as? String, let name = entry["name"] as? String else {
            throw OpenRouterError.missingField("data[].id/name")
        }
        return (id: id, name: name)
    }

    /// One entry's base rates and context window. An entry without an id cannot
    /// be keyed, so it is a schema change and throws; a missing price or context
    /// window is a legitimately absent value and parses as `nil`.
    private static func modelDetailEntry(_ entry: [String: Any]) throws -> (id: String, detail: ModelDetail) {
        guard let id = entry["id"] as? String else {
            throw OpenRouterError.missingField("data[].id")
        }
        let pricing = entry["pricing"] as? [String: Any]
        return (id, ModelDetail(
            promptPricePerToken: price(pricing?["prompt"]),
            completionPricePerToken: price(pricing?["completion"]),
            contextLength: entry["context_length"] as? Int))
    }

    static func parseCatalog(_ data: Data) throws -> [(id: String, name: String)] {
        try modelEntries(in: data).map(catalogEntry)
    }

    /// The per-model details from the same `/models` body `parseCatalog`
    /// reads, keyed by model id.
    static func parseModelDetails(_ data: Data) throws -> [String: ModelDetail] {
        var details: [String: ModelDetail] = [:]
        for entry in try modelEntries(in: data) {
            let (id, detail) = try modelDetailEntry(entry)
            details[id] = detail
        }
        return details
    }

    /// The API sends prices as decimal strings. A missing, empty or
    /// non-numeric value is `nil`, never 0: `$0.00` reads as "free". A
    /// **negative** value is OpenRouter's sentinel for variable or unknown
    /// pricing (`openrouter/auto` ships `"prompt": "-1"`); it is not a rate,
    /// and rendering it as money would show `-$1,000,000.00/M`. Zero is
    /// rejected by neither rule: genuinely free models legitimately price `"0"`.
    private static func price(_ raw: Any?) -> Double? {
        guard let string = raw as? String, let value = Double(string), value >= 0 else { return nil }
        return value
    }

    /// A JSON number tolerating the integer/double split `JSONSerialization`
    /// produces. A missing or non-numeric value is `nil`, never 0.
    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
    }

    /// The `p50` inside a `throughput_last_30m` / `latency_last_30m` object.
    private static func p50(_ raw: Any?) -> Double? {
        guard let object = raw as? [String: Any] else { return nil }
        return number(object["p50"])
    }

    /// One endpoints body's `data.endpoints[]`. `tag` (falling back to the
    /// lowercased `provider_name`) is the slug the ZDR and provider lists key
    /// on; the model id comes from the body itself so the ZDR key matches. An
    /// entry with neither a tag nor a name cannot be keyed and is skipped.
    static func parseModelEndpoints(_ data: Data, zdrKeys: Set<String>) throws -> [EndpointInfo] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let entries = payload["endpoints"] as? [[String: Any]] else {
            throw OpenRouterError.notJSON
        }
        let modelID = payload["id"] as? String ?? ""
        return entries.compactMap { entry in
            let providerName = entry["provider_name"] as? String ?? ""
            let slug = (entry["tag"] as? String) ?? providerName.lowercased()
            guard !slug.isEmpty else { return nil }
            let pricing = entry["pricing"] as? [String: Any]
            return EndpointInfo(
                providerSlug: slug,
                providerName: providerName.isEmpty ? slug : providerName,
                promptPricePerToken: price(pricing?["prompt"]),
                completionPricePerToken: price(pricing?["completion"]),
                throughputP50: p50(entry["throughput_last_30m"]),
                latencyP50: p50(entry["latency_last_30m"]),
                contextLength: entry["context_length"] as? Int,
                quantization: entry["quantization"] as? String,
                zdr: zdrKeys.contains("\(modelID)|\(slug)"),
                privacyPolicyURL: entry["privacy_policy_url"] as? String,
                termsOfServiceURL: entry["terms_of_service_url"] as? String)
        }
    }

    /// The `model_id|tag` keys of `GET /endpoints/zdr`. Despite the name, that
    /// body is the same endpoint-object shape as
    /// `/models/{author}/{slug}/endpoints`: each entry carries `model_id` and
    /// the provider `tag` (the slug), not `model`/`provider`. Reading the wrong
    /// field names would throw on every live call and silently empty the
    /// provider table, so the key is built from the same two fields
    /// `parseModelEndpoints` uses.
    static func parseZDR(_ data: Data) throws -> Set<String> {
        var keys: Set<String> = []
        for entry in try modelEntries(in: data) {
            guard let model = entry["model_id"] as? String,
                  let provider = entry["tag"] as? String else {
                throw OpenRouterError.missingField("data[].model_id/tag")
            }
            keys.insert("\(model)|\(provider)")
        }
        return keys
    }

    /// `GET /providers`, keyed by `slug`. Both URLs are legitimately null for
    /// some providers and parse as `nil`, never as an empty string.
    static func parseProviders(_ data: Data) throws -> [String: (privacy: String?, tos: String?)] {
        var providers: [String: (privacy: String?, tos: String?)] = [:]
        for entry in try modelEntries(in: data) {
            guard let slug = entry["slug"] as? String else {
                throw OpenRouterError.missingField("data[].slug")
            }
            providers[slug] = (
                privacy: entry["privacy_policy_url"] as? String,
                tos: entry["terms_of_service_url"] as? String)
        }
        return providers
    }

    /// The `/providers` entry for an endpoint's provider slug. That list keys on
    /// the base slug (`google-vertex`) while an endpoint's `tag` can carry a
    /// region or variant suffix (`google-vertex/global`), so a miss falls back
    /// to the segment before the first `/`. Without it those rows render no
    /// privacy/ToS links. Pure, so the fallback is pinned by a check.
    static func providerInfo(forSlug slug: String,
                             in providers: [String: (privacy: String?, tos: String?)])
        -> (privacy: String?, tos: String?)? {
        if let exact = providers[slug] { return exact }
        return providers[String(slug.prefix(while: { $0 != "/" }))]
    }

    /// One authenticated GET, status-checked. Shared by the three endpoint
    /// fetches so they cannot disagree about auth or error handling.
    private static func get(_ urlString: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw OpenRouterError.missingField("endpoints url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
        return body
    }

    /// The live per-provider facts for one model. The model id is split on the
    /// **first** `/` only, so ids that themselves contain a slash
    /// (`deepseek/deepseek-v4.1-flash`) keep their tail. pi's `~` alias prefix
    /// is stripped before the request or the path 404s. Endpoints, ZDR and
    /// providers are fetched together and joined in memory; any failure throws
    /// so the caller can degrade to the editor's base price line.
    static func modelEndpoints(modelID: String, apiKey: String) async throws -> [EndpointInfo] {
        let stripped = modelID.hasPrefix("~") ? String(modelID.dropFirst()) : modelID
        guard let slash = stripped.firstIndex(of: "/") else {
            throw OpenRouterError.missingField("model id")
        }
        let author = String(stripped[..<slash])
        let slug = String(stripped[stripped.index(after: slash)...])
        guard !author.isEmpty, !slug.isEmpty else {
            throw OpenRouterError.missingField("model id")
        }

        let endpointsData = try await get(
            "https://openrouter.ai/api/v1/models/\(author)/\(slug)/endpoints", apiKey: apiKey)
        let zdrData = try await get(
            "https://openrouter.ai/api/v1/endpoints/zdr", apiKey: apiKey)
        let providersData = try await get(
            "https://openrouter.ai/api/v1/providers", apiKey: apiKey)

        let zdrKeys = try parseZDR(zdrData)
        let providers = try parseProviders(providersData)
        return try parseModelEndpoints(endpointsData, zdrKeys: zdrKeys).map { endpoint in
            let provider = providerInfo(forSlug: endpoint.providerSlug, in: providers)
            return EndpointInfo(
                providerSlug: endpoint.providerSlug,
                providerName: endpoint.providerName,
                promptPricePerToken: endpoint.promptPricePerToken,
                completionPricePerToken: endpoint.completionPricePerToken,
                throughputP50: endpoint.throughputP50,
                latencyP50: endpoint.latencyP50,
                contextLength: endpoint.contextLength,
                quantization: endpoint.quantization,
                zdr: endpoint.zdr,
                privacyPolicyURL: provider?.privacy ?? endpoint.privacyPolicyURL,
                termsOfServiceURL: provider?.tos ?? endpoint.termsOfServiceURL)
        }
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
    /// the picker and the price line can never disagree. A fresh cache now
    /// carries both, so it short-circuits the fetch and restores the 24-hour
    /// cooldown: the app no longer pulls ~737 KB of `/models` on every refresh.
    /// A cache written before details were persisted has none, so it does not
    /// short-circuit — the next successful fetch upgrades it in place.
    static func models() async throws -> Catalog {
        if let cached = try? loadCachedCatalogWithDetails(), cached.hasModelDetails {
            return cached
        }
        do {
            let request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
            let (body, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
            let catalog = Catalog(
                models: try parseCatalog(body),
                details: try parseModelDetails(body))
            // Best-effort: the contract is to return models, caching is
            // opportunistic. A failed write degrades to refetching next time
            // rather than failing a caller that already holds a good list.
            try? writeCatalog(catalog)
            return catalog
        } catch {
            // Offline fallback: the last good cache beats no picker at all,
            // details included when it has them (the all-nil list-only shape
            // still yields no price line, which is correct for missing data).
            if let cached = try? loadCachedCatalogWithDetails() {
                return cached
            }
            throw error
        }
    }

    /// The full cached catalog: the id/name list and the persisted per-model
    /// details. `nil` when the file is absent or older than 24 hours; throws
    /// when it is present but unreadable or malformed, so a corrupt cache never
    /// reads as an empty catalog.
    static func loadCachedCatalogWithDetails(from path: String = OpenRouter.catalogPath) throws
        -> Catalog? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try parseCachedCatalog(data)
    }

    /// Decodes a cache body. Pure apart from the freshness clock, so the
    /// selftest can round-trip `encodeCatalog` through it without a file or a
    /// network call.
    static func parseCachedCatalog(_ data: Data) throws -> Catalog? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let fetchedAtString = root["fetchedAt"] as? String,
              let fetchedAt = ISO8601DateFormatter().date(from: fetchedAtString),
              let entries = root["models"] as? [[String: Any]] else {
            throw OpenRouterError.notJSON
        }
        guard Date().timeIntervalSince(fetchedAt) < 24 * 60 * 60 else { return nil }
        let models = try entries.map(catalogEntry)
        var details: [String: ModelDetail] = [:]
        for entry in entries {
            let (id, detail) = try modelDetailEntry(entry)
            details[id] = detail
        }
        return Catalog(models: models, details: details)
    }

    /// Encodes a catalog in the cache shape. The details ride along as the same
    /// `pricing`/`context_length` entry fields the live response uses, so one
    /// set of parsers reads both. Internal so the selftest can round-trip it.
    static func encodeCatalog(_ catalog: Catalog) throws -> Data {
        let payload: [String: Any] = [
            "fetchedAt": ISO8601DateFormatter().string(from: Date()),
            "models": catalog.models.map { model -> [String: Any] in
                var entry: [String: Any] = ["id": model.id, "name": model.name]
                if let detail = catalog.details[model.id] {
                    var pricing: [String: Any] = [:]
                    if let prompt = detail.promptPricePerToken { pricing["prompt"] = String(prompt) }
                    if let completion = detail.completionPricePerToken { pricing["completion"] = String(completion) }
                    if !pricing.isEmpty { entry["pricing"] = pricing }
                    if let context = detail.contextLength { entry["context_length"] = context }
                }
                return entry
            },
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Kept as the list-only view for callers that only need the picker. A
    /// missing or stale file is `nil`; a malformed one throws.
    static func loadCachedCatalog(from path: String = OpenRouter.catalogPath) throws
        -> [(id: String, name: String)]? {
        try loadCachedCatalogWithDetails(from: path)?.models
    }

    private static func writeCatalog(_ catalog: Catalog) throws {
        let data = try encodeCatalog(catalog)
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
