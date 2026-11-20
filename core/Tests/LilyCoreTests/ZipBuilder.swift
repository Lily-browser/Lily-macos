import Foundation
@testable import LilyCore

/// Builds zip archives in memory (stored or deflated entries) for the extension reader tests.
/// A copy of the helper in LilyKit's tests: test code is not shared between packages.
struct ZipBuilder {
    struct Entry { var name: String; var data: Data; var deflate = true; var unixMode: UInt32 = 0o100644; var flags: UInt16 = 0; var crc: UInt32? = nil }
    var entries: [Entry] = []

    mutating func add(_ name: String, _ text: String, deflate: Bool = true) { entries.append(Entry(name: name, data: Data(text.utf8), deflate: deflate)) }

    func build() -> Data {
        var out = Data()
        var directory = Data()
        for entry in entries {
            let body = entry.deflate ? (try! (entry.data as NSData).compressed(using: .zlib) as Data) : entry.data
            let crc = entry.crc ?? CRC32.checksum(entry.data)
            let offset = UInt32(out.count)
            let name = Data(entry.name.utf8)
            let method: UInt16 = entry.deflate ? 8 : 0
            for part in [le32(0x0403_4b50), le16(20), le16(entry.flags), le16(method), le16(0), le16(0), le32(crc),
                         le32(UInt32(body.count)), le32(UInt32(entry.data.count)), le16(UInt16(name.count)), le16(0), name, body] {
                out.append(part)
            }
            for part in [le32(0x0201_4b50), le16(0x031E), le16(20), le16(entry.flags), le16(method), le16(0), le16(0), le32(crc),
                         le32(UInt32(body.count)), le32(UInt32(entry.data.count)), le16(UInt16(name.count)), le16(0), le16(0),
                         le16(0), le16(0), le32(entry.unixMode << 16), le32(offset), name] {
                directory.append(part)
            }
        }
        let directoryOffset = UInt32(out.count)
        out.append(directory)
        for part in [le32(0x0605_4b50), le16(0), le16(0), le16(UInt16(entries.count)), le16(UInt16(entries.count)),
                     le32(UInt32(directory.count)), le32(directoryOffset), le16(0)] {
            out.append(part)
        }
        return out
    }

    private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
}
