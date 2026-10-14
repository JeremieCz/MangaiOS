import CryptoKit
import Foundation
import SwiftData
import XCTest
import ZIPFoundation
@testable import MangaiOS

final class LibraryBackupTests: XCTestCase {
    private var workspace: URL!
    private var root: URL { workspace.appendingPathComponent("LocalContent", isDirectory: true) }
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=")!

    override func setUpWithError() throws {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        workspace = caches.appendingPathComponent("BackupTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let workspace { try FileManager.default.removeItem(at: workspace) }
    }

    @MainActor
    private func repository() throws -> SwiftDataLibraryRepository {
        try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(inMemory: true))
    }
    @MainActor
    private func service(limits: ImportLimits = ImportLimits(), capacity: Int64 = Int64.max) -> LibraryBackupService {
        LibraryBackupService(root: root, limits: limits, availableSpace: { _ in capacity })
    }

    private func write(_ path: String, _ bytes: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    @MainActor
    private func populate(_ repo: SwiftDataLibraryRepository) throws -> LibraryBackupSnapshot {
        var metadata = SeriesMetadata(title: "Série complète", authors: ["Auteur"], artists: ["Artiste"],
                                      summary: "Résumé", genres: ["Manga"], status: .completed, notes: "Note privée", rating: 8)
        let cover = LocalFileInput(path: try RelativePath("covers/one.png"), kind: .image, byteCount: Int64(png.count))
        try write(cover.path.value, png)
        let series = try repo.createSeries(NewSeries(sourceID: "local", sourceKey: "one", metadata: metadata,
                                                     favoriteAt: Date(timeIntervalSince1970: 1_700_000_000), cover: cover))
        metadata.title = "Hors bibliothèque"
        _ = try repo.createSeries(NewSeries(sourceID: "offline", sourceKey: "other", metadata: metadata))
        let inputs: [(String, Data, LocalFileKind)] = [
            ("imports/full/page.png", png, .image),
            ("imports/full/ComicInfo.xml", Data("<ComicInfo><Unknown>préservé</Unknown></ComicInfo>".utf8), .document),
            ("imports/full/manifest.json", Data("{\"original\":\"metadata\"}".utf8), .document),
            ("archives/original.cbz", Data([0, 1, 2, 3]), .archive)
        ]
        var files: [LocalFileInput] = []
        for (path, bytes, kind) in inputs {
            try write(path, bytes)
            files.append(LocalFileInput(path: try RelativePath(path), kind: kind, byteCount: Int64(bytes.count)))
        }
        let chapter = try repo.createChapter(NewChapter(seriesID: series.id, key: "chapitre", title: "Chapitre 1",
            number: 1.5, order: 7, files: files,
            pages: [LocalPageInput(fileID: files[0].id, width: 1, height: 1),
                    LocalPageInput(fileID: files[3].id, entryIndex: 4, width: 8, height: 12)]))
        try repo.recordReaderProgress(chapterID: chapter.id, pageIndex: 1, duration: 12.25,
                                      at: Date(timeIntervalSince1970: 1_700_100_000), completed: true)
        try repo.setBookmark(chapterID: chapter.id, isBookmarked: true)
        let first = try repo.createCategory(id: UUID(), name: "A")
        let second = try repo.createCategory(id: UUID(), name: "B")
        try repo.reorderCategories(ids: [second.id, first.id])
        try repo.setCategories(seriesID: series.id, categoryIDs: [first.id, second.id])
        try repo.setGlobalPreferences(ReadingPreferences(mode: .webtoon, doublePages: .enabled, isolateCover: false))
        try repo.setSeriesPreferences(seriesID: series.id, value: SeriesReadingPreferences(mode: .leftToRight,
                                                                                           doublePages: nil, isolateCover: true))
        try write("orphan/retained.xml", Data("fichier privé sans référence".utf8))
        try write("staging/unconfirmed/private.png", png)
        return try repo.exportSnapshot()
    }

    private func edited(_ value: LibraryBackupSnapshot, _ edit: (inout [String: Any]) throws -> Void) throws -> LibraryBackupSnapshot {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        try edit(&object)
        return try JSONDecoder().decode(LibraryBackupSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @MainActor
    func testRepositoryRoundTripPreservesAllDomainFieldsAndHistoryIdentity() throws {
        let repo = try repository()
        let original = try populate(repo)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LibraryBackupSnapshot.self, from: encoded)
        let generation = MutationGate.generation
        try repo.replaceSnapshot(decoded)
        XCTAssertNotEqual(MutationGate.generation, generation)
        XCTAssertEqual(try repo.exportSnapshot(), original)
        let history = try XCTUnwrap(original.series.flatMap(\.chapters).first?.history)
        XCTAssertEqual(try repo.history().first, history)
        try repo.replaceSnapshot(original)
        XCTAssertEqual(try repo.exportSnapshot(), original)
    }

    @MainActor
    func testEmptySnapshotRemovesEntireGraphAndPersistsAfterReopening() throws {
        let store = workspace.appendingPathComponent("empty.sqlite")
        var empty: LibraryBackupSnapshot!
        try autoreleasepool {
            let container = try StorageFactory.makeContainer(storeURL: store)
            let concrete = try SwiftDataLibraryRepository(container: container)
            empty = try concrete.exportSnapshot()
            _ = try populate(concrete)
            let repo: any LibraryRepository = concrete
            for _ in 0..<2 {
                try repo.replaceSnapshot(empty)
                XCTAssertEqual(try repo.exportSnapshot(), empty)
                let reloaded = try SwiftDataLibraryRepository(container: container)
                XCTAssertEqual(try reloaded.exportSnapshot(), empty)
            }
        }
        try autoreleasepool {
            let container = try StorageFactory.makeContainer(storeURL: store)
            let repo = try SwiftDataLibraryRepository(container: container)
            XCTAssertEqual(try repo.exportSnapshot(), empty)
            // Vérifier aussi les objets détachés, invisibles dans le snapshot.
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredSeries>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredChapter>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredFile>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredPage>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredHistory>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredSeriesPreferences>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredCategory>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredGlobalPreferences>()), 1)
        }
    }

    @MainActor
    func testMultipleSeriesAndChaptersRestoreTwiceWithReusedIDsAndPersist() throws {
        let store = workspace.appendingPathComponent("multiple.sqlite")
        var expected: LibraryBackupSnapshot!
        try autoreleasepool {
            let container = try StorageFactory.makeContainer(storeURL: store)
            let concrete = try SwiftDataLibraryRepository(container: container)
            let repo: any LibraryRepository = concrete
            try repo.setGlobalPreferences(ReadingPreferences(mode: .webtoon, doublePages: .enabled, isolateCover: false))
            for seriesIndex in 0..<2 {
                let category = try repo.createCategory(id: UUID(), name: "Catégorie \(seriesIndex)")
                let cover = LocalFileInput(path: try RelativePath("covers/\(seriesIndex).png"),
                                           kind: .image, byteCount: Int64(seriesIndex + 1))
                let series = try repo.createSeries(NewSeries(sourceKey: "série-\(seriesIndex)",
                    metadata: SeriesMetadata(title: "Série \(seriesIndex)", notes: "Note \(seriesIndex)"),
                    favoriteAt: Date(timeIntervalSince1970: Double(1_700_000_000 + seriesIndex)), cover: cover))
                try repo.setCategories(seriesID: series.id, categoryIDs: [category.id])
                try repo.setSeriesPreferences(seriesID: series.id, value: SeriesReadingPreferences(
                    mode: seriesIndex == 0 ? .leftToRight : .vertical,
                    doublePages: seriesIndex == 0 ? .automatic : .disabled, isolateCover: seriesIndex == 0))
                for chapterIndex in 0..<2 {
                    let value = seriesIndex * 2 + chapterIndex
                    let file = LocalFileInput(path: try RelativePath("chapters/\(seriesIndex)/\(chapterIndex).cbz"),
                                              kind: .archive, byteCount: Int64(100 + value))
                    let chapter = try repo.createChapter(NewChapter(seriesID: series.id, key: "chapitre-\(chapterIndex)",
                        title: "Chapitre \(value)", number: Double(value), order: chapterIndex, files: [file],
                        pages: [LocalPageInput(fileID: file.id, entryIndex: 0, width: 100 + value, height: 200),
                                LocalPageInput(fileID: file.id, entryIndex: 1, width: 200, height: 300 + value)]))
                    try repo.recordReaderProgress(chapterID: chapter.id, pageIndex: chapterIndex,
                        duration: Double(value) + 0.5, at: Date(timeIntervalSince1970: Double(1_700_100_000 + value)),
                        completed: chapterIndex == 1)
                    try repo.setBookmark(chapterID: chapter.id, isBookmarked: seriesIndex == chapterIndex)
                }
            }
            expected = try concrete.exportSnapshot()
            XCTAssertEqual(expected.series.count, 2)
            XCTAssertEqual(expected.series.flatMap(\.chapters).count, 4)
            // Les objets absents doivent disparaître sans supprimer les objets réutilisés.
            let extra = try repo.createSeries(NewSeries(sourceKey: "à supprimer", metadata: SeriesMetadata(title: "Ancienne")))
            _ = try repo.createChapter(NewChapter(seriesID: extra.id, key: "ancien", title: "Ancien", order: 0))
            _ = try repo.createCategory(id: UUID(), name: "Ancienne catégorie")
            for _ in 0..<2 {
                try repo.replaceSnapshot(expected)
                XCTAssertEqual(try concrete.exportSnapshot(), expected)
                let reloaded: any LibraryRepository = try SwiftDataLibraryRepository(container: container)
                XCTAssertEqual(try reloaded.exportSnapshot(), expected)
            }
        }
        try autoreleasepool {
            let container = try StorageFactory.makeContainer(storeURL: store)
            let repo: any LibraryRepository = try SwiftDataLibraryRepository(container: container)
            XCTAssertEqual(try repo.exportSnapshot(), expected)
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredSeries>()), 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredChapter>()), 4)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredFile>()), 6)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredPage>()), 8)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredHistory>()), 4)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredSeriesPreferences>()), 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredCategory>()), 3)
        }
    }

    @MainActor
    func testInvalidSnapshotsNeverMutateRepository() throws {
        let repo = try repository()
        let original = try populate(repo)
        let duplicate = LibraryBackupSnapshot(series: original.series + [original.series[0]],
                                               categories: original.categories, globalPreferences: original.globalPreferences)
        let missingCategory = LibraryBackupSnapshot(series: original.series,
                                                    categories: [], globalPreferences: original.globalPreferences)
        let invalidPage = try edited(original) { object in
            var series = try XCTUnwrap(object["series"] as? [[String: Any]])
            let index = try XCTUnwrap(series.firstIndex { ($0["chapters"] as? [Any])?.isEmpty == false })
            var chapters = try XCTUnwrap(series[index]["chapters"] as? [[String: Any]])
            var pages = try XCTUnwrap(chapters[0]["pages"] as? [[String: Any]])
            pages[0]["index"] = 9
            chapters[0]["pages"] = pages
            series[index]["chapters"] = chapters
            object["series"] = series
        }
        let orphanPage = try edited(original) { object in
            var series = try XCTUnwrap(object["series"] as? [[String: Any]])
            let index = try XCTUnwrap(series.firstIndex { ($0["chapters"] as? [Any])?.isEmpty == false })
            var chapters = try XCTUnwrap(series[index]["chapters"] as? [[String: Any]])
            var pages = try XCTUnwrap(chapters[0]["pages"] as? [[String: Any]])
            pages[0]["fileID"] = UUID().uuidString
            chapters[0]["pages"] = pages
            series[index]["chapters"] = chapters
            object["series"] = series
        }
        for value in [duplicate, missingCategory, invalidPage, orphanPage] {
            XCTAssertThrowsError(try repo.replaceSnapshot(value))
            XCTAssertEqual(try repo.exportSnapshot(), original)
        }
    }

    @MainActor
    func testArchiveRoundTripBytesAndSafetyCanRestorePreviousState() throws {
        let repo = try repository()
        let original = try populate(repo)
        let backup = service()
        let longPath = Array(repeating: String(repeating: "a", count: 200), count: 5).joined(separator: "/")
            + "/" + String(repeating: "b", count: 19)
        XCTAssertEqual(longPath.utf8.count, 1_024)
        try write(longPath, Data("chemin complet".utf8))
        let exported = try backup.export(repository: repo)
        let saved = try Data(contentsOf: exported)
        try repo.deleteSeries(id: original.series[0].id)
        try write("other/new.txt", Data("état précédent".utf8))
        let beforeRestore = try repo.exportSnapshot()
        let prepared = try backup.prepare(source: exported)
        XCTAssertEqual(prepared.manifest.snapshot, original)
        XCTAssertTrue(prepared.manifest.files.contains { $0.path.value == "orphan/retained.xml" })
        XCTAssertFalse(prepared.manifest.files.contains { $0.path.value.hasPrefix("staging/") })
        XCTAssertNil(try backup.restore(prepared, repository: repo))
        XCTAssertEqual(try repo.exportSnapshot(), original)
        for file in original.files {
            let bytes = try Data(contentsOf: root.appendingPathComponent(file.path.value))
            let record = try XCTUnwrap(prepared.manifest.files.first { $0.path == file.path })
            XCTAssertEqual(Int64(bytes.count), record.byteCount)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), record.sha256)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("other/new.txt").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(longPath)), Data("chemin complet".utf8))
        XCTAssertEqual(try Data(contentsOf: exported), saved)
        let safety = try XCTUnwrap(backup.safetyArchives().first)
        let undo = try backup.prepare(source: safety)
        XCTAssertNil(try backup.restore(undo, repository: repo))
        XCTAssertEqual(try repo.exportSnapshot(), beforeRestore)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("other/new.txt")), Data("état précédent".utf8))
        try backup.discardExport(exported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
    }

    private func archive(_ entries: [(String, Data, Entry.EntryType)]) throws -> URL {
        let url = workspace.appendingPathComponent("\(UUID()).zip")
        let zip = try Archive(url: url, accessMode: .create)
        for (path, data, type) in entries {
            try zip.addEntry(with: path, type: type, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
            }
        }
        return url
    }

    @MainActor
    private func entries(_ prepared: PreparedBackup) throws -> [(String, Data, Entry.EntryType)] {
        [("manifest.json", try JSONEncoder().encode(prepared.manifest), .file)]
            + (try prepared.manifest.files.map {
                ("content/" + $0.path.value, try Data(contentsOf: root.appendingPathComponent($0.path.value)), .file)
            })
    }

    @MainActor
    func testRejectsVersionsHashesMissingExtraDuplicatesTraversalAndSymlinks() throws {
        let repo = try repository()
        let original = try populate(repo)
        let backup = service()
        let exported = try backup.export(repository: repo)
        let prepared = try backup.prepare(source: exported)
        let valid = try entries(prepared)
        var badVersion = valid
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid[0].1) as? [String: Any])
        object["version"] = 99
        badVersion[0].1 = try JSONSerialization.data(withJSONObject: object)
        var badHash = valid
        badHash[1].1 = Data(repeating: 55, count: badHash[1].1.count)
        let fixtures = [
            badVersion, badHash, Array(valid.dropLast()),
            valid + [("unexpected", Data(), .file)],
            valid + [("manifest.json", valid[0].1, .file)],
            valid + [("MANIFEST.JSON", valid[0].1, .file)],
            valid + [("../outside", Data(), .file)],
            valid + [("content/link", Data("outside".utf8), .symlink)]
        ]
        for fixture in fixtures {
            let url = try archive(fixture)
            XCTAssertThrowsError(try backup.prepare(source: url))
            XCTAssertEqual(try repo.exportSnapshot(), original)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        try backup.discard(prepared)
        try backup.discardExport(exported)
    }

    @MainActor
    func testTruncatedCRCAndManifestQuotaRejected() throws {
        let repo = try repository()
        _ = try populate(repo)
        let backup = service()
        let exported = try backup.export(repository: repo)
        let bytes = try Data(contentsOf: exported)
        let truncated = workspace.appendingPathComponent("truncated.zip")
        try bytes.dropLast(12).write(to: truncated)
        XCTAssertThrowsError(try backup.prepare(source: truncated))
        var corrupt = bytes
        let nameLength = Int(corrupt[26]) | Int(corrupt[27]) << 8
        let extraLength = Int(corrupt[28]) | Int(corrupt[29]) << 8
        corrupt[30 + nameLength + extraLength] ^= 1
        let crc = workspace.appendingPathComponent("crc.zip")
        try corrupt.write(to: crc)
        XCTAssertThrowsError(try backup.prepare(source: crc))
        let huge = try archive([("manifest.json", Data(repeating: 32, count: backup.manifestBytes + 1), .file)])
        XCTAssertThrowsError(try backup.prepare(source: huge))
        try backup.discardExport(exported)
    }

    @MainActor
    func testDiskLimitsMissingContentAndLocalSymlinkLeaveDataIntact() throws {
        let repo = try repository()
        let snapshot = try populate(repo)
        XCTAssertThrowsError(try service(capacity: 0).export(repository: repo))
        var limits = ImportLimits()
        limits.totalBytes = 1
        XCTAssertThrowsError(try service(limits: limits).export(repository: repo))
        let target = root.appendingPathComponent(snapshot.files[0].path.value)
        let bytes = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try service().export(repository: repo))
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("evil"), withDestinationURL: workspace)
        XCTAssertThrowsError(try service().export(repository: repo))
        XCTAssertEqual(try repo.exportSnapshot(), snapshot)
    }

    @MainActor
    func testFailedDatabaseReplacementRecoversOldFilesAndKeepsSafety() throws {
        let base = try repository()
        _ = try populate(base)
        let backup = service()
        let exported = try backup.export(repository: base)
        let prepared = try backup.prepare(source: exported)
        let old = try base.createSeries(NewSeries(sourceKey: "survivor", metadata: SeriesMetadata(title: "Ancien")))
        try write("survivor.txt", Data("ancienne copie".utf8))
        let previous = try base.exportSnapshot()
        let failing = FailingImportRepository(base: base)
        failing.failNextReplacement = true
        XCTAssertThrowsError(try backup.restore(prepared, repository: failing))
        XCTAssertEqual(try base.exportSnapshot(), previous)
        XCTAssertEqual(try base.series(id: old.id).metadata.title, "Ancien")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("survivor.txt")), Data("ancienne copie".utf8))
        XCTAssertEqual(try backup.safetyArchives().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.workspace.appendingPathComponent("journal.json").path))
        try backup.discardExport(exported)
    }

    @MainActor
    func testCrashRecoveryAtEveryUncommittedCheckpointIsIdempotent() throws {
        for checkpoint in 0...4 {
            let repo = try repository()
            let old = try populate(repo)
            let backup = service()
            let id = UUID()
            let directory = backup.workspace.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let export = try backup.export(repository: repo)
            let checked = try backup.prepare(source: export)
            try JSONEncoder().encode(checked.manifest).write(to: directory.appendingPathComponent("previousManifest.json"))
            try backup.discard(checked)
            try FileManager.default.copyItem(at: export, to: directory.appendingPathComponent("Securite.zip"))
            try backup.discardExport(export)
            try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("previous.json"), options: .atomic)
            let journal = LibraryBackupService.Journal(id: id, rootExisted: true,
                                                      phase: checkpoint == 4 ? .recovering : .pending)
            try JSONEncoder().encode(journal).write(to: backup.workspace.appendingPathComponent("journal.json"), options: .atomic)
            if checkpoint >= 1 { try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("old")) }
            if checkpoint >= 2 {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try write("new-only.txt", Data("nouveau".utf8))
            }
            if checkpoint >= 3 {
                try repo.replaceSnapshot(LibraryBackupSnapshot(series: [],
                    categories: [CategorySnapshot(id: LibraryIdentity.uncategorizedID, name: "Sans catégorie",
                                                 order: 0, isSystem: true, seriesIDs: [])],
                    globalPreferences: ReadingPreferences()))
            }
            if checkpoint == 4 {
                // Interruption après le rollback du dépôt et des fichiers,
                // avant suppression du journal recovering.
                try repo.replaceSnapshot(old)
                try FileManager.default.removeItem(at: root)
                try FileManager.default.moveItem(at: directory.appendingPathComponent("old"), to: root)
            }
            try backup.recover(repository: repo)
            try backup.recover(repository: repo)
            XCTAssertEqual(try repo.exportSnapshot(), old)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("covers/one.png")), png)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new-only.txt").path))
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    @MainActor
    func testCommittedJournalNeverRollsBackSuccessfulRestore() throws {
        let repo = try repository()
        let old = try populate(repo)
        let backup = service()
        let id = UUID()
        let directory = backup.workspace.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("previous.json"))
        try JSONEncoder().encode(LibraryBackupService.Journal(id: id, rootExisted: true, phase: .committed))
            .write(to: backup.workspace.appendingPathComponent("journal.json"))
        try repo.deleteSeries(id: old.series[0].id)
        let committed = try repo.exportSnapshot()
        try backup.recover(repository: repo)
        XCTAssertEqual(try repo.exportSnapshot(), committed)
    }

    @MainActor
    func testCancellationAndWriterGateDoNotMutate() throws {
        let repo = try repository()
        let snapshot = try populate(repo)
        let backup = service()
        let exported = try backup.export(repository: repo)
        let prepared = try backup.prepare(source: exported)
        try backup.discard(prepared)
        XCTAssertThrowsError(try backup.restore(prepared, repository: repo))
        let lease = UUID()
        try MutationGate.beginImport(lease, root: root)
        XCTAssertThrowsError(try backup.export(repository: repo))
        MutationGate.endImport(lease)
        try MutationGate.withExclusive(root: root) {
            XCTAssertThrowsError(try repo.setGlobalPreferences(ReadingPreferences()))
            XCTAssertThrowsError(try repo.deleteSeries(id: snapshot.series[0].id))
            XCTAssertThrowsError(try repo.replaceSnapshot(snapshot))
        }
        MutationGate.requireRecovery()
        defer { MutationGate.recoveryFinished() }
        XCTAssertThrowsError(try repo.setBookmark(chapterID: snapshot.series.flatMap(\.chapters)[0].id,
                                                 isBookmarked: false))
        MutationGate.recoveryFinished()
        XCTAssertEqual(try repo.exportSnapshot(), snapshot)
        try backup.discardExport(exported)
    }

    @MainActor
    func testReplacementFromIndependentLibraryWithSameIdentityKeys() throws {
        let first = try repository()
        let original = try populate(first)
        let second = try repository()
        let previous = try populate(second)
        XCTAssertNotEqual(original.series.map(\.id), previous.series.map(\.id))
        try second.replaceSnapshot(original)
        XCTAssertEqual(try second.exportSnapshot(), original)
        try second.replaceSnapshot(previous)
        XCTAssertEqual(try second.exportSnapshot(), previous)
    }

    @MainActor
    func testDiskRestoreReopensWithExactSnapshotAndHistoryUUID() throws {
        let store = workspace.appendingPathComponent("library.store")
        var expected: LibraryBackupSnapshot!
        var export: URL!
        try autoreleasepool {
            let repo = try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(storeURL: store))
            expected = try populate(repo)
            export = try service().export(repository: repo)
        }
        try autoreleasepool {
            let repo = try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(storeURL: store))
            XCTAssertEqual(try repo.exportSnapshot(), expected)
            for item in expected.series { try repo.deleteSeries(id: item.id) }
            let backup = service()
            let value = try backup.prepare(source: export)
            XCTAssertNil(try backup.restore(value, repository: repo))
        }
        try autoreleasepool {
            let repo = try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(storeURL: store))
            XCTAssertEqual(try repo.exportSnapshot(), expected)
        }
    }

    @MainActor
    func testViewModelPreviewCancelAndExportCompletionLifecycle() throws {
        let repo = try repository()
        let original = try populate(repo)
        let backup = service()
        let model = LibraryBackupViewModel(service: backup)
        model.export(repository: repo)
        let export = try XCTUnwrap(model.document?.url)
        model.select(export)
        XCTAssertEqual(model.prepared?.manifest.snapshot, original)
        XCTAssertFalse(model.busy)
        model.cancel()
        XCTAssertNil(model.prepared)
        XCTAssertEqual(try repo.exportSnapshot(), original)
        model.exportFinished(.failure(CocoaError(.userCancelled)))
        XCTAssertNil(model.document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertNotNil(model.message)
        model.export(repository: repo)
        let success = try XCTUnwrap(model.document?.url)
        model.exportFinished(.success(workspace.appendingPathComponent("external-export.zip")))
        XCTAssertEqual(model.message, "Sauvegarde exportée.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: success.path))
    }

    @MainActor
    func testCancelledPreparationAndAbandonedArtifactsAreCleanedAtStartup() async throws {
        let repo = try repository()
        let original = try populate(repo)
        let backup = service()
        let export = try backup.export(repository: repo)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try backup.prepare(source: export)
        }
        do { _ = try await task.value; XCTFail("Préparation annulée acceptée") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try repo.exportSnapshot(), original)
        let abandoned = try backup.prepare(source: export)
        let path = backup.workspace.appendingPathComponent(abandoned.id.uuidString)
        let restarted = service()
        XCTAssertNil(try restarted.recover(repository: repo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try repo.exportSnapshot(), original)
    }

    @MainActor
    func testRestoreDiskFailureBeforeJournalKeepsRepositoryFilesAndPreparation() throws {
        let repo = try repository()
        let original = try populate(repo)
        var capacity = Int64.max
        let backup = LibraryBackupService(root: root, availableSpace: { _ in capacity })
        let export = try backup.export(repository: repo)
        let prepared = try backup.prepare(source: export)
        capacity = 0
        XCTAssertThrowsError(try backup.restore(prepared, repository: repo))
        XCTAssertTrue(backup.isPrepared(prepared))
        XCTAssertEqual(try repo.exportSnapshot(), original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("covers/one.png")), png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.workspace.appendingPathComponent("journal.json").path))
        try backup.discard(prepared)
        try backup.discardExport(export)
    }

    @MainActor
    func testCorruptRecoveryPreimageBlocksWithoutMutatingGoodData() throws {
        let repo = try repository()
        let original = try populate(repo)
        let backup = service()
        let export = try backup.export(repository: repo)
        let prepared = try backup.prepare(source: export)
        let directory = backup.workspace.appendingPathComponent(prepared.id.uuidString)
        try JSONEncoder().encode(original).write(to: directory.appendingPathComponent("previous.json"))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared.manifest)) as? [String: Any])
        manifest["version"] = 99
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("previousManifest.json"))
        try JSONEncoder().encode(LibraryBackupService.Journal(id: prepared.id, rootExisted: true, phase: .pending))
            .write(to: backup.workspace.appendingPathComponent("journal.json"))
        XCTAssertThrowsError(try backup.recover(repository: repo))
        XCTAssertEqual(try repo.exportSnapshot(), original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("covers/one.png")), png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.workspace.appendingPathComponent("journal.json").path))
    }

    @MainActor
    func testRecoveryRestoresOriginallyAbsentRoot() throws {
        let repo = try repository()
        let previous = try repo.exportSnapshot()
        try FileManager.default.removeItem(at: root)
        let backup = service()
        let export = try backup.export(repository: repo)
        let prepared = try backup.prepare(source: export)
        let directory = backup.workspace.appendingPathComponent(prepared.id.uuidString)
        try JSONEncoder().encode(previous).write(to: directory.appendingPathComponent("previous.json"))
        try JSONEncoder().encode(prepared.manifest).write(to: directory.appendingPathComponent("previousManifest.json"))
        try FileManager.default.copyItem(at: export, to: directory.appendingPathComponent("Securite.zip"))
        try JSONEncoder().encode(LibraryBackupService.Journal(id: prepared.id, rootExisted: false, phase: .pending))
            .write(to: backup.workspace.appendingPathComponent("journal.json"))
        _ = try repo.createSeries(NewSeries(sourceKey: "new", metadata: SeriesMetadata(title: "Nouveau")))
        try write("new.txt", Data("nouveau".utf8))
        let restarted = service()
        XCTAssertNil(try restarted.recover(repository: repo))
        XCTAssertEqual(try repo.exportSnapshot(), previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try restarted.safetyArchives().count, 1)
    }
}
