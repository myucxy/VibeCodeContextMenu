import AppKit
import Foundation

// 将 Windows .ico 目录高保真转换为 macOS PNG 图标以及 AppIcon.icns
// 用法: icon_convert <ico_dir> <out_png_dir> <out_icns_path>

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: icon_convert <ico_dir> <out_png_dir> <out_icns_path>\n", stderr)
    exit(1)
}

let icoDir = URL(fileURLWithPath: CommandLine.arguments[1])
let outPngDir = URL(fileURLWithPath: CommandLine.arguments[2])
let outIcnsPath = URL(fileURLWithPath: CommandLine.arguments[3])

let fm = FileManager.default
try fm.createDirectory(at: outPngDir, withIntermediateDirectories: true)

func renderPNG(from image: NSImage, size: Int, to destination: URL) throws {
    let targetSize = NSSize(width: size, height: size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconConvert", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap"])
    }

    rep.size = targetSize
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: targetSize).fill()

    // 挑选原始 ICO 中像素最大的 representation，避免放大低清 16x16 图层
    var bestRep: NSImageRep?
    var bestPixels = 0
    for candidate in image.representations {
        let pixels = max(candidate.pixelsWide, candidate.pixelsHigh)
        if pixels > bestPixels {
            bestPixels = pixels
            bestRep = candidate
        }
    }

    if let best = bestRep {
        best.draw(in: NSRect(origin: .zero, size: targetSize))
    } else {
        image.draw(in: NSRect(origin: .zero, size: targetSize))
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconConvert", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try pngData.write(to: destination)
}

let entries = try fm.contentsOfDirectory(at: icoDir, includingPropertiesForKeys: nil)
let icoFiles = entries.filter { $0.pathExtension.lowercased() == "ico" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

for icoURL in icoFiles {
    guard let image = NSImage(contentsOf: icoURL) else {
        fputs("Warning: could not load \(icoURL.lastPathComponent)\n", stderr)
        continue
    }
    let stem = icoURL.deletingPathExtension().lastPathComponent
    let outPNG = outPngDir.appendingPathComponent("\(stem).png")
    try renderPNG(from: image, size: 64, to: outPNG)
    print("  [OK] \(icoURL.lastPathComponent) -> \(outPNG.lastPathComponent)")

    if stem.lowercased() == "vibecode" {
        // 生成 macOS 应用图标 AppIcon.icns
        let tempDir = fm.temporaryDirectory.appendingPathComponent("vibecode-iconset-\(UUID().uuidString)")
        let iconsetDir = tempDir.appendingPathComponent("AppIcon.iconset")
        try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let specs: [(String, Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        for (name, px) in specs {
            try renderPNG(from: image, size: px, to: iconsetDir.appendingPathComponent(name))
        }

        try fm.createDirectory(at: outIcnsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outIcnsPath.path]
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(domain: "IconConvert", code: 3, userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
        }
        print("  [OK] vibecode.ico -> \(outIcnsPath.lastPathComponent)")
    }
}
