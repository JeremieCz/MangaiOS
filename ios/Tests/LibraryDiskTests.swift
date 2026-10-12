import Foundation
import SwiftData
import XCTest
@testable import MangaiOS

final class LibraryDiskTests: XCTestCase {
    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaiOS-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    func testDiskReopenPreservesDomainAndNeverDeletesPhysicalFiles() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("library.store")
        let physicalFile = directory.appendingPathComponent("page.jpg")
        try Data("fixture locale".utf8).write(to: physicalFile)
        let seriesID = UUID()
        let chapterID = UUID()
        let categoryID = UUID()
        let fileID = UUID()
        let pageID = UUID()
        let date = Date(timeIntervalSince1970: 1_000)
        try autoreleasepool {
            let repo = try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(storeURL: storeURL))
            _ = try repo.createSeries(NewSeries(
                id: seriesID, sourceKey: "exemple", metadata: SeriesMetadata(title: "Exemple"), favoriteAt: date
            ))
            _ = try repo.createCategory(id: categoryID, name: "Locale")
            try repo.setCategories(seriesID: seriesID, categoryIDs: [categoryID])
            _ = try repo.createChapter(NewChapter(
                id: chapterID, seriesID: seriesID, key: "1", title: "Chapitre", order: 0,
                files: [LocalFileInput(id: fileID, path: RelativePath("page.jpg"), kind: .image)],
                pages: [LocalPageInput(id: pageID, fileID: fileID)]
            ))
            try repo.setGlobalPreferences(ReadingPreferences(mode: .webtoon))
            try repo.setSeriesPreferences(seriesID: seriesID, value: SeriesReadingPreferences(doublePages: .enabled))
            try repo.setBookmark(chapterID: chapterID, isBookmarked: true)
            try repo.recordProgress(chapterID: chapterID, pageIndex: 0, duration: 12, at: date)
        }
        try autoreleasepool {
            let repo = try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(storeURL: storeURL))
            let series = try repo.series(id: seriesID)
            XCTAssertEqual(series.favoriteAt, date)
            XCTAssertEqual(series.categoryIDs, [categoryID])
            XCTAssertEqual(series.chapters.first?.id, chapterID)
            XCTAssertEqual(series.chapters.first?.pages.first?.id, pageID)
            XCTAssertEqual(series.chapters.first?.files.first?.id, fileID)
            XCTAssertEqual(series.chapters.first?.history?.duration, 12)
            XCTAssertEqual(series.chapters.first?.history?.lastReadAt, date)
            XCTAssertTrue(try repo.chapter(id: chapterID).isRead)
            XCTAssertTrue(try repo.chapter(id: chapterID).isBookmarked)
            XCTAssertEqual(
                try repo.resolvedPreferences(seriesID: seriesID),
                ReadingPreferences(mode: .webtoon, doublePages: .enabled)
            )
            XCTAssertEqual(try repo.categories()[1].seriesIDs, [seriesID])
            try repo.deleteSeries(id: seriesID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: physicalFile.path))
        }
        try autoreleasepool {
            let repo = try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(storeURL: storeURL))
            XCTAssertEqual(try repo.allSeries().count, 0)
            XCTAssertEqual(try repo.history().count, 0)
            XCTAssertEqual(try repo.categories().count, 2)
        }
    }

    @MainActor
    func testLightweightMigrationFromUnmodifiedV1() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("migration.store")
        let originalDate = Date(timeIntervalSince1970: 456)
        try autoreleasepool {
            let schema = Schema(versionedSchema: StorageSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(StorageMetadata(createdAt: originalDate))
            try context.save()
        }
        let seriesID = UUID()
        try autoreleasepool {
            let container = try StorageFactory.makeContainer(storeURL: storeURL)
            let context = ModelContext(container)
            let metadata = try context.fetch(FetchDescriptor<StorageMetadata>())
            XCTAssertEqual(metadata.count, 1)
            XCTAssertEqual(metadata.first?.key, "application")
            XCTAssertEqual(metadata.first?.createdAt, originalDate)
            let repo = try SwiftDataLibraryRepository(container: container)
            XCTAssertEqual(try repo.allSeries().count, 0)
            XCTAssertEqual(try repo.categories().map(\.id), [LibraryIdentity.uncategorizedID])
            _ = try repo.createSeries(NewSeries(
                id: seriesID, sourceKey: "après migration", metadata: SeriesMetadata(title: "Exemple")
            ))
        }
        try autoreleasepool {
            let container = try StorageFactory.makeContainer(storeURL: storeURL)
            let repo = try SwiftDataLibraryRepository(container: container)
            XCTAssertEqual(try repo.series(id: seriesID).id, seriesID)
            XCTAssertEqual(try repo.categories().count, 1)
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<StorageMetadata>()).first?.createdAt, originalDate)
        }
    }
}
