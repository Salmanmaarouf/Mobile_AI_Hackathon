//
//  InpaintingClient.swift
//  SpatialMemory — PHASE 2: AI Inpainting Network Pipeline
//
//  Uploads the punched-out background plate plus its alpha mask to an
//  OpenAI-style `/v1/images/edits` endpoint and returns the hallucinated plate
//  restored to the source aspect ratio.
//
//  Targets: Swift 5.10+, visionOS 1.0+
//

import CoreGraphics
import Foundation

// MARK: - Multipart body builder

/// Minimal, allocation-conscious `multipart/form-data` writer.
///
/// The wire format is unforgiving: every part opens with `--<boundary>CRLF`,
/// headers are CRLF-separated, a blank CRLF line separates headers from the
/// payload, each payload is followed by a CRLF, and the body terminates with
/// `--<boundary>--CRLF`. A single missing CRLF produces a 400 with a message
/// that does not mention CRLFs.
public struct MultipartFormData {

    public let boundary: String
    private var body = Data()
    private var finalized = false

    public init(boundary: String = "SpatialMemory-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public mutating func append(name: String, value: String) {
        precondition(!finalized, "cannot append after finalize()")
        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        write(value)
        write("\r\n")
    }

    public mutating func append(
        name: String,
        filename: String,
        mimeType: String,
        data: Data
    ) {
        precondition(!finalized, "cannot append after finalize()")
        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        write("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        write("\r\n")
    }

    public mutating func finalize() -> Data {
        guard !finalized else { return body }
        write("--\(boundary)--\r\n")
        finalized = true
        return body
    }

    private mutating func write(_ string: String) {
        body.append(Data(string.utf8))
    }
}

// MARK: - Configuration

public struct InpaintingConfiguration: Sendable {

    public var endpoint: URL
    public var apiKey: String
    public var model: String

    /// Ladder of square sides to try, largest first. Every entry must be a size
    /// the endpoint accepts.
    public var sideLadder: [Int]

    /// Hard upload budget per file. The documented ceiling for the classic
    /// edits endpoint is 4 MB; we target slightly under it so the multipart
    /// envelope and headers cannot push a borderline payload over.
    public var maxBytesPerFile: Int

    /// Seconds before the request is abandoned. Diffusion inpainting on a
    /// 1024² canvas routinely takes 20–60 s, so the URLSession default of 60 is
    /// too tight to rely on.
    public var timeout: TimeInterval

    public var maxRetries: Int

    /// Additional headers, e.g. `OpenAI-Organization`, or an Azure `api-key`.
    public var extraHeaders: [String: String]

    public init(
        endpoint: URL,
        apiKey: String,
        model: String = "gpt-image-1",
        sideLadder: [Int] = [1024, 768, 512],
        maxBytesPerFile: Int = 3_900_000,
        timeout: TimeInterval = 180,
        maxRetries: Int = 3,
        extraHeaders: [String: String] = [:]
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.sideLadder = sideLadder
        self.maxBytesPerFile = maxBytesPerFile
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.extraHeaders = extraHeaders
    }
}

// MARK: - Errors

public enum InpaintingError: LocalizedError {
    case badResponse(status: Int, message: String)
    case emptyPayload
    case transportFailure(underlying: Error)
    case retriesExhausted(lastStatus: Int?)

    public var errorDescription: String? {
        switch self {
        case let .badResponse(status, message):
            return "Inpainting endpoint returned \(status): \(message)"
        case .emptyPayload:
            return "Inpainting response contained no image data."
        case let .transportFailure(error):
            return "Network transport failed: \(error.localizedDescription)"
        case let .retriesExhausted(status):
            return "Gave up after retrying; last status was \(status.map(String.init) ?? "none")."
        }
    }
}

// MARK: - Response DTOs

struct ImagesEditsResponse: Decodable {
    struct Item: Decodable {
        let url: URL?
        let b64JSON: String?
        let revisedPrompt: String?

        enum CodingKeys: String, CodingKey {
            case url
            case b64JSON = "b64_json"
            case revisedPrompt = "revised_prompt"
        }
    }
    let created: Int?
    let data: [Item]
}

struct APIErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String
        let type: String?
        let code: String?
    }
    let error: Payload
}

// MARK: - Client

public actor InpaintingClient {

    private let configuration: InpaintingConfiguration
    private let session: URLSession

    public init(configuration: InpaintingConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.timeoutIntervalForRequest = configuration.timeout
            sessionConfig.timeoutIntervalForResource = configuration.timeout * 2
            sessionConfig.waitsForConnectivity = true
            self.session = URLSession(configuration: sessionConfig)
        }
    }

    /// Full round trip: source-space plate + mask in, source-space hallucinated
    /// plate out.
    ///
    /// - Parameters:
    ///   - plate: background with the subject punched out (transparent hole).
    ///   - mask: black RGB, alpha 0 over the hole. Must be the same pixel size
    ///           as `plate`.
    ///   - prompt: what should exist behind the subject.
    public func inpaint(
        plate: CGImage,
        mask: CGImage,
        prompt: String
    ) async throws -> CGImage {

        let canvas = SquareCanvas(sourceSize: plate.size, side: configuration.sideLadder[0])

        // --------------------------------------------------------------
        // Project both rasters into the square canvas.
        //
        // Plate pads with clamped edges: the model sees a plausible continuation
        // of the scene in the bars rather than a black frame.
        //
        // Mask pads with OPAQUE black: alpha 1 in the bars means "leave this
        // alone". Padding the mask with `.clear` instead would invite the model
        // to invent content in the letterbox, which we then crop off — wasted
        // compute and a visible seam where the invented region meets the frame.
        // --------------------------------------------------------------
        let squarePlate = try canvas.project(plate, pad: .clampEdges)
            .render(cropping: canvas.squareExtent)
        let squareMask = try canvas.project(mask, pad: .opaqueBlack)
            .render(cropping: canvas.squareExtent)

        // --------------------------------------------------------------
        // Encode under the byte budget.
        //
        // The plate keeps its alpha (the hole is meaningful to some backends).
        // Both files MUST end up the same pixel size, so whatever side the plate
        // settled on drives the mask encode — we never let them negotiate
        // independently.
        // --------------------------------------------------------------
        let (plateData, side) = try PNGEncoder.encodeSquare(
            squarePlate,
            ladder: configuration.sideLadder,
            maxBytes: configuration.maxBytesPerFile,
            preserveAlpha: true
        )
        let maskResized = try PNGEncoder.resizeSquare(squareMask, to: side)
        let maskData = try PNGEncoder.encode(maskResized, preserveAlpha: true)

        guard maskData.count <= configuration.maxBytesPerFile else {
            throw ImagingError.pngBudgetExceeded(
                bytes: maskData.count,
                budget: configuration.maxBytesPerFile
            )
        }

        let returned = try await send(
            plate: plateData,
            mask: maskData,
            prompt: prompt,
            side: side
        )

        // --------------------------------------------------------------
        // Restore the source aspect ratio: crop the letterbox off, resample to
        // the original pixel grid.
        // --------------------------------------------------------------
        return try canvas.unproject(returned, returnedSide: CGFloat(returned.width))
    }

    // MARK: - Transport

    private func send(
        plate: Data,
        mask: Data,
        prompt: String,
        side: Int
    ) async throws -> CGImage {

        var lastStatus: Int?

        for attempt in 0..<max(configuration.maxRetries, 1) {
            if attempt > 0 {
                // Exponential backoff with jitter: 0.8 s, 1.6 s, 3.2 s ± 25 %.
                let base = 0.8 * pow(2.0, Double(attempt - 1))
                let jitter = Double.random(in: 0.75...1.25)
                try await Task.sleep(nanoseconds: UInt64(base * jitter * 1_000_000_000))
            }

            try Task.checkCancellation()

            var form = MultipartFormData()
            form.append(name: "image", filename: "image.png", mimeType: "image/png", data: plate)
            form.append(name: "mask", filename: "mask.png", mimeType: "image/png", data: mask)
            form.append(name: "prompt", value: prompt)
            form.append(name: "model", value: configuration.model)
            form.append(name: "n", value: "1")
            form.append(name: "size", value: "\(side)x\(side)")
            let bodyData = form.finalize()

            var request = URLRequest(url: configuration.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
            for (key, value) in configuration.extraHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.timeoutInterval = configuration.timeout

            let data: Data
            let response: URLResponse
            do {
                // `upload(for:from:)` streams the body instead of holding a
                // second copy in the request object — worth it for a pair of
                // multi-megabyte PNGs on a headset's memory budget.
                (data, response) = try await session.upload(for: request, from: bodyData)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == configuration.maxRetries - 1 {
                    throw InpaintingError.transportFailure(underlying: error)
                }
                continue
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            lastStatus = status

            if (200..<300).contains(status) {
                return try await Self.decodeImage(from: data, session: session)
            }

            // 408/429/5xx are worth another go; 4xx otherwise is a permanent
            // client error and retrying just burns quota.
            let retryable = status == 408 || status == 429 || (500..<600).contains(status)
            if !retryable {
                throw InpaintingError.badResponse(
                    status: status,
                    message: Self.errorMessage(from: data)
                )
            }
        }

        throw InpaintingError.retriesExhausted(lastStatus: lastStatus)
    }

    // MARK: - Decoding

    /// Handles both response shapes: inline base64 (`b64_json`, the only option
    /// for the gpt-image family) and a short-lived CDN `url` (dall-e-2/3).
    private static func decodeImage(from data: Data, session: URLSession) async throws -> CGImage {
        let decoded = try JSONDecoder().decode(ImagesEditsResponse.self, from: data)
        guard let item = decoded.data.first else { throw InpaintingError.emptyPayload }

        if let b64 = item.b64JSON {
            // `.ignoreUnknownCharacters` tolerates line-wrapped base64, which
            // some gateways emit.
            guard let bytes = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) else {
                throw ImagingError.decodingFailed
            }
            return try ImageDecoder.cgImage(from: bytes)
        }

        if let url = item.url {
            let (bytes, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                throw InpaintingError.badResponse(status: status, message: "CDN fetch failed")
            }
            return try ImageDecoder.cgImage(from: bytes)
        }

        throw InpaintingError.emptyPayload
    }

    private static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        return String(data: data.prefix(512), encoding: .utf8) ?? "<unreadable body>"
    }
}
