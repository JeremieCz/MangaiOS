import Foundation

@MainActor
protocol LibraryRepository {
    func exportSnapshot() throws -> LibraryBackupSnapshot
    func replaceSnapshot(_ snapshot: LibraryBackupSnapshot) throws
    func series(id: UUID) throws -> SeriesSnapshot
    func allSeries(inLibraryOnly: Bool) throws -> [SeriesSnapshot]
    func createSeries(_ input: NewSeries) throws -> SeriesSnapshot
    func updateSeries(id: UUID, metadata: SeriesMetadata) throws
    func setFavorite(id: UUID, at date: Date?) throws
    func deleteSeries(id: UUID) throws
    func createChapter(_ input: NewChapter) throws -> ChapterSnapshot
    /// La série facultative et son chapitre sont sauvegardés dans une seule transaction.
    func commitImport(series: NewSeries?, chapter: NewChapter) throws -> ChapterSnapshot
    func chapter(id: UUID) throws -> ChapterSnapshot
    func deleteChapter(id: UUID) throws
    func setRead(chapterID: UUID, isRead: Bool) throws
    func setBookmark(chapterID: UUID, isBookmarked: Bool) throws
    func recordProgress(chapterID: UUID, pageIndex: Int, duration: TimeInterval, at date: Date) throws
    func recordReaderProgress(chapterID: UUID, pageIndex: Int, duration: TimeInterval, at date: Date,
                              completed: Bool) throws
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

extension LibraryRepository {
    func recordReaderProgress(chapterID: UUID, pageIndex: Int, duration: TimeInterval, at date: Date,
                              completed: Bool) throws {
        let wasRead = try chapter(id: chapterID).isRead
        try recordProgress(chapterID: chapterID, pageIndex: pageIndex, duration: duration, at: date)
        if !completed && !wasRead { try setRead(chapterID: chapterID, isRead: false) }
    }
}
