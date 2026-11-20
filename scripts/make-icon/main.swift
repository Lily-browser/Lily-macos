// Writes the default Lily app icon (AppIcon.icns) using the same drawing the app uses at runtime.
// bundle.sh compiles this file together with core/Sources/LilyCore/UI/AppIconArt.swift:
//   swiftc main.swift AppIconArt.swift -o make-icon && make-icon <out.icns>
// One image per pixel size: iconutil would also store "128@2x" and "256@2x", byte-for-byte
// copies of the 256 and 512 px images (about 220 KB); macOS picks an icon image by pixel size.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <out.icns>\n".utf8))
    exit(64)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])

// icns: "icns", total length, then (type, length including its 8-byte header, PNG) chunks, all
// lengths big-endian.
func bigEndian(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
let chunks: [(type: String, pixels: Int)] = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
                                             ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)]
var body = Data()
for chunk in chunks {
    let png = AppIconArt.png(pixels: chunk.pixels, variant: .iris, dark: false)
    body += Data(chunk.type.utf8) + bigEndian(png.count + 8) + png
}
try (Data("icns".utf8) + bigEndian(body.count + 8) + body).write(to: out)
