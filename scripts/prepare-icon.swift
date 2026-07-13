#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
  fputs("Usage: prepare-icon.swift <input.png> <output.png>\n", stderr)
  exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard
  let source = NSImage(contentsOf: inputURL),
  let sourceImage = source.cgImage(
    forProposedRect: nil,
    context: nil,
    hints: nil
  )
else {
  fputs("Could not read input image.\n", stderr)
  exit(1)
}

let width = sourceImage.width
let height = sourceImage.height
let bytesPerRow = width * 4
let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
pixels.initialize(repeating: 0, count: bytesPerRow * height)
defer { pixels.deallocate() }

let bitmapInfo =
  CGBitmapInfo.byteOrder32Big.rawValue
  | CGImageAlphaInfo.premultipliedLast.rawValue
guard
  width > 0,
  height > 0,
  let context = CGContext(
    data: pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: bitmapInfo
  )
else {
  fputs("Could not create output bitmap.\n", stderr)
  exit(1)
}

context.interpolationQuality = .high
context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))

let pixelCount = width * height
var visited = [Bool](repeating: false, count: pixelCount)
var queue = [Int]()
queue.reserveCapacity(pixelCount / 3)

func byteOffset(for pixelIndex: Int) -> Int {
  let y = pixelIndex / width
  let x = pixelIndex % width
  return y * bytesPerRow + x * 4
}

func whiteDistance(at pixelIndex: Int) -> Double {
  let offset = byteOffset(for: pixelIndex)
  let red = Double(pixels[offset])
  let green = Double(pixels[offset + 1])
  let blue = Double(pixels[offset + 2])
  let dr = 255 - red
  let dg = 255 - green
  let db = 255 - blue
  return (dr * dr + dg * dg + db * db).squareRoot()
}

func isExteriorCandidate(_ pixelIndex: Int) -> Bool {
  let offset = byteOffset(for: pixelIndex)
  let red = Int(pixels[offset])
  let green = Int(pixels[offset + 1])
  let blue = Int(pixels[offset + 2])
  let chroma = max(red, green, blue) - min(red, green, blue)
  return chroma < 70 && whiteDistance(at: pixelIndex) < 315
}

func enqueue(_ pixelIndex: Int) {
  guard !visited[pixelIndex], isExteriorCandidate(pixelIndex) else { return }
  visited[pixelIndex] = true
  queue.append(pixelIndex)
}

for x in 0..<width {
  enqueue(x)
  enqueue((height - 1) * width + x)
}
for y in 0..<height {
  enqueue(y * width)
  enqueue(y * width + width - 1)
}

var cursor = 0
while cursor < queue.count {
  let pixelIndex = queue[cursor]
  cursor += 1
  let x = pixelIndex % width
  let y = pixelIndex / width

  if x > 0 { enqueue(pixelIndex - 1) }
  if x + 1 < width { enqueue(pixelIndex + 1) }
  if y > 0 { enqueue(pixelIndex - width) }
  if y + 1 < height { enqueue(pixelIndex + width) }
}

for pixelIndex in queue {
  let offset = byteOffset(for: pixelIndex)
  let distance = whiteDistance(at: pixelIndex)
  let opacity = min(max((distance - 2) / 180, 0), 1)

  if opacity == 0 {
    pixels[offset] = 0
    pixels[offset + 1] = 0
    pixels[offset + 2] = 0
  } else if opacity < 1 {
    for component in 0..<3 {
      let composited = Double(pixels[offset + component]) / 255
      let foreground = (composited - (1 - opacity)) / opacity
      pixels[offset + component] = UInt8(
        min(max((foreground * opacity * 255).rounded(), 0), 255)
      )
    }
  }
  pixels[offset + 3] = UInt8((opacity * 255).rounded())
}

// Remove isolated generation noise outside the icon's intended macOS squircle.
// The edge is feathered so downscaled icon sizes remain clean.
let centerX = Double(width) / 2
let centerY = Double(height) / 2
let radiusX = centerX - 14
let radiusY = centerY - 14
for y in 0..<height {
  for x in 0..<width {
    let normalizedX = abs(Double(x) + 0.5 - centerX) / radiusX
    let normalizedY = abs(Double(y) + 0.5 - centerY) / radiusY
    let squircleDistance = pow(normalizedX, 5) + pow(normalizedY, 5)
    let maskOpacity = min(max((1 - squircleDistance) / 0.018, 0), 1)
    guard maskOpacity < 1 else { continue }

    let offset = y * bytesPerRow + x * 4
    for component in 0..<4 {
      pixels[offset + component] = UInt8(
        (Double(pixels[offset + component]) * maskOpacity).rounded()
      )
    }
  }
}

guard
  let outputImage = context.makeImage(),
  let png = NSBitmapImageRep(cgImage: outputImage)
    .representation(using: .png, properties: [:])
else {
  fputs("Could not encode output PNG.\n", stderr)
  exit(1)
}

do {
  try png.write(to: outputURL, options: .atomic)
} catch {
  fputs("Could not write output image: \(error.localizedDescription)\n", stderr)
  exit(1)
}
