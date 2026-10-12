import Foundation

@MainActor
protocol LibraryRepository {
    func series(id: UUID) throws -> SeriesSnapshot
    func allSeries(inLibraryOnly: Bool) throws -> [SeriesSnapshot]
    func createSeries(_ input: NewSeries) throws -> SeriesSnapshot
    func updateSeries(id: UUID, metadata: SeriesMetadata) throws
    func setFavorite(id: UUID, at date: Date?) throws
    func deleteSeries(id: UUID) throws
    func createChapter(_ input: NewChapter) throws -> ChapterSnapshot
    func chapter(id: UUID) throws -> ChapterSnapshot
    func deleteChapter(id: UUID) throws
    func setRead(chapterID: UUID, isRead: Bool) throws
    func setBookmark(chapterID: UUID, isBookmarked: Bool) throws
    func recordProgress(chapterID: UUID, pageIndex: Int, duration: TimeInterval, at date: Date) throws
    func categories() throws -> [CategorySnapshot]
    func createCategory(id: UUID, name: String) throws -> CategorySnapshot
    func renameCategory(id: UUID, name: String) throws
    func reorderCategories(ids: [UUID]) throws
    func deleteCategory(id: UUID) throws
    func setCategories(seriesID: UUID, categoryIDs: [UUID]) throws
    func globalPreferences() throws -> ReadingPreferences
    func setGlobalPreferences(_ value: ReadingPreferences) throws
    func setSeriesPreferences(seriesID: UUID, value: SeriesReadingPreferences) throws
    func resolvedPreferences(seriesID: UUID) throws -> ReadingPreferences
    func history() throws -> [HistorySnapshot]
}
