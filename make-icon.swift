import AppKit

let iconsetPath = "/tmp/DICTATR.iconset"
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

try? FileManager.default.removeItem(atPath: iconsetPath)
try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

// Required icon sizes for macOS .iconset
let specs: [(name: String, px: Int)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x",1024),
]

for spec in specs {
    let size = CGFloat(spec.px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Dark rounded-rect background
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.2
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).setFill()
    path.fill()

    // Draw emoji centered
    let emoji = "🎙️"
    let fontSize = size * 0.65
    let font = NSFont.systemFont(ofSize: fontSize)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let textSize = emoji.size(withAttributes: attrs)
    let point = NSPoint(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2
    )
    emoji.draw(at: point, withAttributes: attrs)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to render \(spec.name)")
        continue
    }

    let filePath = "\(iconsetPath)/\(spec.name).png"
    try png.write(to: URL(fileURLWithPath: filePath))
}

// Convert .iconset to .icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath, "-o", outputPath]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Created \(outputPath)")
} else {
    print("iconutil failed with status \(process.terminationStatus)")
}

// Clean up
try? FileManager.default.removeItem(atPath: iconsetPath)
