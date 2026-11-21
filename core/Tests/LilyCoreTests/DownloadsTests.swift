import Foundation
import Testing
@testable import LilyCore

@Suite struct DownloadsTests {
    @Test func progressFractionHandlesUnknownSizes() {
        var item = DownloadManager.Item(filename: "a.zip")
        #expect(item.fraction == nil)
        item.totalBytes = 200
        item.receivedBytes = 50
        #expect(item.fraction == 0.25)
        item.receivedBytes = 500
        #expect(item.fraction == 1)
    }

    @Test func collidingNamesGetNumbered() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("report.pdf"))
        try Data().write(to: dir.appendingPathComponent("report 2.pdf"))
        try Data().write(to: dir.appendingPathComponent("README"))
        #expect(DownloadManager.uniqueURL(in: dir, name: "report.pdf").lastPathComponent == "report 3.pdf")
        #expect(DownloadManager.uniqueURL(in: dir, name: "README").lastPathComponent == "README 2")
        #expect(DownloadManager.uniqueURL(in: dir, name: "new.txt").lastPathComponent == "new.txt")
    }

    @Test func runningDownloadsOfTheSameNameGetDifferentPartialFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-dl-\(UUID().uuidString)")
        let first = DownloadManager.uniqueURL(in: dir, name: "app.dmg.download")
        let second = DownloadManager.uniqueURL(in: dir, name: "app.dmg.download", reserved: [first])
        let third = DownloadManager.uniqueURL(in: dir, name: "app.dmg.download", reserved: [first, second])
        #expect(first.lastPathComponent == "app.dmg.download")
        #expect(second.lastPathComponent == "app.dmg 2.download" && third.lastPathComponent == "app.dmg 3.download")
        // Nothing but the final name ends in the real extension while a download runs.
        #expect(![first, second, third].contains { $0.pathExtension == "dmg" })
    }
}
