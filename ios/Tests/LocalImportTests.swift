import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import XCTest
import ZIPFoundation
@testable import MangaiOS

final class LocalImportTests: XCTestCase {
    private var workspace: URL!
    private var source: URL { workspace.appendingPathComponent("source", isDirectory: true) }
    private var privateRoot: URL { workspace.appendingPathComponent("private", isDirectory: true) }

    override func setUpWithError() throws {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        workspace = caches.appendingPathComponent("ImportTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try FileManager.default.removeItem(at: workspace) }
    }

    private func image(_ path: String = "1.png") throws -> URL {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func archive(_ entries: [(String, Data, Entry.EntryType)], name: String = "volume.cbz") throws -> URL {
        let url = workspace.appendingPathComponent(name)
        let zip = try Archive(url: url, accessMode: .create)
        for (path, data, type) in entries {
            try zip.addEntry(with: path, type: type, uncompressedSize: Int64(data.count),
                             modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                             compressionMethod: type == .file ? .deflate : .none) { position, size in
                data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
            }
        }
        return url
    }

    private func service(_ limits: ImportLimits = ImportLimits(), capacity: Int64 = Int64.max) -> LocalImportService {
        LocalImportService(root: privateRoot, limits: limits, availableSpace: { _ in capacity })
    }

    private func stage(_ prepared: PreparedImport) -> URL {
        privateRoot.appendingPathComponent("staging/\(prepared.id.uuidString)")
    }

    private func assertNoStages(file: StaticString = #filePath, line: UInt = #line) throws {
        let staging = privateRoot.appendingPathComponent("staging")
        if FileManager.default.fileExists(atPath: staging.path) {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty, file: file, line: line)
        }
    }

    private func expectRejection(_ url: URL, importer: LocalImportService? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await (importer ?? service()).prepare(source: url)
            XCTFail("Import dangereux accepté", file: file, line: line)
        } catch {
            XCTAssertFalse(error is CancellationError, file: file, line: line)
        }
        try assertNoStages(file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file: file, line: line)
    }

    func testDirectoryNestedNaturalOrderAndPrivateCopy() async throws {
        for name in ["10.png", "2.png", "01.png", "9.png", "001.png", "1.png", "09.png", "11.png"] {
            _ = try image("nested/\(name)")
        }
        _ = try image(".hidden.png")
        _ = try image("__MACOSX/metadata.png")
        let importer = service()
        let prepared = try await importer.prepare(source: source)
        XCTAssertEqual(prepared.manifest.pages.map(\.originalPath),
                       ["001.png", "01.png", "1.png", "2.png", "09.png", "9.png", "10.png", "11.png"].map { "nested/" + $0 })
        XCTAssertEqual(prepared.manifest.pages.map(\.index), Array(0..<8))
        XCTAssertEqual(prepared.manifest.pages.first?.width, 2)
        XCTAssertEqual(prepared.manifest.pages.first?.height, 3)
        let copied = stage(prepared).appendingPathComponent(prepared.manifest.pages[0].filename)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: source.appendingPathComponent("nested/001.png")))
        try await importer.discard(prepared)
        try assertNoStages()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("nested/001.png").path))
    }

    func testZIPAndCBZPreserveXMLBytesAndStableContentFingerprint() async throws {
        let data = try Data(contentsOf: image())
        let xml = Data("""
        <ComicInfo xmlns:ty="http://www.w3.org/2001/XMLSchema" xmlns:mh="http://www.w3.org/2001/XMLSchema">
        <Series>Test</Series><Title>Chapitre</Title><Number>2</Number>
        <ty:PublishingStatusTachiyomi>Licensed</ty:PublishingStatusTachiyomi>
        <mh:SourceMihon>javascript:neverExecute()</mh:SourceMihon><Unmapped>Valeur brute</Unmapped>
        </ComicInfo>

        """.utf8)
        let cbz = try archive([("2.png", data, .file), ("ComicInfo.xml", xml, .file)])
        let zip = try archive([("ComicInfo.xml", xml, .file), ("2.png", data, .file)], name: "volume.zip")
        let importer = service()
        let first = try await importer.prepare(source: cbz)
        let second = try await importer.prepare(source: zip)
        XCTAssertEqual(first.manifest.fingerprint, second.manifest.fingerprint)
        XCTAssertEqual(first.manifest.metadata.series.title, "Test")
        XCTAssertEqual(first.manifest.metadata.number, 2)
        XCTAssertEqual(first.manifest.metadata.series.status, .unknown)
        XCTAssertEqual(first.manifest.metadata.source, "javascript:neverExecute()")
        XCTAssertEqual(first.manifest.metadata.warnings.count, 1)
        XCTAssertEqual(try Data(contentsOf: stage(first).appendingPathComponent("ComicInfo.xml")), xml)
        let persisted = try JSONDecoder().decode(ImportManifest.self,
            from: Data(contentsOf: stage(first).appendingPathComponent("manifest.json")))
        XCTAssertEqual(persisted.fingerprint, first.manifest.fingerprint)
        XCTAssertEqual(persisted.metadata, first.manifest.metadata)
        try await importer.discard(first)
        try await importer.discard(second)
        try assertNoStages()
    }

    func testRejectsEmptyFolderArchiveAndUnsupportedFiles() async throws {
        try await expectRejection(source)
        let empty = try archive([])
        try await expectRejection(empty)
        _ = try image()
        try Data("not supported".utf8).write(to: source.appendingPathComponent("extra.pdf"))
        try await expectRejection(source)
    }

    func testRejectsInvalidImagesInFolderAndArchive() async throws {
        try Data("not an image".utf8).write(to: source.appendingPathComponent("1.png"))
        try await expectRejection(source)
        let zip = try archive([("1.png", Data("bad".utf8), .file)])
        try await expectRejection(zip)
    }

    func testRejectsSymlinksIncludingHiddenAndZIP() async throws {
        let url = try image()
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent(".link"), withDestinationURL: url)
        try await expectRejection(source)
        let zip = try archive([("1.png", try Data(contentsOf: url), .file), ("link", Data("../outside".utf8), .symlink)])
        try await expectRejection(zip)
    }

    func testRejectsTraversalAndNormalizedDuplicateZIPPaths() async throws {
        let data = try Data(contentsOf: image())
        for (index, names) in [["../escape.png"], ["/absolute.png"], ["a\\b.png"],
                               ["1.png", "1.png"], ["É.png", "E\u{301}.PNG"]].enumerated() {
            let zip = try archive(names.map { ($0, data, .file) }, name: "unsafe\(index).zip")
            try await expectRejection(zip)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escape.png").path))
    }

    func testRejectsLowDiskFileTotalPagePixelXMLAndEntryLimits() async throws {
        _ = try image()
        try await expectRejection(source, importer: service(capacity: 1))
        var limits = ImportLimits()
        limits.fileBytes = 1
        try await expectRejection(source, importer: service(limits))
        limits = ImportLimits()
        limits.totalBytes = 1
        try await expectRejection(source, importer: service(limits))
        limits = ImportLimits()
        limits.pixels = 5
        try await expectRejection(source, importer: service(limits))
        _ = try image("2.png")
        limits = ImportLimits()
        limits.pages = 1
        try await expectRejection(source, importer: service(limits))
        limits = ImportLimits()
        limits.entries = 1
        try await expectRejection(source, importer: service(limits))
        try Data("<ComicInfo/>".utf8).write(to: source.appendingPathComponent("ComicInfo.xml"))
        limits = ImportLimits()
        limits.xmlBytes = 1
        try await expectRejection(source, importer: service(limits))
        let data = try Data(contentsOf: source.appendingPathComponent("1.png"))
        let zip = try archive([("1.png", data, .file), ("2.png", data, .file)])
        limits = ImportLimits()
        limits.archiveBytes = 1
        try await expectRejection(zip, importer: service(limits))
        limits = ImportLimits()
        limits.fileBytes = 1
        try await expectRejection(zip, importer: service(limits))
        limits = ImportLimits()
        limits.totalBytes = 1
        try await expectRejection(zip, importer: service(limits))
        limits = ImportLimits()
        limits.entries = 1
        try await expectRejection(zip, importer: service(limits))
        limits = ImportLimits()
        limits.pages = 1
        try await expectRejection(zip, importer: service(limits))
    }

    func testRejectsEncryptedTruncatedAndBadCRCZIP() async throws {
        let data = try Data(contentsOf: image())
        let original = try archive([("1.png", data, .file)])
        let bytes = try Data(contentsOf: original)
        let central = try XCTUnwrap((0..<(bytes.count - 4)).first {
            bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4b && bytes[$0 + 2] == 0x01 && bytes[$0 + 3] == 0x02
        })
        var encrypted = bytes
        encrypted[6] |= 1
        encrypted[central + 8] |= 1
        let encryptedURL = workspace.appendingPathComponent("encrypted.zip")
        try encrypted.write(to: encryptedURL)
        try await expectRejection(encryptedURL)
        var crc = bytes
        crc[central + 16] ^= 0xff
        crc[14] ^= 0xff
        let badCRC = workspace.appendingPathComponent("badCRC.zip")
        try crc.write(to: badCRC)
        try await expectRejection(badCRC)
        let truncated = workspace.appendingPathComponent("truncated.zip")
        try bytes.dropLast().write(to: truncated)
        try await expectRejection(truncated)
        let hidden = try archive([(".metadata", Data([42]), .file), ("1.png", data, .file)], name: "hidden.zip")
        var hiddenBytes = try Data(contentsOf: hidden)
        let hiddenCentral = try XCTUnwrap((0..<(hiddenBytes.count - 4)).first {
            hiddenBytes[$0] == 0x50 && hiddenBytes[$0 + 1] == 0x4b
                && hiddenBytes[$0 + 2] == 0x01 && hiddenBytes[$0 + 3] == 0x02
        })
        hiddenBytes[hiddenCentral + 16] ^= 0xff
        hiddenBytes[14] ^= 0xff
        try hiddenBytes.write(to: hidden)
        try await expectRejection(hidden)
    }

    func testRejectsXXEAndMultipleComicInfoWithoutLeavingCopies() async throws {
        let data = try Data(contentsOf: image())
        let xxe = try archive([("1.png", data, .file),
            ("ComicInfo.xml", Data("<!DOCTYPE ComicInfo SYSTEM 'file:///nonexistent'><ComicInfo/>".utf8), .file)])
        try await expectRejection(xxe)
        let multiple = try archive([("1.png", data, .file),
            ("ComicInfo.xml", Data("<ComicInfo/>".utf8), .file),
            ("nested/ComicInfo.xml", Data("<ComicInfo/>".utf8), .file)], name: "multiple.zip")
        try await expectRejection(multiple)
    }

    func testCancellationBeforePreparationAndAfterStagingCleansUp() async throws {
        _ = try image()
        let importer = service()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await importer.prepare(source: source)
        }
        do { _ = try await task.value; XCTFail("Annulation ignorée") }
        catch { XCTAssertTrue(error is CancellationError) }
        try assertNoStages()
        let prepared = try await importer.prepare(source: source)
        try await importer.discard(prepared)
        try await importer.discard(prepared)
        try assertNoStages()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("1.png").path))
    }

    func testCancellationDuringStreamingRemovesPartialFiles() async throws {
        _ = try image()
        let importer = service()
        let task = Task {
            try await importer.prepare(source: source) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await task.value; XCTFail("Annulation du flux ignorée") }
        catch { XCTAssertTrue(error is CancellationError) }
        try assertNoStages()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("1.png").path))
    }

    func testStagedWriteFailureIsReportedAndCleaned() async throws {
        _ = try image()
        let blocked = privateRoot.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        try Data([42]).write(to: blocked)
        do { _ = try await service().prepare(source: source); XCTFail("Écriture impossible acceptée") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: blocked), Data([42]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("1.png").path))
    }

    func testRenameConflictLeavesStagingRecoverableWithoutOverwriting() async throws {
        _ = try image()
        let importer = service()
        let prepared = try await importer.prepare(source: source)
        let final = privateRoot.appendingPathComponent("imports/\(prepared.id.uuidString)")
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        let marker = final.appendingPathComponent("untouched")
        try Data([42]).write(to: marker)
        do { try await importer.install(prepared); XCTFail("Écrasement autorisé") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage(prepared).path))
        XCTAssertEqual(try Data(contentsOf: marker), Data([42]))
        try await importer.discard(prepared)
        try assertNoStages()
    }

    @MainActor
    func testCommitNewThenExistingPreservesMetadataAndProgressAndRefusesDuplicate() async throws {
        _ = try image()
        let repository = try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(inMemory: true))
        let importer = service()
        let first = try await importer.prepare(source: source)
        let chosen = SeriesMetadata(title: "Titre choisi", authors: ["Moi"], notes: "Ne pas écraser")
        let chapter = try await ImportCommitter.commit(first, target: .newSeries(chosen),
                                                       repository: repository, service: importer)
        XCTAssertEqual(chapter.pages.map(\.index), [0])
        XCTAssertEqual(chapter.files.filter { $0.kind == .image }.count, 1)
        let series = try repository.series(id: chapter.seriesID)
        XCTAssertEqual(series.metadata, chosen)
        let category = try repository.createCategory(name: "Choisie")
        try repository.setCategories(seriesID: series.id, categoryIDs: [category.id])
        try repository.setSeriesPreferences(seriesID: series.id, value: SeriesReadingPreferences(mode: .vertical))
        try repository.recordProgress(chapterID: chapter.id, pageIndex: 0, duration: 12, at: Date())
        try repository.setBookmark(chapterID: chapter.id, isBookmarked: true)
        let originalProgress = try repository.chapter(id: chapter.id)
        let duplicate = try await importer.prepare(source: source)
        do {
            _ = try await ImportCommitter.commit(duplicate, target: .existingSeries(series.id),
                                                 repository: repository, service: importer)
            XCTFail("Doublon non refusé")
        } catch {
            XCTAssertTrue(error is DomainError)
        }
        let copy = try await ImportCommitter.commit(duplicate, target: .existingSeries(series.id), allowDuplicate: true,
                                                    repository: repository, service: importer)
        XCTAssertNotEqual(copy.id, chapter.id)
        XCTAssertNotEqual(copy.key, chapter.key)
        XCTAssertEqual(copy.order, 1)
        XCTAssertFalse(copy.isRead)
        XCTAssertEqual(try repository.chapter(id: chapter.id), originalProgress)
        XCTAssertEqual(try repository.series(id: series.id).metadata, chosen)
        XCTAssertEqual(try repository.series(id: series.id).categoryIDs, [category.id])
        XCTAssertEqual(try repository.series(id: series.id).preferences.mode, .vertical)
        XCTAssertEqual(try repository.series(id: series.id).favoriteAt, series.favoriteAt)
        let newDuplicate = try await importer.prepare(source: source)
        do {
            _ = try await ImportCommitter.commit(newDuplicate, target: .newSeries(chosen),
                                                 repository: repository, service: importer)
            XCTFail("Doublon de nouvelle série accepté")
        } catch { XCTAssertTrue(error is DomainError) }
        let separateSeriesChapter = try await ImportCommitter.commit(newDuplicate, target: .newSeries(chosen),
            allowDuplicate: true, repository: repository, service: importer)
        XCTAssertNotEqual(separateSeriesChapter.seriesID, series.id)
        XCTAssertEqual(try repository.allSeries(inLibraryOnly: false).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("1.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateRoot.appendingPathComponent(
            chapter.files.first!.path.value).path))
        try assertNoStages()
    }

    @MainActor
    func testAtomicRepositoryRollbackOnChapterConflict() throws {
        let repository = try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(inMemory: true))
        let first = try repository.createSeries(NewSeries(sourceKey: "old", metadata: SeriesMetadata(title: "Old")))
        let file = LocalFileInput(path: try RelativePath("old/page.png"), kind: .image)
        _ = try repository.createChapter(NewChapter(seriesID: first.id, key: "1", title: "Old", order: 0, files: [file]))
        let new = NewSeries(sourceKey: "new", metadata: SeriesMetadata(title: "New"))
        let conflict = NewChapter(seriesID: new.id, key: "1", title: "New", order: 0, files: [file])
        XCTAssertThrowsError(try repository.commitImport(series: new, chapter: conflict))
        XCTAssertEqual(try repository.allSeries(inLibraryOnly: false).map(\.id), [first.id])
        XCTAssertThrowsError(try repository.series(id: new.id))
        XCTAssertThrowsError(try repository.chapter(id: conflict.id))
        var covered = new
        covered.cover = LocalFileInput(path: try RelativePath("new/cover.png"), kind: .image)
        let coverConflict = NewChapter(seriesID: covered.id, key: "cover", title: "Cover", order: 0,
                                       files: [covered.cover!])
        XCTAssertThrowsError(try repository.commitImport(series: covered, chapter: coverConflict))
        XCTAssertThrowsError(try repository.series(id: covered.id))
        let valid = NewChapter(seriesID: new.id, key: "ok", title: "New", order: 0)
        _ = try repository.commitImport(series: new, chapter: valid)
        XCTAssertEqual(try repository.series(id: new.id).chapters.map(\.id), [valid.id])
    }

    @MainActor
    func testDatabaseFailureRemovesInstalledFilesButNeverSources() async throws {
        _ = try image()
        let underlying = try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(inMemory: true))
        let repository = FailingImportRepository(base: underlying)
        let importer = service()
        let prepared = try await importer.prepare(source: source)
        do {
            _ = try await ImportCommitter.commit(prepared, target: .newSeries(SeriesMetadata(title: "Test")),
                                                 repository: repository, service: importer)
            XCTFail("Échec base ignoré")
        } catch { XCTAssertTrue(error is DomainError) }
        XCTAssertTrue(try underlying.allSeries(inLibraryOnly: false).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            privateRoot.appendingPathComponent("imports/\(prepared.id.uuidString)").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("1.png").path))
        try assertNoStages()
    }

    @MainActor
    func testCancellationAfterSaveNeverDeletesCommittedFiles() async throws {
        _ = try image()
        let underlying = try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(inMemory: true))
        let repository = FailingImportRepository(base: underlying, cancelAfterSave: true)
        let importer = service()
        let prepared = try await importer.prepare(source: source)
        let task = Task { @MainActor in
            try await ImportCommitter.commit(prepared, target: .newSeries(SeriesMetadata(title: "Saved")),
                                             repository: repository, service: importer)
        }
        let saved = try await task.value
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(try underlying.chapter(id: saved.id), saved)
        for file in saved.files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: privateRoot.appendingPathComponent(file.path.value).path))
        }
        try assertNoStages()
    }
}

@MainActor
private final class FailingImportRepository: LibraryRepository {
    let base: SwiftDataLibraryRepository
    let cancelAfterSave: Bool
    init(base: SwiftDataLibraryRepository, cancelAfterSave: Bool = false) {
        self.base = base
        self.cancelAfterSave = cancelAfterSave
    }
    func commitImport(series: NewSeries?, chapter: NewChapter) throws -> ChapterSnapshot {
        if cancelAfterSave {
            let saved = try base.commitImport(series: series, chapter: chapter)
            withUnsafeCurrentTask { $0?.cancel() }
            return saved
        }
        throw DomainError.invalidValue("échec de sauvegarde simulé")
    }
    func series(id: UUID) throws -> SeriesSnapshot { try base.series(id: id) }
    func allSeries(inLibraryOnly: Bool) throws -> [SeriesSnapshot] { try base.allSeries(inLibraryOnly: inLibraryOnly) }
    func createSeries(_ input: NewSeries) throws -> SeriesSnapshot { try base.createSeries(input) }
    func updateSeries(id: UUID, metadata: SeriesMetadata) throws { try base.updateSeries(id: id, metadata: metadata) }
    func setFavorite(id: UUID, at date: Date?) throws { try base.setFavorite(id: id, at: date) }
    func deleteSeries(id: UUID) throws { try base.deleteSeries(id: id) }
    func createChapter(_ input: NewChapter) throws -> ChapterSnapshot { try base.createChapter(input) }
    func chapter(id: UUID) throws -> ChapterSnapshot { try base.chapter(id: id) }
    func deleteChapter(id: UUID) throws { try base.deleteChapter(id: id) }
    func setRead(chapterID: UUID, isRead: Bool) throws { try base.setRead(chapterID: chapterID, isRead: isRead) }
    func setBookmark(chapterID: UUID, isBookmarked: Bool) throws { try base.setBookmark(chapterID: chapterID, isBookmarked: isBookmarked) }
    func recordProgress(chapterID: UUID, pageIndex: Int, duration: TimeInterval, at date: Date) throws {
        try base.recordProgress(chapterID: chapterID, pageIndex: pageIndex, duration: duration, at: date)
    }
    func categories() throws -> [CategorySnapshot] { try base.categories() }
    func createCategory(id: UUID, name: String) throws -> CategorySnapshot { try base.createCategory(id: id, name: name) }
    func renameCategory(id: UUID, name: String) throws { try base.renameCategory(id: id, name: name) }
    func reorderCategories(ids: [UUID]) throws { try base.reorderCategories(ids: ids) }
    func deleteCategory(id: UUID) throws { try base.deleteCategory(id: id) }
    func setCategories(seriesID: UUID, categoryIDs: [UUID]) throws { try base.setCategories(seriesID: seriesID, categoryIDs: categoryIDs) }
    func globalPreferences() throws -> ReadingPreferences { try base.globalPreferences() }
    func setGlobalPreferences(_ value: ReadingPreferences) throws { try base.setGlobalPreferences(value) }
    func setSeriesPreferences(seriesID: UUID, value: SeriesReadingPreferences) throws { try base.setSeriesPreferences(seriesID: seriesID, value: value) }
    func resolvedPreferences(seriesID: UUID) throws -> ReadingPreferences { try base.resolvedPreferences(seriesID: seriesID) }
    func history() throws -> [HistorySnapshot] { try base.history() }
}
