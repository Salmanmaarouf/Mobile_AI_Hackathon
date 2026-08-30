//
//  ReplicateInpainting.swift
//  SpatialMemory — background continuation that cannot invent a person
//
//  ============================================================================
//  WHY THIS EXISTS ALONGSIDE `InpaintingClient`
//
//  `/v1/images/edits` does not fill a hole. It redraws the whole square canvas
//  from a text prompt, and it is free to put anything in the result — including
//  a face where a face used to be. For a memory that a person with dementia is
//  going to inhabit, a plausible stranger standing where their husband stood is
//  not a rendering artefact, it is a false memory presented as a real one. No
//  prompt reliably prevents it, because generation is what that endpoint does.
//
//  LaMa (Suvorov et al., WACV 2022) is the other kind of model. It is not text
//  conditioned at all: it takes an image and a mask and continues the
//  surrounding structure into the masked region using Fourier convolutions,
//  which is why it holds long straight edges — walls, floors, door frames,
//  whiteboards — across large holes. It has no concept of "person" to draw. It
//  is the model behind most of the object-removal buttons you have used.
//
//  Consequences for this file: `prompt` is accepted and ignored, and there is
//  no square canvas. LaMa is resolution robust, so the plate goes up at its own
//  aspect ratio and comes back the same shape, which removes the letterbox pad
//  and unproject round trip that `SquareCanvas` exists to undo.
//  ============================================================================
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import CoreImage
import Foundation

// MARK: - Configuration

public struct ReplicateConfiguration: Sendable {

    /// From replicate.com/account/api-tokens. Read it from the environment or
    /// the keychain — see `SpatialMemoryEngine.replicate(...)`.
    public var apiToken: String

    /// `owner/name` of the inpainting model.
    ///
    /// The default is the most-run LaMa mirror on Replicate. Any model taking an
    /// image and a binary mask and returning an image will work; change
    /// `imageInputKey` / `maskInputKey` if it names its inputs differently.
    public var model: String

    /// Pin a specific version hash, or leave `nil` to resolve the model's latest
    /// version at first use.
    ///
    /// Resolving costs one extra request per process and never goes stale, which
    /// is worth more than the round trip: a hardcoded hash is a time bomb that
    /// starts returning 422 the day the owner pushes a new version.
    public var version: String?

    public var imageInputKey: String
    public var maskInputKey: String

    /// Long edge the plate is resampled to before upload. The backdrop is seen
    /// at several metres, through the mesh's tears, and is then overscanned and
    /// blurred at the rim — 1024 is already more detail than survives. Larger
    /// costs base64 payload and inference time for pixels nobody resolves.
    public var uploadLongEdge: Int

    /// Ceiling on either encoded PNG. The whole request is JSON with the images
    /// inline as data URIs, so base64 adds a third on top of this.
    public var maxBytesPerFile: Int

    /// Seconds to wait for the prediction. `Prefer: wait` blocks server-side up
    /// to 60; anything longer falls through to polling.
    public var timeout: TimeInterval

    public var pollInterval: TimeInterval
    public var maxRetries: Int

    public init(
        apiToken: String,
        model: String = "allenhooo/lama",
        version: String? = nil,
        imageInputKey: String = "image",
        maskInputKey: String = "mask",
        uploadLongEdge: Int = 1024,
        maxBytesPerFile: Int = 3_500_000,
        timeout: TimeInterval = 120,
        pollInterval: TimeInterval = 1.0,
        maxRetries: Int = 3
    ) {
        self.apiToken = apiToken
        self.model = model
        self.version = version
        self.imageInputKey = imageInputKey
        self.maskInputKey = maskInputKey
        self.uploadLongEdge = uploadLongEdge
        self.maxBytesPerFile = maxBytesPerFile
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.maxRetries = maxRetries
    }
}

// MARK: - Errors

public enum ReplicateError: LocalizedError {
    case badResponse(status: Int, message: String)
    case predictionFailed(String)
    case timedOut(seconds: TimeInterval)
    case noOutput
    case versionUnresolvable(model: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .badResponse(status, message):
            return "Replicate returned \(status): \(message)"
        case let .predictionFailed(message):
            return "Replicate prediction failed: \(message)"
        case let .timedOut(seconds):
            return "Replicate prediction did not finish within \(Int(seconds))s."
        case .noOutput:
            return "Replicate prediction succeeded but carried no image."
        case let .versionUnresolvable(model, detail):
            return "Could not resolve a version for \(model): \(detail)"
        }
    }
}

// MARK: - Wire shapes

private struct ReplicateModelResponse: Decodable {
    struct Version: Decodable { let id: String }
    let latest_version: Version?
}

private struct ReplicatePrediction: Decodable {
    struct URLs: Decodable { let get: URL? }
    let id: String?
    let status: String?
    let error: ReplicateErrorValue?
    let urls: URLs?
    /// LaMa returns a single string. Other models return an array. Both, and a
    /// null while the prediction is still running, have to decode.
    let output: ReplicateOutput?
}

/// Replicate's `error` is a string on most models and an object on a few.
private enum ReplicateErrorValue: Decodable {
    case text(String)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            self = .other
        }
    }

    var message: String {
        switch self {
        case let .text(value): return value
        case .other:           return "unspecified error"
        }
    }
}

private enum ReplicateOutput: Decodable {
    case single(String)
    case many([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let one = try? container.decode(String.self) {
            self = .single(one)
        } else if let list = try? container.decode([String].self) {
            self = .many(list)
        } else {
            self = .many([])
        }
    }

    var first: String? {
        switch self {
        case let .single(value): return value
        case let .many(list):    return list.first
        }
    }
}

// MARK: - Client

public actor ReplicateInpaintingClient {

    private let configuration: ReplicateConfiguration
    private let session: URLSession
    private var resolvedVersion: String?

    public init(configuration: ReplicateConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.resolvedVersion = configuration.version
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = configuration.timeout
            config.timeoutIntervalForResource = configuration.timeout * 2
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    /// - Parameters:
    ///   - plate: the frame to inpaint. For LaMa this should be the ORIGINAL
    ///     photograph with the subject still in it, not a punched-out plate —
    ///     the model decides what to erase from the mask, and it continues the
    ///     surroundings better when it can see what was there. Use
    ///     `PipelineOptions.SourceStrategy.originalWithMaskOnly`.
    ///   - mask: this project's convention — black RGB, alpha 0 over the hole.
    ///     Converted here to LaMa's convention, which is opaque white over the
    ///     region to fill.
    ///   - prompt: accepted and ignored. LaMa is not text conditioned. That is
    ///     the property being bought, not a limitation being tolerated.
    public func inpaint(plate: CGImage, mask: CGImage, prompt: String) async throws -> CGImage {
        _ = prompt

        let targetSize = plate.size

        let smallPlate = try Self.fit(plate, longEdge: configuration.uploadLongEdge)
        let side = CGSize(width: smallPlate.width, height: smallPlate.height)

        // 1 where the API mask said alpha 0, then flattened to opaque white on
        // black — which is what a LaMa mask is.
        let holeExtent = CGRect(origin: .zero, size: mask.size)
        let hole = LocalBackgroundFiller.holeMask(fromAPIMask: mask.ci).cropped(to: holeExtent)
        let holeImage = try hole.render(cropping: holeExtent)
        let smallMask = try Self.resize(holeImage, to: side)

        let plateData = try PNGEncoder.encode(smallPlate, preserveAlpha: false)
        let maskData = try PNGEncoder.encode(smallMask, preserveAlpha: false)

        for data in [plateData, maskData] where data.count > configuration.maxBytesPerFile {
            throw ImagingError.pngBudgetExceeded(
                bytes: data.count,
                budget: configuration.maxBytesPerFile
            )
        }

        let returned = try await run(
            image: Self.dataURI(plateData),
            mask: Self.dataURI(maskData)
        )

        // Back onto the source pixel grid so the caller's aspect and the
        // backdrop geometry still agree.
        return try Self.resize(returned, to: targetSize)
    }

    // MARK: Transport

    private func run(image: String, mask: String) async throws -> CGImage {
        let modelVersion = try await resolveVersion()

        var lastError: Error?
        for attempt in 0..<max(configuration.maxRetries, 1) {
            if attempt > 0 {
                let backoff = 0.8 * pow(2.0, Double(attempt - 1)) * Double.random(in: 0.75...1.25)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
            try Task.checkCancellation()

            do {
                let body: [String: Any] = [
                    "version": modelVersion,
                    "input": [
                        configuration.imageInputKey: image,
                        configuration.maskInputKey: mask
                    ]
                ]

                var request = URLRequest(url: URL(string: "https://api.replicate.com/v1/predictions")!)
                request.httpMethod = "POST"
                request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // Blocks server-side until the prediction finishes, up to 60 s.
                // LaMa runs in about two, so in practice this returns a finished
                // prediction and the polling loop below never spins.
                request.setValue("wait=60", forHTTPHeaderField: "Prefer")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = configuration.timeout

                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1

                // A non-2xx is raised the same way whatever the code; the catch
                // below is what decides between "retry" and "give up now".
                guard (200..<300).contains(status) else {
                    throw ReplicateError.badResponse(
                        status: status,
                        message: Self.errorMessage(from: data)
                    )
                }

                let prediction = try JSONDecoder().decode(ReplicatePrediction.self, from: data)
                let settled = try await settle(prediction)
                guard let reference = settled.output?.first else { throw ReplicateError.noOutput }
                return try await Self.image(from: reference, session: session)

            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ReplicateError {
                // 4xx other than 429 is permanent — a bad token, a wrong input
                // key, a version that no longer exists. Retrying burns seconds
                // the fallback filler could have spent drawing something.
                if case let .badResponse(status, _) = error,
                   status != 429, (400..<500).contains(status) {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ReplicateError.noOutput
    }

    /// Polls until the prediction reaches a terminal state, if `Prefer: wait`
    /// did not already deliver one.
    private func settle(_ prediction: ReplicatePrediction) async throws -> ReplicatePrediction {
        var current = prediction
        let deadline = Date().addingTimeInterval(configuration.timeout)

        while true {
            switch current.status {
            case "succeeded", "successful":
                return current
            case "failed", "canceled":
                throw ReplicateError.predictionFailed(current.error?.message ?? current.status ?? "unknown")
            default:
                break
            }

            guard Date() < deadline else {
                throw ReplicateError.timedOut(seconds: configuration.timeout)
            }
            guard let next = current.urls?.get else {
                throw ReplicateError.predictionFailed("no polling URL on an unfinished prediction")
            }

            try await Task.sleep(nanoseconds: UInt64(configuration.pollInterval * 1_000_000_000))
            try Task.checkCancellation()

            var request = URLRequest(url: next)
            request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                throw ReplicateError.badResponse(status: status, message: Self.errorMessage(from: data))
            }
            current = try JSONDecoder().decode(ReplicatePrediction.self, from: data)
        }
    }

    /// The pinned version, or the model's latest, resolved once per client.
    private func resolveVersion() async throws -> String {
        if let resolvedVersion { return resolvedVersion }

        let url = URL(string: "https://api.replicate.com/v1/models/\(configuration.model)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw ReplicateError.versionUnresolvable(
                model: configuration.model,
                detail: "HTTP \(status): \(Self.errorMessage(from: data))"
            )
        }
        guard let decoded = try? JSONDecoder().decode(ReplicateModelResponse.self, from: data),
              let id = decoded.latest_version?.id else {
            throw ReplicateError.versionUnresolvable(
                model: configuration.model,
                detail: "no latest_version in the model response"
            )
        }

        resolvedVersion = id
        return id
    }

    // MARK: Payload helpers

    /// Replicate returns either an inline data URI or a short-lived CDN URL,
    /// depending on how the model's container was configured.
    private static func image(from reference: String, session: URLSession) async throws -> CGImage {
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
            throw ReplicateError.badResponse(status: status, message: "output fetch failed")
        }
        return try ImageDecoder.cgImage(from: bytes)
    }

    private static func dataURI(_ png: Data) -> String {
        "data:image/png;base64,\(png.base64EncodedString())"
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? String { return detail }
            if let title = object["title"] as? String { return title }
            if let error = object["error"] as? String { return error }
        }
        return String(data: data.prefix(512), encoding: .utf8) ?? "<unreadable body>"
    }

    // MARK: Geometry helpers

    /// Resamples so the long edge is at most `longEdge`, preserving aspect.
    /// Never upscales — there is no detail to invent on the way up.
    static func fit(_ image: CGImage, longEdge: Int) throws -> CGImage {
        let current = max(image.width, image.height)
        guard current > longEdge, longEdge > 0 else { return image }
        let scale = CGFloat(longEdge) / CGFloat(current)
        let target = CGSize(
            width: max(1, (CGFloat(image.width) * scale).rounded()),
            height: max(1, (CGFloat(image.height) * scale).rounded())
        )
        return try resize(image, to: target)
    }

    static func resize(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0 else { throw ImagingError.emptyExtent }
        if w == image.width && h == image.height { return image }

        guard let context = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: ImagingContext.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImagingError.rasterizationFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = context.makeImage() else { throw ImagingError.rasterizationFailed }
        return out
    }
}

// MARK: - The seam

extension ReplicateInpaintingClient: BackgroundFilling {
    public func fill(plate: CGImage, mask: CGImage, prompt: String) async throws -> CGImage {
        try await inpaint(plate: plate, mask: mask, prompt: prompt)
    }
}
