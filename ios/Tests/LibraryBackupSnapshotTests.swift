import Foundation
import XCTest
@testable import MangaiOS

final class LibraryBackupSnapshotTests: XCTestCase {
    private func fixture() throws -> LibraryBackupSnapshot {
        let seriesID = UUID(), chapterID = UUID(), fileID = UUID(), categoryID = UUID()
        let file = FileSnapshot(id: fileID, path: try RelativePath("imports/example/one.png"), kind: .image, byteCount: 12)
        let history = HistorySnapshot(id: UUID(), chapterID: chapterID, lastReadAt: Date(timeIntervalSince1970: 1234.5),
                                      lastPageIndex: 0, duration: 12.75)
        let chapter = ChapterSnapshot(id: chapterID, seriesID: seriesID, key: "one", title: "Chapitre", number: 1.5,
            order: 4, isRead: true, isBookmarked: true, lastPageIndex: 0, files: [file],
            pages: [PageSnapshot(id: UUID(), index: 0, fileID: fileID, entryIndex: nil, width: 2, height: 3)], history: history)
        let series = SeriesSnapshot(id: seriesID, sourceID: "local", sourceKey: "one", metadata: SeriesMetadata(title: "Série"),
            favoriteAt: nil, cover: nil, categoryIDs: [categoryID],
            preferences: SeriesReadingPreferences(mode: .vertical, isolateCover: false), chapters: [chapter])
        return LibraryBackupSnapshot(series: [series],
            categories: [CategorySnapshot(id: LibraryIdentity.uncategorizedID, name: "Sans catégorie", order: 0,
                                          isSystem: true, seriesIDs: []),
                         CategorySnapshot(id: categoryID, name: "Personnel", order: 1, isSystem: false, seriesIDs: [seriesID])],
            globalPreferences: ReadingPreferences(mode: .webtoon, doublePages: .automatic, isolateCover: true))
    }

    private func reject(_ change: (inout [String: Any]) throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        try change(&object)
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(LibraryBackupSnapshot.self, from: data).validate(), file: file, line: line)
    }

    private func changeChapter(_ object: inout [String: Any],
                               change: (inout [String: Any]) throws -> Void) throws {
        var series = try XCTUnwrap(object["series"] as? [[String: Any]])
        var chapters = try XCTUnwrap(series[0]["chapters"] as? [[String: Any]])
        try change(&chapters[0])
        series[0]["chapters"] = chapters
        object["series"] = series
    }

    func testCodableRoundTripPreservesFieldsUUIDsAndFractionalDates() throws {
        let value = try fixture()
        try value.validate()
        let result = try JSONDecoder().decode(LibraryBackupSnapshot.self, from: JSONEncoder().encode(value))
        try result.validate()
        XCTAssertEqual(result, value)
        XCTAssertEqual(result.series[0].chapters[0].history?.duration, 12.75)
        XCTAssertEqual(result.series[0].chapters[0].history?.lastReadAt.timeIntervalSince1970, 1234.5)
        XCTAssertNil(result.series[0].favoriteAt)
    }

    func testDuplicateIdentityAndIDsAreRejected() throws {
        let value = try fixture()
        XCTAssertThrowsError(try LibraryBackupSnapshot(series: value.series + value.series,
            categories: value.categories, globalPreferences: value.globalPreferences).validate())
        try reject { object in
            var series = try XCTUnwrap(object["series"] as? [[String: Any]])
            var other = series[0]
            other["id"] = UUID().uuidString
            other["chapters"] = []
            other["categoryIDs"] = []
            series.append(other)
            object["series"] = series
        }
        try reject { object in
            try changeChapter(&object) { chapter in
                var pages = try XCTUnwrap(chapter["pages"] as? [[String: Any]])
                pages[0]["id"] = chapter["id"]
                chapter["pages"] = pages
            }
        }
    }

    func testCategorySystemInverseAndOrderMustMatch() throws {
        for field in ["id", "name", "order", "isSystem"] {
            try reject { object in
                var categories = try XCTUnwrap(object["categories"] as? [[String: Any]])
                switch field {
                case "id": categories[0][field] = UUID().uuidString
                case "name": categories[0][field] = "Renommée"
                case "order": categories[1][field] = 0
                default: categories[0][field] = false
                }
                object["categories"] = categories
            }
        }
        try reject { object in
            var categories = try XCTUnwrap(object["categories"] as? [[String: Any]])
            categories[1]["seriesIDs"] = []
            object["categories"] = categories
        }
    }

    func testCrossReferencesContiguousPagesAndHistoryMatch() throws {
        for field in ["seriesID", "lastPageIndex", "order", "number"] {
            try reject { object in
                try changeChapter(&object) { chapter in
                    chapter[field] = field == "seriesID" ? UUID().uuidString as Any : -1
                }
            }
        }
        for field in ["fileID", "index", "width", "entryIndex"] {
            try reject { object in
                try changeChapter(&object) { chapter in
                    var pages = try XCTUnwrap(chapter["pages"] as? [[String: Any]])
                    pages[0][field] = field == "fileID" ? UUID().uuidString as Any : -1
                    chapter["pages"] = pages
                }
            }
        }
        for field in ["chapterID", "lastPageIndex", "duration"] {
            try reject { object in
                try changeChapter(&object) { chapter in
                    var history = try XCTUnwrap(chapter["history"] as? [String: Any])
                    history[field] = field == "chapterID" ? UUID().uuidString as Any : -1
                    chapter["history"] = history
                }
            }
        }
    }

    func testStrictEnumsPathsAndFileSizes() throws {
        for (field, value) in [("path", "../outside"), ("path", "staging/prepared/image.png"),
                               ("kind", "executable"), ("byteCount", "-1")] {
            try reject { object in
                try changeChapter(&object) { chapter in
                    var files = try XCTUnwrap(chapter["files"] as? [[String: Any]])
                    files[0][field] = field == "byteCount" ? -1 as Any : value
                    chapter["files"] = files
                }
            }
        }
        try reject { object in
            var prefs = try XCTUnwrap(object["globalPreferences"] as? [String: Any])
            prefs["mode"] = "unsupported"
            object["globalPreferences"] = prefs
        }
    }

    func testNonFiniteDurationsRatingsAndDatesCannotEncodeOrValidate() throws {
        let value = try fixture()
        let series = value.series[0], chapter = series.chapters[0]
        for duration in [Double.infinity, Double.nan, -1] {
            let oldHistory = try XCTUnwrap(chapter.history)
            let history = HistorySnapshot(id: oldHistory.id, chapterID: chapter.id, lastReadAt: oldHistory.lastReadAt,
                                          lastPageIndex: 0, duration: duration)
            let changedChapter = ChapterSnapshot(id: chapter.id, seriesID: series.id, key: chapter.key,
                title: chapter.title, number: nil, order: 0, isRead: true, isBookmarked: false, lastPageIndex: 0,
                files: chapter.files, pages: chapter.pages, history: history)
            let changedSeries = SeriesSnapshot(id: series.id, sourceID: series.sourceID, sourceKey: series.sourceKey,
                metadata: series.metadata, favoriteAt: nil, cover: nil, categoryIDs: series.categoryIDs,
                preferences: series.preferences, chapters: [changedChapter])
            let changed = LibraryBackupSnapshot(series: [changedSeries], categories: value.categories,
                                                 globalPreferences: value.globalPreferences)
            XCTAssertThrowsError(try changed.validate())
        }
        XCTAssertThrowsError(try SeriesMetadata(title: "Série", rating: .infinity).validate())
        XCTAssertThrowsError(try JSONEncoder().encode(Date(timeIntervalSinceReferenceDate: .infinity)))
    }
}
