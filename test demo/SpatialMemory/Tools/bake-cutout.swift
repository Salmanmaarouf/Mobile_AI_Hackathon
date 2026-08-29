#!/usr/bin/env swift
//
//  bake-cutout.swift
//  SpatialMemory — bake a full-frame subject cutout on your Mac
//
//  WHY THIS EXISTS
//  VNGenerateForegroundInstanceMaskRequest has no CPU code path, so it cannot
//  run in any simulator. Your Mac has a GPU and Neural Engine, so it can. Run
//  this once per photo, drop the result into the app bundle, and the simulator
//  gets a real silhouette instead of the elliptical placeholder.
//
//  USAGE
//      swift Tools/bake-cutout.swift ~/Desktop/photo.jpg
//
//  Writes  photo-cutout.png  next to the input: the full frame at full size,
//  subject opaque, background transparent. That is exactly what
//  AlphaChannelMatteSource expects.
//
//  Add both files to the Xcode project as `sample.jpg` and `sample-cutout.png`
//  and the demo picks them up automatically.
//
//  REQUIRES  macOS 14+ (Apple silicon). No project, no dependencies.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import VideoToolbox

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("""
    usage: swift bake-cutout.swift <image> [output.png]

    Writes a full-frame subject cutout (subject opaque, background transparent).

    """.utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
let outputURL: URL = {
    if args.count >= 3 {
        return URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
    }
    let stem = inputURL.deletingPathExtension().lastPathComponent
    return inputURL.deletingLastPathComponent().appendingPathComponent("\(stem)-cutout.png")
}()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - Load

guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fail("could not read \(inputURL.path)")
}
print("in   \(inputURL.lastPathComponent)  \(image.width)×\(image.height)")

// MARK: - Segment
//
// This is the same call ForegroundSegmentationService makes. Note the parameter
// on the mask generator is `forInstances:from:` and the handler must stay alive
// across it — it re-enters the handler to resample against the original buffer.

let handler = VNImageRequestHandler(cgImage: image, options: [:])
let request = VNGenerateForegroundInstanceMaskRequest()

do {
    try handler.perform([request])
} catch {
    fail("""
    Vision failed: \(error.localizedDescription)
    If this says "Could not create inference context", the request could not reach the
    GPU/ANE. This needs macOS 14+ on Apple silicon.
    """)
}

guard let observation = request.results?.first,
      observation.allInstances.isEmpty == false else {
    fail("no salient foreground subject found in this image")
}

let instances = observation.allInstances
print("     \(instances.count) instance(s)")

// generateScaledMaskForImage gives the mask back at SOURCE resolution. The
// observation's own `instanceMask` is ~512 px on the long edge and stair-steps.
guard let maskBuffer = try? observation.generateScaledMaskForImage(
    forInstances: instances,
    from: handler
) else {
    fail("mask generation failed")
}

var maskCG: CGImage?
VTCreateCGImageFromCVPixelBuffer(maskBuffer, options: nil, imageOut: &maskCG)
guard let rawMask = maskCG else { fail("could not convert the mask buffer") }

// MARK: - Composite subject over transparency

let ctx = CIContext(options: [.cacheIntermediates: false])
let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)

// Splat the mask's red channel into every channel so the blend behaves the same
// whether it samples luminance or alpha.
let splat = CIFilter(name: "CIColorMatrix", parameters: [
    kCIInputImageKey: CIImage(cgImage: rawMask),
    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
    "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
    "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
    "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
])?.outputImage ?? CIImage(cgImage: rawMask)

// Force it onto the source pixel grid; the upsample can land a pixel short.
let maskExtent = splat.extent
let conformed = (maskExtent.width == extent.width && maskExtent.height == extent.height)
    ? splat
    : splat.transformed(by: CGAffineTransform(
        scaleX: extent.width / maskExtent.width,
        y: extent.height / maskExtent.height))

// Deliberately NO erode/feather here. The app applies its own matting chain to
// whatever this file contains, and feathering twice thins the silhouette.
let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
guard let cutout = CIFilter(name: "CIBlendWithMask", parameters: [
    kCIInputImageKey: CIImage(cgImage: image),
    kCIInputBackgroundImageKey: clear,
    kCIInputMaskImageKey: conformed
])?.outputImage?.cropped(to: extent) else {
    fail("compositing failed")
}

guard let outCG = ctx.createCGImage(
    cutout,
    from: extent,
    format: .RGBA8,
    colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
) else {
    fail("rasterization failed")
}

// MARK: - Write

guard let dest = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else {
    fail("could not create \(outputURL.path)")
}
CGImageDestinationAddImage(dest, outCG, nil)
guard CGImageDestinationFinalize(dest) else { fail("could not write the PNG") }

let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
let bytes = (attributes?[.size] as? Int) ?? 0
print("out  \(outputURL.lastPathComponent)  \(outCG.width)×\(outCG.height)  \(bytes) bytes")
print("""

Next: add both files to the Xcode project as `sample.jpg` and `sample-cutout.png`.
The demo calls MatteSourceFactory.bundledCutoutOrAutomatic(resource: "sample-cutout"),
which picks the cutout up automatically.
""")
