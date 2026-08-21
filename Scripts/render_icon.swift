#!/usr/bin/env swift
// Draws the 1024px master icon: a rounded teal tile with a microphone on it.
// Run through make_icon.sh, which handles the sizes and the .icns packing.

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let side: CGFloat = 1024

let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    FileHandle.standardError.write(Data("no graphics context\n".utf8))
    exit(1)
}

// Rounded tile, in the proportions macOS uses for app icons.
let inset = side * 0.085
let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let tile = NSBezierPath(roundedRect: rect, xRadius: side * 0.2237, yRadius: side * 0.2237)

context.saveGState()
tile.addClip()

let colors = [
    NSColor(calibratedRed: 0.16, green: 0.62, blue: 0.62, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.09, green: 0.36, blue: 0.47, alpha: 1).cgColor,
]
if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])
{
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: [])
}

// A soft highlight across the top so the tile does not read as flat.
context.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
context.fillEllipse(
    in: CGRect(x: rect.minX - side * 0.2, y: rect.midY, width: rect.width * 1.4, height: rect.height))
context.restoreGState()

// Microphone: a capsule, an arc under it, and a stem.
let centerX = side / 2
let white = NSColor.white.withAlphaComponent(0.97)
white.setFill()
white.setStroke()

let capsuleWidth = side * 0.20
let capsuleHeight = side * 0.40
let capsule = NSBezierPath(
    roundedRect: CGRect(
        x: centerX - capsuleWidth / 2,
        y: side * 0.42,
        width: capsuleWidth,
        height: capsuleHeight),
    xRadius: capsuleWidth / 2,
    yRadius: capsuleWidth / 2)
capsule.fill()

let arc = NSBezierPath()
arc.lineWidth = side * 0.055
arc.lineCapStyle = .round
arc.appendArc(
    withCenter: CGPoint(x: centerX, y: side * 0.455),
    radius: side * 0.175,
    startAngle: 200,
    endAngle: 340,
    clockwise: false)
arc.stroke()

let stem = NSBezierPath()
stem.lineWidth = side * 0.055
stem.lineCapStyle = .round
stem.move(to: CGPoint(x: centerX, y: side * 0.285))
stem.line(to: CGPoint(x: centerX, y: side * 0.215))
stem.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("could not encode the icon\n".utf8))
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("    wrote \(outputPath)")
