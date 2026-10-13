import Foundation
import SwiftData
import XCTest
@testable import MangaiOS

final class LibraryRepositoryTests: XCTestCase {
    @MainActor
    func testReaderPartialLastPagePersistsWithoutMarkingRead() throws {
        let repo = try repository()
        let series = try repo.createSeries(seriesInput())
        let chapter = try repo.createChapter(chapterInput(seriesID: series.id))
        try repo.recordReaderProgress(chapterID: chapter.id, pageIndex: 2, duration: 4,
                                      at: Date(), completed: false)
        XCTAssertFalse(try repo.chapter(id: chapter.id).isRead)
        XCTAssertEqual(try repo.chapter(id: chapter.id).lastPageIndex, 2)
        try repo.recordReaderProgress(chapterID: chapter.id, pageIndex: 2, duration: 2,
                                      at: Date(), completed: true)
        XCTAssertTrue(try repo.chapter(id: chapter.id).isRead)
        try repo.recordReaderProgress(chapterID: chapter.id, pageIndex: 0, duration: 1,
                                      at: Date(), completed: false)
        XCTAssertTrue(try repo.chapter(id: chapter.id).isRead)
        XCTAssertEqual(try repo.chapter(id: chapter.id).history?.duration, 7)
    }
    @MainActor
    private func repository() throws -> SwiftDataLibraryRepository {
        try SwiftDataLibraryRepository(container: StorageFactory.makeContainer(inMemory: true))
    }

    private func seriesInput(id: UUID = UUID(), key: String = "exemple") -> NewSeries {
        NewSeries(id: id, sourceKey: key, metadata: SeriesMetadata(title: "Exemple"))
    }

    private func chapterInput(seriesID: UUID, key: String = "1", pageCount: Int = 3) throws -> NewChapter {
        let file = LocalFileInput(path: try RelativePath("chapitres/\(key).cbz"), kind: .archive)
        return NewChapter(
            seriesID: seriesID, key: key, title: "Chapitre \(key)", number: 1, order: 0,
            files: [file],
            pages: (0..<pageCount).map { LocalPageInput(fileID: file.id, entryIndex: $0) }
        )
    }

    @MainActor
    func testDefaultsMetadataSnapshotsAndStableIdentifiers() throws {
        let repo = try repository()
        var input = seriesInput()
        input.metadata = SeriesMetadata(
            title: "Exemple", authors: ["Auteur fictif"], artists: ["Artiste fictif"],
            summary: "Résumé fictif", genres: ["Aventure"], status: .ongoing,
            notes: "Note de test", rating: 7
        )
        input.cover = LocalFileInput(path: try RelativePath("couvertures/exemple.jpg"), kind: .image)
        let series = try repo.createSeries(input)
        XCTAssertEqual(series.id, input.id)
        XCTAssertEqual(series.metadata, input.metadata)
        XCTAssertEqual(series.cover?.id, input.cover?.id)
        XCTAssertFalse(series.isInLibrary)
        XCTAssertEqual(series.preferences, SeriesReadingPreferences())
        var local = try chapterInput(seriesID: series.id)
        local.number = nil
        let chapter = try repo.createChapter(local)
        XCTAssertEqual(chapter.id, local.id)
        XCTAssertNil(chapter.number)
        XCTAssertFalse(chapter.isRead)
        XCTAssertFalse(chapter.isBookmarked)
        XCTAssertNil(chapter.lastPageIndex)
        XCTAssertNil(chapter.history)
        XCTAssertEqual(chapter.pages.map(\.index), [0, 1, 2])
        XCTAssertEqual(chapter.pages.map(\.id), local.pages.map(\.id))
        XCTAssertEqual(try repo.series(id: series.id).chapters, [chapter])
        var metadata = input.metadata
        metadata.title = "Titre modifié"
        try repo.updateSeries(id: series.id, metadata: metadata)
        XCTAssertEqual(try repo.series(id: series.id).metadata, metadata)
        XCTAssertEqual(series.metadata.title, "Exemple")
    }

    @MainActor
    func testSeriesAndChapterDuplicatesDoNotUpsert() throws {
        let repo = try repository()
        let input = seriesInput()
        let series = try repo.createSeries(input)
        var duplicateID = seriesInput(id: series.id, key: "autre")
        duplicateID.metadata.title = "Ne pas écraser"
        XCTAssertThrowsError(try repo.createSeries(duplicateID))
        XCTAssertThrowsError(try repo.createSeries(seriesInput()))
        var otherSource = seriesInput()
        otherSource.sourceID = "réservée"
        let otherSeries = try repo.createSeries(otherSource)
        let chapter = try repo.createChapter(chapterInput(seriesID: series.id))
        XCTAssertThrowsError(try repo.createChapter(chapterInput(seriesID: series.id)))
        var duplicateChapterID = try chapterInput(seriesID: otherSeries.id)
        duplicateChapterID.id = chapter.id
        XCTAssertThrowsError(try repo.createChapter(duplicateChapterID))
        _ = try repo.createChapter(chapterInput(seriesID: otherSeries.id))
        XCTAssertEqual(try repo.series(id: series.id).metadata.title, "Exemple")
        XCTAssertEqual(try repo.series(id: series.id).chapters.count, 1)
        XCTAssertEqual(try repo.allSeries().count, 2)
    }

    @MainActor
    func testFileAndPageDuplicatesAndInvalidOwnershipAreRejected() throws {
        let repo = try repository()
        let series = try repo.createSeries(seriesInput())
        let first = try chapterInput(seriesID: series.id)
        _ = try repo.createChapter(first)
        var second = try chapterInput(seriesID: series.id, key: "2")
        second.files[0].id = first.files[0].id
        XCTAssertThrowsError(try repo.createChapter(second))
        second = try chapterInput(seriesID: series.id, key: "2")
        second.pages[0].id = first.pages[0].id
        XCTAssertThrowsError(try repo.createChapter(second))
        second = try chapterInput(seriesID: series.id, key: "2")
        second.files.append(second.files[0])
        XCTAssertThrowsError(try repo.createChapter(second))
        second = try chapterInput(seriesID: series.id, key: "2")
        second.pages.append(second.pages[0])
        XCTAssertThrowsError(try repo.createChapter(second))
        second = try chapterInput(seriesID: series.id, key: "2")
        second.pages[0].fileID = first.files[0].id
        XCTAssertThrowsError(try repo.createChapter(second))
        XCTAssertEqual(try repo.series(id: series.id).chapters.count, 1)
    }

    @MainActor
    func testSystemCategoryIsIdempotentAndProtected() throws {
        let container = try StorageFactory.makeContainer(inMemory: true)
        let first = try SwiftDataLibraryRepository(container: container)
        _ = try SwiftDataLibraryRepository(container: container)
        let systemID = LibraryIdentity.uncategorizedID
        XCTAssertEqual(try first.categories().count, 1)
        XCTAssertEqual(try first.categories().first?.id, systemID)
        XCTAssertEqual(try first.categories().first?.order, 0)
        XCTAssertThrowsError(try first.renameCategory(id: systemID, name: "Autre"))
        XCTAssertThrowsError(try first.deleteCategory(id: systemID))
        XCTAssertThrowsError(try first.createCategory(id: systemID, name: "Autre"))
        let series = try first.createSeries(seriesInput())
        XCTAssertThrowsError(try first.setCategories(seriesID: series.id, categoryIDs: [systemID]))
        XCTAssertThrowsError(try first.reorderCategories(ids: [systemID]))
        XCTAssertEqual(try first.categories().first?.seriesIDs, [series.id])
    }

    @MainActor
    func testManyToManyAssociationsOrderAndCategoryDeletion() throws {
        let repo = try repository()
        let a = try repo.createSeries(seriesInput(key: "a"))
        let b = try repo.createSeries(seriesInput(key: "b"))
        let first = try repo.createCategory(name: "Première")
        let second = try repo.createCategory(name: "Deuxième")
        XCTAssertThrowsError(try repo.createCategory(id: first.id, name: "Doublon"))
        try repo.setCategories(seriesID: a.id, categoryIDs: [first.id, second.id])
        try repo.setCategories(seriesID: b.id, categoryIDs: [first.id])
        XCTAssertThrowsError(try repo.setCategories(seriesID: a.id, categoryIDs: [first.id, first.id]))
        XCTAssertThrowsError(try repo.setCategories(seriesID: a.id, categoryIDs: [second.id, UUID()]))
        XCTAssertEqual(Set(try repo.series(id: a.id).categoryIDs), [first.id, second.id])
        XCTAssertEqual(try repo.categories()[1].seriesIDs.count, 2)
        XCTAssertEqual(try repo.categories()[0].seriesIDs, [])
        try repo.reorderCategories(ids: [second.id, first.id])
        XCTAssertEqual(try repo.categories().map(\.id), [LibraryIdentity.uncategorizedID, second.id, first.id])
        XCTAssertThrowsError(try repo.reorderCategories(ids: [first.id, first.id]))
        try repo.renameCategory(id: first.id, name: "Renommée")
        try repo.deleteCategory(id: first.id)
        XCTAssertEqual(try repo.categories().map(\.order), [0, 1])
        XCTAssertEqual(try repo.series(id: a.id).categoryIDs, [second.id])
        XCTAssertEqual(try repo.series(id: b.id).categoryIDs, [])
        XCTAssertEqual(try repo.categories()[0].seriesIDs, [b.id])
        try repo.setCategories(seriesID: a.id, categoryIDs: [])
        XCTAssertEqual(try repo.categories()[1].seriesIDs, [])
        XCTAssertEqual(try repo.allSeries().count, 2)
    }

    @MainActor
    func testPreferencesPersistAndResolveIndependently() throws {
        let repo = try repository()
        let series = try repo.createSeries(seriesInput())
        for mode in ReadingMode.allCases {
            try repo.setGlobalPreferences(ReadingPreferences(mode: mode))
            XCTAssertEqual(try repo.globalPreferences().mode, mode)
        }
        let global = ReadingPreferences(mode: .vertical, doublePages: .automatic, isolateCover: false)
        try repo.setGlobalPreferences(global)
        XCTAssertEqual(try repo.globalPreferences(), global)
        XCTAssertEqual(try repo.resolvedPreferences(seriesID: series.id), global)
        try repo.setSeriesPreferences(seriesID: series.id, value: SeriesReadingPreferences(mode: .leftToRight))
        XCTAssertEqual(
            try repo.resolvedPreferences(seriesID: series.id),
            ReadingPreferences(mode: .leftToRight, doublePages: .automatic, isolateCover: false)
        )
        try repo.setSeriesPreferences(seriesID: series.id, value: SeriesReadingPreferences())
        XCTAssertEqual(try repo.resolvedPreferences(seriesID: series.id), global)
    }

    @MainActor
    func testBoundedProgressMonotoneReadAndAggregatedHistory() throws {
        let repo = try repository()
        let series = try repo.createSeries(seriesInput())
        let chapter = try repo.createChapter(chapterInput(seriesID: series.id))
        let firstDate = Date(timeIntervalSince1970: 1_000)
        try repo.recordProgress(chapterID: chapter.id, pageIndex: 2, duration: 4, at: firstDate)
        let historyID = try XCTUnwrap(repo.chapter(id: chapter.id).history?.id)
        try repo.recordProgress(chapterID: chapter.id, pageIndex: 0, duration: 2, at: firstDate.addingTimeInterval(1))
        XCTAssertTrue(try repo.chapter(id: chapter.id).isRead)
        XCTAssertEqual(try repo.chapter(id: chapter.id).lastPageIndex, 0)
        XCTAssertEqual(try repo.history().count, 1)
        XCTAssertEqual(try repo.history()[0].duration, 6)
        XCTAssertEqual(try repo.history()[0].id, historyID)
        try repo.recordProgress(chapterID: chapter.id, pageIndex: 1, duration: 0, at: firstDate)
        XCTAssertEqual(try repo.history()[0].lastReadAt, firstDate.addingTimeInterval(1))
        XCTAssertEqual(try repo.history()[0].lastPageIndex, 0)
        for page in [-1, 3, Int.max] {
            XCTAssertThrowsError(try repo.recordProgress(chapterID: chapter.id, pageIndex: page, duration: 1, at: firstDate))
        }
        for duration in [-1.0, .infinity, .nan] {
            XCTAssertThrowsError(try repo.recordProgress(chapterID: chapter.id, pageIndex: 0, duration: duration, at: firstDate))
        }
        XCTAssertThrowsError(try repo.recordProgress(
            chapterID: chapter.id, pageIndex: 0, duration: 0,
            at: Date(timeIntervalSinceReferenceDate: .infinity)
        ))
        XCTAssertEqual(try repo.history()[0].duration, 6)
        try repo.setRead(chapterID: chapter.id, isRead: false)
        XCTAssertFalse(try repo.chapter(id: chapter.id).isRead)
        XCTAssertNil(try repo.chapter(id: chapter.id).lastPageIndex)
        try repo.recordProgress(chapterID: chapter.id, pageIndex: 1, duration: 0, at: firstDate)
        XCTAssertFalse(try repo.chapter(id: chapter.id).isRead)
        try repo.setRead(chapterID: chapter.id, isRead: true)
        try repo.setBookmark(chapterID: chapter.id, isBookmarked: true)
        XCTAssertTrue(try repo.chapter(id: chapter.id).isBookmarked)
        XCTAssertTrue(try repo.chapter(id: chapter.id).isRead)
        let empty = try repo.createChapter(chapterInput(seriesID: series.id, key: "vide", pageCount: 0))
        XCTAssertThrowsError(try repo.recordProgress(chapterID: empty.id, pageIndex: 0, duration: 0, at: firstDate))
        XCTAssertEqual(try repo.history().count, 1)
    }

    @MainActor
    func testHistoryDurationOverflowIsRolledBack() throws {
        let repo = try repository()
        let series = try repo.createSeries(seriesInput())
        let chapter = try repo.createChapter(chapterInput(seriesID: series.id))
        let date = Date(timeIntervalSince1970: 1_000)
        try repo.recordProgress(
            chapterID: chapter.id, pageIndex: 0, duration: .greatestFiniteMagnitude, at: date
        )
        XCTAssertThrowsError(try repo.recordProgress(
            chapterID: chapter.id, pageIndex: 2, duration: .greatestFiniteMagnitude, at: date
        ))
        XCTAssertEqual(try repo.chapter(id: chapter.id).lastPageIndex, 0)
        XCTAssertFalse(try repo.chapter(id: chapter.id).isRead)
        XCTAssertEqual(try repo.history()[0].duration, .greatestFiniteMagnitude)
    }

    @MainActor
    func testInvalidInputDoesNotLeaveChanges() throws {
        let repo = try repository()
        var input = seriesInput()
        input.sourceKey = " "
        XCTAssertThrowsError(try repo.createSeries(input))
        input = seriesInput()
        input.favoriteAt = Date(timeIntervalSinceReferenceDate: .nan)
        XCTAssertThrowsError(try repo.createSeries(input))
        XCTAssertEqual(try repo.allSeries().count, 0)
        let series = try repo.createSeries(seriesInput())
        XCTAssertThrowsError(try repo.updateSeries(id: series.id, metadata: SeriesMetadata(title: "")))
        XCTAssertEqual(try repo.series(id: series.id).metadata.title, "Exemple")
        var chapter = try chapterInput(seriesID: series.id)
        chapter.order = -1
        XCTAssertThrowsError(try repo.createChapter(chapter))
        chapter.order = 0
        chapter.number = .nan
        XCTAssertThrowsError(try repo.createChapter(chapter))
        chapter.number = 1
        chapter.files[0].byteCount = -1
        XCTAssertThrowsError(try repo.createChapter(chapter))
        XCTAssertEqual(try repo.series(id: series.id).chapters.count, 0)
        XCTAssertThrowsError(try repo.createCategory(name: " "))
        XCTAssertThrowsError(try repo.setFavorite(id: UUID(), at: nil))
    }

    @MainActor
    func testRollbackAfterPartialMutationAndContextIsolation() throws {
        let container = try StorageFactory.makeContainer(inMemory: true)
        let repo = try SwiftDataLibraryRepository(container: container)
        let series = try repo.createSeries(seriesInput())
        let chapter = try repo.createChapter(chapterInput(seriesID: series.id))
        // Injection d’un stockage incohérent : l’échec survient après modification de la progression.
        let independent = ModelContext(container)
        independent.autosaveEnabled = false
        independent.insert(StoredHistory(chapterID: chapter.id, date: .now, page: 0, duration: 0))
        try independent.save()
        independent.insert(StorageMetadata(key: "travail indépendant"))
        XCTAssertThrowsError(try repo.recordProgress(chapterID: chapter.id, pageIndex: 2, duration: 1, at: .now))
        XCTAssertFalse(try repo.chapter(id: chapter.id).isRead)
        XCTAssertNil(try repo.chapter(id: chapter.id).lastPageIndex)
        let reading = ModelContext(container)
        XCTAssertNil(try reading.fetch(FetchDescriptor<StoredChapter>()).first?.lastPageIndex)
        XCTAssertTrue(independent.hasChanges)
        try independent.save()
        XCTAssertEqual(try reading.fetchCount(FetchDescriptor<StorageMetadata>()), 1)
        let orphanSeriesID = UUID()
        let orphan = StoredSeriesPreferences(seriesID: orphanSeriesID)
        orphan.modeRaw = ReadingMode.vertical.rawValue
        independent.insert(orphan)
        try independent.save()
        XCTAssertThrowsError(try repo.createSeries(seriesInput(id: orphanSeriesID, key: "orpheline")))
        XCTAssertEqual(try repo.allSeries().count, 1)
        XCTAssertEqual(orphan.modeRaw, ReadingMode.vertical.rawValue)
    }

    @MainActor
    func testLibraryRemovalChapterDeletionAndSeriesCascadesAreDistinct() throws {
        let container = try StorageFactory.makeContainer(inMemory: true)
        let repo = try SwiftDataLibraryRepository(container: container)
        var input = seriesInput()
        input.cover = LocalFileInput(path: try RelativePath("couvertures/exemple.jpg"), kind: .image)
        let series = try repo.createSeries(input)
        let category = try repo.createCategory(name: "Catégorie")
        try repo.setCategories(seriesID: series.id, categoryIDs: [category.id])
        let first = try repo.createChapter(chapterInput(seriesID: series.id))
        let second = try repo.createChapter(chapterInput(seriesID: series.id, key: "2"))
        try repo.recordProgress(chapterID: first.id, pageIndex: 1, duration: 2, at: .now)
        try repo.recordProgress(chapterID: second.id, pageIndex: 2, duration: 1, at: .now)
        try repo.setFavorite(id: series.id, at: .now)
        XCTAssertEqual(try repo.allSeries(inLibraryOnly: true).count, 1)
        try repo.setFavorite(id: series.id, at: nil)
        XCTAssertEqual(try repo.allSeries(inLibraryOnly: true).count, 0)
        XCTAssertEqual(try repo.series(id: series.id).chapters.count, 2)
        XCTAssertEqual(try repo.history().count, 2)
        try repo.deleteChapter(id: first.id)
        XCTAssertThrowsError(try repo.chapter(id: first.id))
        XCTAssertEqual(try repo.history().map(\.chapterID), [second.id])
        let afterChapter = ModelContext(container)
        XCTAssertEqual(try afterChapter.fetchCount(FetchDescriptor<StoredPage>()), 3)
        XCTAssertEqual(try afterChapter.fetchCount(FetchDescriptor<StoredFile>()), 2)
        try repo.deleteSeries(id: series.id)
        let afterSeries = ModelContext(container)
        XCTAssertEqual(try afterSeries.fetchCount(FetchDescriptor<StoredChapter>()), 0)
        XCTAssertEqual(try afterSeries.fetchCount(FetchDescriptor<StoredFile>()), 0)
        XCTAssertEqual(try afterSeries.fetchCount(FetchDescriptor<StoredPage>()), 0)
        XCTAssertEqual(try afterSeries.fetchCount(FetchDescriptor<StoredHistory>()), 0)
        XCTAssertEqual(try afterSeries.fetchCount(FetchDescriptor<StoredSeriesPreferences>()), 0)
        XCTAssertEqual(try repo.categories().count, 2)
        XCTAssertEqual(try repo.categories()[1].seriesIDs, [])
    }

    @MainActor
    func testInMemoryRepositoriesAreIsolated() throws {
        let first = try repository()
        let second = try repository()
        _ = try first.createSeries(seriesInput())
        _ = try first.createCategory(name: "Privée au conteneur")
        XCTAssertEqual(try second.allSeries().count, 0)
        XCTAssertEqual(try second.categories().count, 1)
    }
}
