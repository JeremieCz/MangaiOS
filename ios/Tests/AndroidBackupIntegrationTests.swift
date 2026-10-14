import Foundation
import SwiftData
import XCTest
import zlib
@testable import MangaiOS

final class AndroidBackupIntegrationTests: XCTestCase {
    private var workspace: URL!
    private var root: URL { workspace.appendingPathComponent("private", isDirectory: true) }
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=")!

    override func setUpWithError() throws {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        workspace = caches.appendingPathComponent("AndroidTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let workspace { try FileManager.default.removeItem(at: workspace) }
    }
    @MainActor
    private func repository() throws -> SwiftDataLibraryRepository {
        try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(inMemory: true))
    }
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = workspace.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    private func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AndroidBackupError.invalid
        }
        defer { deflateEnd(&stream) }
        var result = Data()
        var output = [UInt8](repeating: 0, count: 32_768)
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            while true {
                let status = output.withUnsafeMutableBytes { buffer -> Int32 in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(buffer.count)
                    return deflate(&stream, Z_FINISH)
                }
                result.append(contentsOf: output.prefix(output.count - Int(stream.avail_out)))
                if status == Z_STREAM_END { break }
                guard status == Z_OK else { throw AndroidBackupError.invalid }
            }
        }
        return result
    }
    func testRawAndGzipParityAndUnchangedOriginal() throws {
        let raw = AndroidBackupDecoderTests.golden
        let gzipBytes = try gzip(raw)
        let rawURL = try write("raw.protobuf", raw)
        let gzipURL = try write("archive.tachibk", gzipBytes)
        XCTAssertEqual(try AndroidBackupFile.read(rawURL), raw)
        XCTAssertEqual(try AndroidBackupFile.read(gzipURL), raw)
        XCTAssertEqual(try Data(contentsOf: gzipURL), gzipBytes)
        XCTAssertEqual(try AndroidBackupDecoder.decode(AndroidBackupFile.read(gzipURL)).series[0].source, -1)
    }
    func testTruncatedBadCRCTrailingAndConcatenatedGzipRejected() throws {
        let compressed = try gzip(AndroidBackupDecoderTests.golden)
        var corrupt = compressed
        corrupt[corrupt.count - 8] ^= 0xff
        for (index, bytes) in [Data(compressed.dropLast()), corrupt, compressed + Data([0]), compressed + compressed].enumerated() {
            XCTAssertThrowsError(try AndroidBackupFile.read(write("bad-\(index).tachibk", bytes)))
        }
    }
    func testGzipBombRawQuotaAndSymlinkRejected() throws {
        let bomb = try write("bomb.tachibk", gzip(Data(repeating: 0, count: 2 * 1_024 * 1_024)))
        XCTAssertThrowsError(try AndroidBackupFile.read(bomb))
        let large = try write("large.protobuf", Data(repeating: 0, count: 16 * 1_024 * 1_024 + 1))
        XCTAssertThrowsError(try AndroidBackupFile.read(large))
        let link = workspace.appendingPathComponent("link.tachibk")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bomb)
        XCTAssertThrowsError(try AndroidBackupFile.read(link))
    }
    @MainActor
    func testCommitMergePreservesUnrelatedIDsMetadataAndDuplicateDoesNotInstall() throws {
        let repo = try repository()
        let original = try repo.createSeries(NewSeries(sourceKey: "existing",
            metadata: SeriesMetadata(title: "Personnel", notes: "Mes notes", rating: 9)))
        let backup = try AndroidBackupDecoder.decode(AndroidBackupDecoderTests.golden)
        try AndroidBackupCommitter.commit(backup, root: root, repository: repo)
        XCTAssertEqual(try repo.series(id: original.id), original)
        let snapshot = try repo.exportSnapshot()
        let imported = try XCTUnwrap(snapshot.series.first(where: { $0.sourceID == "android:-1" }))
        XCTAssertTrue(imported.chapters[0].pages.isEmpty)
        XCTAssertTrue(imported.chapters[0].isRead)
        XCTAssertTrue(imported.chapters[0].isBookmarked)
        XCTAssertNil(imported.chapters[0].lastPageIndex)
        let document = try XCTUnwrap(imported.chapters[0].files.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(document.path.value).path))
        let directories = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("android").path)
        XCTAssertThrowsError(try AndroidBackupCommitter.commit(backup, root: root, repository: repo))
        XCTAssertEqual(try repo.exportSnapshot(), snapshot)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("android").path), directories)
    }
    @MainActor
    func testMergeTransactionRollsBackSeriesWhenFileIdentityFails() throws {
        let repo = try repository()
        let file = LocalFileInput(path: try RelativePath("existing/document.json"), kind: .document)
        _ = try repo.createSeries(NewSeries(sourceKey: "existing", metadata: SeriesMetadata(title: "Personnel"), cover: file))
        let baseline = try repo.exportSnapshot()
        let backup = try AndroidBackupDecoder.decode(AndroidBackupDecoderTests.golden)
        let plan = try AndroidLibraryMerge.plan(backup, baseline: baseline, importID: UUID(), includeReaderModes: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan.snapshot)) as? [String: Any])
        var series = try XCTUnwrap(object["series"] as? [[String: Any]])
        var chapters = try XCTUnwrap(series[1]["chapters"] as? [[String: Any]])
        var files = try XCTUnwrap(chapters[0]["files"] as? [[String: Any]])
        files[0]["path"] = file.path.value
        chapters[0]["files"] = files
        series[1]["chapters"] = chapters
        object["series"] = series
        let invalidForRepository = try JSONDecoder().decode(LibraryBackupSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        try invalidForRepository.validate() // chemin partagé admis en sauvegarde ; interdit pour un nouvel import
        XCTAssertThrowsError(try repo.commitAndroidMerge(invalidForRepository))
        XCTAssertEqual(try repo.exportSnapshot(), baseline)
    }
    @MainActor
    func testMutationGateAndPrivateDirectorySymlinkBlockWithoutMutation() throws {
        let repo = try repository()
        let baseline = try repo.exportSnapshot()
        let backup = try AndroidBackupDecoder.decode(AndroidBackupDecoderTests.golden)
        try MutationGate.withExclusive(root: root) {
            XCTAssertThrowsError(try AndroidBackupCommitter.commit(backup, root: root, repository: repo))
        }
        let elsewhere = workspace.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("android"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try AndroidBackupCommitter.commit(backup, root: root, repository: repo))
        XCTAssertEqual(try repo.exportSnapshot(), baseline)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
    @MainActor
    func testExplicitAttachmentPreservesUserStateAndBackupRestoresSidecar() async throws {
        let repo = try repository()
        let backup = try AndroidBackupDecoder.decode(AndroidBackupDecoderTests.golden)
        try AndroidBackupCommitter.commit(backup, root: root, repository: repo)
        let imported = try XCTUnwrap(repo.allSeries(inLibraryOnly: false).first)
        let originalChapter = try XCTUnwrap(imported.chapters.first)
        let originalDocument = originalChapter.files[0]
        var metadata = imported.metadata
        metadata.title = "Titre personnel"
        metadata.notes = "Notes personnelles"
        try repo.updateSeries(id: imported.id, metadata: metadata)
        try repo.setRead(chapterID: originalChapter.id, isRead: false)
        try repo.setBookmark(chapterID: originalChapter.id, isBookmarked: false)
        let source = workspace.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try png.write(to: source.appendingPathComponent("1.png"))
        let importer = LocalImportService(root: root, availableSpace: { _ in Int64.max })
        let prepared = try await importer.prepare(source: source)
        let saved = try await ImportCommitter.commit(prepared, target: .existingAndroidChapter(originalChapter.id),
                                                     repository: repo, service: importer)
        XCTAssertEqual(saved.id, originalChapter.id)
        XCTAssertEqual(saved.key, originalChapter.key)
        XCTAssertEqual(saved.title, originalChapter.title)
        XCTAssertEqual(saved.pageCount, 1)
        XCTAssertEqual(saved.lastPageIndex, 0)
        XCTAssertFalse(saved.isRead)
        XCTAssertFalse(saved.isBookmarked)
        XCTAssertTrue(saved.files.contains(originalDocument))
        XCTAssertEqual(try repo.series(id: imported.id).metadata, metadata)
        XCTAssertEqual(try repo.series(id: imported.id).chapters.count, 1)
        let pendingData = try Data(contentsOf: root.appendingPathComponent(originalDocument.path.value))
        let backupService = LibraryBackupService(root: root, availableSpace: { _ in Int64.max })
        let archive = try backupService.export(repository: repo)
        let restoration = try backupService.prepare(source: archive)
        _ = try backupService.restore(restoration, repository: repo)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(originalDocument.path.value)), pendingData)
        XCTAssertEqual(try repo.chapter(id: originalChapter.id).pageCount, 1)
    }
}
