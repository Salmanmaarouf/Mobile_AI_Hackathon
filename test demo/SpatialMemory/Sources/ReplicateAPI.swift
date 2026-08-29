//
//  ReplicateAPI.swift
//  SpatialMemory — one Replicate transport, shared by depth and inpainting
//
//  Both network stages talk to the same API: resolve a model version, create a
//  prediction, wait for it, pull an image or a number back out. This is that,
//  once, with the diagnostics in one place — because the failure mode that
//  actually costs you an afternoon is not a bug in the arithmetic, it is a 422
//  whose body says exactly what is wrong and which nobody ever prints.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import Foundation

// MARK: - A Sendable view of arbitrary output JSON

/// Replicate's `output` is whatever the model author decided: a bare URL string
/// for one image, an array for several, an object for a model that returns more
/// than one thing — Depth Pro returns a raster AND a focal length. Rather than
/// pin a shape this cannot know in advance, decode it structurally and let the
/// caller go looking.
public enum ReplicateValue: Sendable, Equatable {

    case string(String)
    case number(Double)
    case bool(Bool)
    case list([ReplicateValue])
    case object([String: ReplicateValue])
    case null

    public subscript(key: String) -> ReplicateValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case let .number(value): return value
        case let .string(value): return Double(value)
        default:                 return nil
        }
    }

    /// The first string anywhere shallow — handles `"url"`, `["url"]`, and an
    /// object whose only interesting field is a string, in one call.
    public var firstString: String? {
        switch self {
        case let .string(value): return value
        case let .list(items):   return items.compactMap(\.firstString).first
        default:                 return nil
        }
    }

    /// Looks for the first of `keys` that is present, then for a string in it.
    /// Falls back to treating the whole value as the answer when it is not an
    /// object, which is the single-output case.
    public func string(forAnyOf keys: [String]) -> String? {
        if case .object = self {
            for key in keys {
                if let found = self[key]?.firstString { return found }
            }
            return nil
        }
        return firstString
    }

    public func number(forAnyOf keys: [String]) -> Double? {
        if case .object = self {
            for key in keys {
                if let found = self[key]?.doubleValue { return found }
            }
            return nil
        }
        return doubleValue
    }

    /// The field names actually present, for an error message that tells you
    /// what to put in the configuration instead of making you guess.
    public var availableKeys: [String] {
        if case let .object(fields) = self { return fields.keys.sorted() }
        return []
    }

    init(_ raw: Any) {
        switch raw {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            // Order matters and the obvious spelling is wrong. JSONSerialization
            // returns booleans as NSNumber, and `NSNumber(value: 1) as? Bool`
            // succeeds — so matching `case as Bool` first would turn every 0 and
            // every 1 in the payload into a boolean. Only CFBoolean is a boolean.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as [Any]:
            self = .list(value.map(ReplicateValue.init))
        case let value as [String: Any]:
            self = .object(value.mapValues(ReplicateValue.init))
        default:
            self = .null
        }
    }

    /// One line describing the shape, for pinning a model's field names down.
    public var compactSummary: String {
        switch self {
        case let .string(value):
            return value.count > 90 ? "\"\(value.prefix(90))…\"" : "\"\(value)\""
        case let .number(value): return String(value)
        case let .bool(value):   return String(value)
        case let .list(items):   return "[" + items.map(\.compactSummary).joined(separator: ", ") + "]"
        case let .object(fields):
            let inner = fields.keys.sorted()
                .map { "\($0): \(fields[$0]?.compactSummary ?? "null")" }
                .joined(separator: ", ")
            return "{" + inner + "}"
        case .null: return "null"
        }
    }
}

// MARK: - Errors

public enum ReplicateAPIError: LocalizedError {
    case http(status: Int, body: String)
    case predictionFailed(String)
    case timedOut(seconds: TimeInterval)
    case noOutput
    case versionUnresolvable(model: String, detail: String)
    case outputShape(expected: String, keysPresent: [String])

    public var errorDescription: String? {
        switch self {
        case let .http(status, body):
            return "Replicate returned \(status): \(body)"
        case let .predictionFailed(message):
            return "Replicate prediction failed: \(message)"
        case let .timedOut(seconds):
            return "Replicate prediction did not finish within \(Int(seconds))s."
        case .noOutput:
            return "Replicate prediction succeeded but carried no output."
        case let .versionUnresolvable(model, detail):
            return "Could not resolve a version for \(model): \(detail)"
        case let .outputShape(expected, keys):
            let present = keys.isEmpty ? "none (output was not an object)" : keys.joined(separator: ", ")
            return "Replicate output had no \(expected). Fields present: \(present)."
        }
    }
}

// MARK: - Transport

public actor ReplicateAPI {

    private let token: String
    private let session: URLSession
    /// `owner/name` → resolved version id, so a second stage using the same
    /// model does not pay for the lookup twice.
    private var versions: [String: String] = [:]

    /// Set true and every prediction's raw output JSON is printed. Leave it on
    /// while you are pinning a new model's field names down; the shape of a
    /// community model's output is not documented anywhere you can reach from
    /// inside the app.
    public var logsRawOutput: Bool

    public init(token: String, timeout: TimeInterval = 120, logsRawOutput: Bool = false) {
        self.token = token
        self.logsRawOutput = logsRawOutput
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    public func setLogsRawOutput(_ enabled: Bool) { logsRawOutput = enabled }

    // MARK: Running a prediction

    public func run(
        model: String,
        version pinned: String? = nil,
        input: [String: Any],
        timeout: TimeInterval = 120,
        pollInterval: TimeInterval = 1.0,
        maxRetries: Int = 3
    ) async throws -> ReplicateValue {

        let version = try await resolveVersion(model: model, pinned: pinned)
        var lastError: Error?

        for attempt in 0..<max(maxRetries, 1) {
            if attempt > 0 {
                let backoff = 0.8 * pow(2.0, Double(attempt - 1)) * Double.random(in: 0.75...1.25)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
            try Task.checkCancellation()

            do {
                var request = URLRequest(url: URL(string: "https://api.replicate.com/v1/predictions")!)
                request.httpMethod = "POST"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // Blocks server side until the prediction settles, up to 60 s,
                // so the polling loop below is usually never entered.
                request.setValue("wait=60", forHTTPHeaderField: "Prefer")
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: ["version": version, "input": input]
                )
                request.timeoutInterval = timeout

                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(status) else {
                    throw ReplicateAPIError.http(status: status, body: Self.body(of: data))
                }

                let settled = try await settle(
                    Self.json(data),
                    timeout: timeout,
                    pollInterval: pollInterval
                )
                guard let output = settled["output"], output != .null else {
                    throw ReplicateAPIError.noOutput
                }
                if logsRawOutput {
                    print("[SpatialMemory] \(model) output \(output.compactSummary)")
                }
                return output

            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ReplicateAPIError {
                // 4xx that is not 429 is permanent: a bad token, an input key the
                // model does not have, a version that no longer exists. Retrying
                // spends seconds the fallback could have spent drawing.
                if case let .http(status, _) = error,
                   status != 429, (400..<500).contains(status) {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ReplicateAPIError.noOutput
    }

    private func settle(
        _ prediction: ReplicateValue,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws -> ReplicateValue {

        var current = prediction
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            switch current["status"]?.stringValue {
            case "succeeded", "successful":
                return current
            case "failed", "canceled":
                let detail = current["error"]?.firstString
                    ?? current["status"]?.stringValue
                    ?? "unknown"
                throw ReplicateAPIError.predictionFailed(detail)
            default:
                break
            }

            guard Date() < deadline else { throw ReplicateAPIError.timedOut(seconds: timeout) }
            guard let next = current["urls"]?["get"]?.stringValue,
                  let url = URL(string: next) else {
                throw ReplicateAPIError.predictionFailed("no polling URL on an unfinished prediction")
            }

            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                throw ReplicateAPIError.http(status: status, body: Self.body(of: data))
            }
            current = Self.json(data)
        }
    }

    private func resolveVersion(model: String, pinned: String?) async throws -> String {
        if let pinned { return pinned }
        if let cached = versions[model] { return cached }

        let url = URL(string: "https://api.replicate.com/v1/models/\(model)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw ReplicateAPIError.versionUnresolvable(
                model: model,
                detail: "HTTP \(status): \(Self.body(of: data))"
            )
        }
        guard let id = Self.json(data)["latest_version"]?["id"]?.stringValue else {
            throw ReplicateAPIError.versionUnresolvable(
                model: model,
                detail: "no latest_version.id in the model response"
            )
        }
        versions[model] = id
        return id
    }

    // MARK: Diagnosis

    /// Answers the three questions that come before any question about input
    /// field names: does the token authenticate, can this device reach the API
    /// at all, and does each model exist under the name it is being asked for.
    ///
    /// Deliberately never throws. A diagnostic that fails on the first problem
    /// tells you about one thing when you wanted to know about all of them.
    public func diagnose(models: [String]) async -> String {
        var lines: [String] = []

        // Account first: this separates "bad token" and "no network" from
        // "model not found", which otherwise look identical from the app.
        var request = URLRequest(url: URL(string: "https://api.replicate.com/v1/account")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(status) {
                let who = Self.json(data)["username"]?.stringValue ?? "authenticated"
                lines.append("token OK — \(who)")
            } else {
                lines.append("token REJECTED — HTTP \(status): \(Self.body(of: data))")
            }
        } catch {
            lines.append("cannot reach api.replicate.com — \(error.localizedDescription)")
        }

        for model in models {
            do {
                let id = try await resolveVersion(model: model, pinned: nil)
                lines.append("\(model) OK — version \(id.prefix(12))…")
            } catch {
                lines.append("\(model) FAILED — \(error.localizedDescription)")
            }
        }

        let report = lines.joined(separator: "\n")
        print("[SpatialMemory] Replicate diagnosis:\n\(report)")
        return report
    }

    // MARK: Fetching an output

    /// Resolves an output reference — Replicate hands back either an inline
    /// `data:` URI or a short-lived CDN URL, depending on how the model's
    /// container was configured.
    public func image(at reference: String) async throws -> CGImage {
        if reference.hasPrefix("data:") {
            guard let comma = reference.firstIndex(of: ","),
                  let bytes = Data(
                    base64Encoded: String(reference[reference.index(after: comma)...]),
                    options: [.ignoreUnknownCharacters]
                  ) else {
                throw ImagingError.decodingFailed
            }
            return try ImageDecoder.cgImage(from: bytes)
        }

        guard let url = URL(string: reference) else { throw ImagingError.decodingFailed }
        let (bytes, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw ReplicateAPIError.http(status: status, body: "output fetch failed")
        }
        return try ImageDecoder.cgImage(from: bytes)
    }

    // MARK: Payload helpers

    public nonisolated static func dataURI(_ png: Data) -> String {
        "data:image/png;base64,\(png.base64EncodedString())"
    }

    nonisolated static func json(_ data: Data) -> ReplicateValue {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return .null }
        return ReplicateValue(raw)
    }

    /// The most useful 512 bytes of a failure. Replicate puts the actionable
    /// part in `detail` — "Invalid token", or the name of the input field the
    /// model does not have.
    nonisolated static func body(of data: Data) -> String {
        let value = json(data)
        for key in ["detail", "title", "error"] {
            if let message = value[key]?.firstString { return message }
        }
        return String(data: data.prefix(512), encoding: .utf8) ?? "<unreadable body>"
    }
}
