import Foundation
import XCTest
@testable import MangaiOS

final class LibraryPresentationTests: XCTestCase {
    private func chapter(order: Int, read: Bool = false, bookmark: Bool = false, date: Date? = nil) -> ChapterSnapshot {
        let id = UUID()
        return ChapterSnapshot(id: id, seriesID: UUID(), key: "\(order)", title: "\(order)", number: nil,
            order: order, isRead: read, isBookmarked: bookmark, lastPageIndex: nil, files: [],
            pages: [PageSnapshot(id: UUID(), index: 0, fileID: UUID(), entryIndex: nil, width: 600, height: 900)],
            history: date.map { HistorySnapshot(id: UUID(), chapterID: id, lastReadAt: $0, lastPageIndex: 0, duration: 2) })
    }
    private func series(title: String = "Exemple", favorite: Bool = true, categories: [UUID] = [],
                        chapters: [ChapterSnapshot] = []) -> SeriesSnapshot {
        SeriesSnapshot(id: UUID(), sourceID: "local", sourceKey: UUID().uuidString,
            metadata: SeriesMetadata(title: title), favoriteAt: favorite ? Date() : nil, cover: nil,
            categoryIDs: categories, preferences: SeriesReadingPreferences(), chapters: chapters)
    }
    func testSearchAndLibraryFilter() {
        let a = series(title: "Manga Alpha"), b = series(title: "Alpha", favorite: false)
        XCTAssertEqual(LibrarySelection.filtered([a, b], query: "ALPHA", category: nil,
                                                inLibraryOnly: true, sort: .title).map(\.id), [a.id])
        XCTAssertEqual(LibrarySelection.filtered([a, b], query: "", category: nil,
                                                inLibraryOnly: false, sort: .title).count, 2)
    }
    func testCategoryAndUncategorizedFilter() {
        let category = UUID(), a = series(), b = series(categories: [])
        let categorized = series(categories: [category])
        XCTAssertEqual(LibrarySelection.filtered([a, b, categorized], query: "", category: category,
                                                inLibraryOnly: false, sort: .title).map(\.id), [categorized.id])
        XCTAssertEqual(LibrarySelection.filtered([a, b, categorized], query: "",
            category: LibraryIdentity.uncategorizedID, inLibraryOnly: true, sort: .title).count, 2)
    }
    func testStableTitleSortAndCounters() {
        let a = series(chapters: [chapter(order: 0, read: true), chapter(order: 1, bookmark: true)])
        let b = series()
        let sorted = LibrarySelection.filtered([a, b], query: "", category: nil, inLibraryOnly: true, sort: .title)
        XCTAssertEqual(sorted.map(\.id), [a.id, b.id].sorted { $0.uuidString < $1.uuidString })
        let counts = LibrarySelection.counters(a)
        XCTAssertEqual(counts.read, 1); XCTAssertEqual(counts.unread, 1); XCTAssertEqual(counts.bookmarked, 1)
    }
    func testRecentAndUnreadSort() {
        let a = series(chapters: [chapter(order: 0, date: Date(timeIntervalSince1970: 10))])
        let b = series(chapters: [chapter(order: 0), chapter(order: 1)])
        XCTAssertEqual(LibrarySelection.filtered([b, a], query: "", category: nil, inLibraryOnly: true, sort: .recent).first?.id, a.id)
        XCTAssertEqual(LibrarySelection.filtered([a, b], query: "", category: nil, inLibraryOnly: true, sort: .unread).first?.id, b.id)
    }
    func testResumePrefersRecentlyStartedUnreadThenOrder() {
        let first = chapter(order: 0), started = chapter(order: 1, date: Date()), read = chapter(order: 2, read: true, date: Date().addingTimeInterval(100))
        XCTAssertEqual(LibrarySelection.resume(series(chapters: [read, started, first]))?.id, started.id)
        XCTAssertEqual(LibrarySelection.resume(series(chapters: [read, first]))?.id, first.id)
        XCTAssertNil(LibrarySelection.resume(series()))
    }
}
