#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.argc == 3 || CommandLine.argc == 4 else {
    fputs("usage: GenerateAppIcon.swift <input.png> <output.png> [side]\n", stderr)
    exit(1)
}
let inURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])
let side = CommandLine.argc == 4 ? Int(CommandLine.arguments[3]) ?? 1024 : 1024

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
else {
    fputs("failed to read input\n", stderr)
    exit(2)
}

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fputs("no sRGB\n", stderr)
    exit(3)
}

// Premultiplied RGBA — avoids channel-order quirks from byteOrder32* flags.
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

guard let ctx = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fputs("failed to create context\n", stderr)
    exit(4)
}

// Match logo background (powder blue).
ctx.setFillColor(red: 222 / 255, green: 232 / 255, blue: 245 / 255, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

let iw = CGFloat(image.width)
let ih = CGFloat(image.height)
let inner = CGFloat(side) * 0.90
let scale = min(inner / iw, inner / ih)
let nw = iw * scale
let nh = ih * scale
let x = (CGFloat(side) - nw) / 2
let y = (CGFloat(side) - nh) / 2

ctx.interpolationQuality = .high
ctx.saveGState()
// Flip to UIKit-style top-left so the PNG matches `icon.png` orientation.
ctx.translateBy(x: 0, y: CGFloat(side))
ctx.scaleBy(x: 1, y: -1)
let drawRect = CGRect(x: x, y: CGFloat(side) - y - nh, width: nw, height: nh)
ctx.draw(image, in: drawRect)
ctx.restoreGState()

guard let outImage = ctx.makeImage() else {
    fputs("failed to make image\n", stderr)
    exit(5)
}

guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    fputs("failed to create destination\n", stderr)
    exit(6)
}
CGImageDestinationAddImage(dest, outImage, nil)
guard CGImageDestinationFinalize(dest) else {
    fputs("failed to write png\n", stderr)
    exit(7)
}
