import Foundation
import XCTest
@testable import MangaiOS

final class LibraryDomainTests: XCTestCase {
    func testRelativePathsRejectTraversalAndAlternativeSeparators() throws {
        for path in [
            "", "/", "/cover.jpg", "a/", "a//b", ".", "..", "./a", "a/../b", "a/./b",
            "C:/a", "a\\b", "\\\\server\\a", "https://host/a", "~", "~/a",
            "a\u{0}b", "a\nb", "a/%2e%2e/b", "a%2fb",
            "a\u{2044}b", "a\u{2215}b", "a\u{29f8}b", "a\u{ff0f}b", "a\u{ff3c}b",
            "/\u{301}a", "a\\\u{301}b", "a:\u{301}b", "a%\u{301}b", "~\u{301}a"
        ] {
            XCTAssertThrowsError(try RelativePath(path), path)
        }
        let path = try RelativePath("séries/exemple/page 01.jpg")
        XCTAssertEqual(path.value, "séries/exemple/page 01.jpg")
        XCTAssertEqual(try JSONDecoder().decode(RelativePath.self, from: JSONEncoder().encode(path)), path)
        XCTAssertThrowsError(try JSONDecoder().decode(RelativePath.self, from: Data("\"../a\"".utf8)))
    }

    func testFiveModesAndIndependentInheritance() {
        XCTAssertEqual(ReadingMode.allCases.count, 5)
        let global = ReadingPreferences(mode: .webtoon, doublePages: .automatic, isolateCover: false)
        XCTAssertEqual(SeriesReadingPreferences().resolved(over: global), global)
        let overrides = SeriesReadingPreferences(mode: .leftToRight, isolateCover: true)
        XCTAssertEqual(
            overrides.resolved(over: global),
            ReadingPreferences(mode: .leftToRight, doublePages: .automatic, isolateCover: true)
        )
        XCTAssertEqual(ReadingPreferences().doublePages, .disabled)
    }

    func testIdentityEncodingHasNoSeparatorCollision() {
        XCTAssertNotEqual(LibraryIdentity.key("a", "b:c"), LibraryIdentity.key("a:b", "c"))
        XCTAssertNotEqual(LibraryIdentity.key("é", "x"), LibraryIdentity.key("éx", ""))
        XCTAssertEqual(NewSeries(sourceKey: "1", metadata: SeriesMetadata(title: "Exemple")).sourceID, "local")
    }

    func testMetadataAndLocalContentValidation() throws {
        XCTAssertThrowsError(try SeriesMetadata(title: " \n").validate())
        for rating in [-1.0, 11, .infinity, .nan] {
            XCTAssertThrowsError(try SeriesMetadata(title: "Exemple", rating: rating).validate())
        }
        try SeriesMetadata(title: "Exemple", rating: 10).validate()
        let path = try RelativePath("chapitres/1.cbz")
        XCTAssertThrowsError(try LocalFileInput(path: path, kind: .archive, byteCount: -1).validate())
        XCTAssertThrowsError(try LocalPageInput(fileID: UUID(), entryIndex: -1).validate())
        XCTAssertThrowsError(try LocalPageInput(fileID: UUID(), width: 0).validate())
        XCTAssertThrowsError(try LocalPageInput(fileID: UUID(), height: -2).validate())
    }
}
