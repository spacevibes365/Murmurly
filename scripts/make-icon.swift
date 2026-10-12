import AppKit
import CoreGraphics
import Foundation

// Draws the Murmurly app icon: two separate waveform tracks, the project's
// defining property — microphone and system audio are never mixed into one lane.

let size: CGFloat = 1024

func makeContext() -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let ctx = makeContext()

// macOS icons sit in a squircle with breathing room around it.
let inset: CGFloat = size * 0.055
let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = plate.width * 0.2237

ctx.saveGState()
ctx.addPath(squircle(plate, radius: radius))
ctx.clip()
let bg = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.07, green: 0.10, blue: 0.22, alpha: 1),
        CGColor(red: 0.10, green: 0.18, blue: 0.42, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bg,
    start: CGPoint(x: plate.minX, y: plate.maxY),
    end: CGPoint(x: plate.maxX, y: plate.minY),
    options: []
)
ctx.restoreGState()

// Two lanes. The upper one is the voice (bright), the lower one the call
// (blue): different sources, deliberately never merged.
struct Lane {
    let centerY: CGFloat
    let color: CGColor
    let heights: [CGFloat]
}

let voice = CGColor(red: 0.96, green: 0.97, blue: 1.0, alpha: 1)
let system = CGColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)

// Seven bars per lane, not twelve: the icon has to survive being 32 points wide
// in the Dock, where thin strokes collapse into a smudge.
let lanes = [
    Lane(centerY: size * 0.655, color: voice,
         heights: [0.30, 0.66, 1.0, 0.52, 0.86, 0.38, 0.62]),
    Lane(centerY: size * 0.345, color: system,
         heights: [0.52, 0.28, 0.74, 1.0, 0.40, 0.82, 0.34]),
]

let barCount = 7
let barWidth = size * 0.076
let gap = size * 0.042
let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
let startX = (size - totalWidth) / 2
let maxHalf = size * 0.125

for lane in lanes {
    ctx.setFillColor(lane.color)
    for (index, factor) in lane.heights.enumerated() {
        let half = max(maxHalf * factor, barWidth / 2)
        let rect = CGRect(
            x: startX + CGFloat(index) * (barWidth + gap),
            y: lane.centerY - half,
            width: barWidth,
            height: half * 2
        )
        ctx.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil
        ))
        ctx.fillPath()
    }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil
)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("written: \(out)")
