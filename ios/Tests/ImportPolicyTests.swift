import Foundation
import XCTest
@testable import MangaiOS

final class ImportPolicyTests: XCTestCase {
    func testNaturalOrderHasDeterministicLeadingZeroTieBreak() {
        let paths = ["10.png", "9.png", "01.png", "2.png", "1.png", "11.png", "09.png", "001.png"]
        XCTAssertEqual(paths.sorted(by: ImportPolicy.precedes),
                       ["001.png", "01.png", "1.png", "2.png", "09.png", "9.png", "10.png", "11.png"])
        XCTAssertTrue(ImportPolicy.precedes("A/2.png", "a/10.png"))
    }

    func testPathsAndUnicodeCaseNormalization() throws {
        for path in ["../page.png", "/page.png", "a//b", "a\\b", "a/./b", "a%2fb", "C:a", "~a", "a\nb"] {
            XCTAssertThrowsError(try ImportPolicy.normalized(path), path)
        }
        XCTAssertEqual(try ImportPolicy.normalized("É/FILE.PNG"), try ImportPolicy.normalized("E\u{301}/file.png"))
        XCTAssertTrue(ImportPolicy.ignored("a/.hidden/x.png"))
        XCTAssertTrue(ImportPolicy.ignored("__MACOSX/a.png"))
        XCTAssertFalse(ImportPolicy.ignored("a/page.png"))
    }

    func testSpaceOverflowSafeAndCleanupErrorIsVisible() throws {
        XCTAssertThrowsError(try ImportPolicy.requireSpace(available: 100, needed: 90, reserve: 20))
        XCTAssertThrowsError(try ImportPolicy.requireSpace(available: Int64.max, needed: Int64.max, reserve: 1))
        try ImportPolicy.requireSpace(available: 100, needed: 80, reserve: 20)
        let failure = ImportFailure.cleanup("Échec base", "Permission refusée")
        XCTAssertTrue(failure.localizedDescription.contains("Échec base"))
        XCTAssertTrue(failure.localizedDescription.contains("Permission refusée"))
        XCTAssertTrue(DomainError.duplicate("chapitre").localizedDescription.contains("Doublon refusé"))
    }

    func testComicInfoNamespacesAndFullMetadata() throws {
        let xml = """
        <ComicInfo xmlns="urn:comic" xmlns:m="urn:mangaios">
        <Series>Série</Series><Title>Début</Title><Number>1.5</Number><Summary>Résumé &amp; suite</Summary>
        <Writer>Alice, Bob</Writer><Penciller>Claire</Penciller><Inker>Denis</Inker><Genre>Aventure;Drame</Genre>
        <Year>2024</Year><Month>2</Month><Day>29</Day>
        <m:Translator>Équipe</m:Translator><m:Status>completed</m:Status>
        <m:Categories>Favoris;À lire</m:Categories><m:Source>https://example.invalid</m:Source>
        </ComicInfo>
        """
        let metadata = try ComicInfo.parse(Data(xml.utf8), fallback: "Fichier")
        XCTAssertEqual(metadata.series.title, "Série")
        XCTAssertEqual(metadata.chapterTitle, "Début")
        XCTAssertEqual(metadata.number, 1.5)
        XCTAssertEqual(metadata.series.authors, ["Alice", "Bob"])
        XCTAssertEqual(metadata.series.artists, ["Claire", "Denis"])
        XCTAssertEqual(metadata.series.summary, "Résumé & suite")
        XCTAssertEqual(metadata.series.genres, ["Aventure", "Drame"])
        XCTAssertEqual(metadata.series.status, .completed)
        XCTAssertEqual(metadata.publicationDate, "2024-02-29")
        XCTAssertEqual(metadata.translators, ["Équipe"])
        XCTAssertEqual(metadata.categories, ["Favoris", "À lire"])
        XCTAssertEqual(metadata.source, "https://example.invalid")
        XCTAssertTrue(metadata.warnings.isEmpty)
    }

    func testComicInfoFallbackInvalidDateAndNumberWarn() throws {
        let metadata = try ComicInfo.parse(Data("""
        <ComicInfo><Year>2023</Year><Month>2</Month><Day>29</Day><Number>NaN</Number></ComicInfo>
        """.utf8), fallback: "Fichier")
        XCTAssertEqual(metadata.series.title, "Fichier")
        XCTAssertNil(metadata.publicationDate)
        XCTAssertNil(metadata.number)
        XCTAssertEqual(metadata.warnings.count, 2)
        let yearOnly = try ComicInfo.parse(Data("<ComicInfo><Year>2020</Year></ComicInfo>".utf8), fallback: "X")
        XCTAssertEqual(yearOnly.publicationDate, "2020-01-01")
    }

    func testComicInfoAndroidNamesTakePriorityRegardlessOfOrderOrPrefix() throws {
        let upstream = """
        <ty:PublishingStatusTachiyomi>On hiatus</ty:PublishingStatusTachiyomi>
        <mh:SourceMihon>javascript:neverExecute()</mh:SourceMihon>
        """
        let generic = "<Status>completed</Status><Source>https://example.invalid/fallback</Source>"
        for fields in [generic + upstream, upstream + generic] {
            let xml = """
            <ComicInfo xmlns:ty="http://www.w3.org/2001/XMLSchema" xmlns:mh="http://www.w3.org/2001/XMLSchema">
            \(fields)
            <Genre>Action;Drame</Genre><Tags>Drame, Mystère</Tags>
            <Penciller>Alice</Penciller><Inker>Bob</Inker><Colorist>Claire</Colorist>
            <Letterer>Denis, Alice</Letterer><CoverArtist>Émilie</CoverArtist>
            </ComicInfo>
            """
            let metadata = try ComicInfo.parse(Data(xml.utf8), fallback: "X")
            XCTAssertEqual(metadata.series.status, .hiatus)
            XCTAssertEqual(metadata.source, "javascript:neverExecute()")
            XCTAssertEqual(metadata.series.genres, ["Action", "Drame", "Mystère"])
            XCTAssertEqual(metadata.series.artists, ["Alice", "Bob", "Claire", "Denis", "Émilie"])
            XCTAssertTrue(metadata.warnings.isEmpty)
            let renamed = xml.replacingOccurrences(of: "ty:", with: "status:")
                .replacingOccurrences(of: "xmlns:ty=", with: "xmlns:status=")
                .replacingOccurrences(of: "mh:", with: "origin:")
                .replacingOccurrences(of: "xmlns:mh=", with: "xmlns:origin=")
            XCTAssertEqual(try ComicInfo.parse(Data(renamed.utf8), fallback: "X"), metadata)
        }
    }

    func testComicInfoAllAndroidPublishingStatusValues() throws {
        let cases: [(String, SeriesStatus, Int)] = [
            ("Ongoing", .ongoing, 0), ("Completed", .completed, 0),
            ("Licensed", .unknown, 1), ("Publishing finished", .completed, 0),
            ("Cancelled", .cancelled, 0), ("On hiatus", .hiatus, 0), ("Unknown", .unknown, 0)
        ]
        for (raw, expected, warnings) in cases {
            let xml = """
            <ComicInfo xmlns:ty="http://www.w3.org/2001/XMLSchema">
            <ty:PublishingStatusTachiyomi>\(raw)</ty:PublishingStatusTachiyomi>
            </ComicInfo>
            """
            let metadata = try ComicInfo.parse(Data(xml.utf8), fallback: "X")
            XCTAssertEqual(metadata.series.status, expected, raw)
            XCTAssertEqual(metadata.warnings.count, warnings, raw)
        }
    }

    func testComicInfoUnknownUpstreamStatusDoesNotUseGenericFallback() throws {
        for raw in ["Unknown", "Future status", "Licensed"] {
            let xml = """
            <ComicInfo xmlns:ty="http://www.w3.org/2001/XMLSchema">
            <Status>ongoing</Status><ty:PublishingStatusTachiyomi>\(raw)</ty:PublishingStatusTachiyomi>
            </ComicInfo>
            """
            let metadata = try ComicInfo.parse(Data(xml.utf8), fallback: "X")
            XCTAssertEqual(metadata.series.status, .unknown)
            XCTAssertEqual(metadata.warnings.count, raw == "Unknown" ? 0 : 1)
        }
        let generic = try ComicInfo.parse(Data("<ComicInfo><Status>Future status</Status></ComicInfo>".utf8), fallback: "X")
        XCTAssertEqual(generic.series.status, .unknown)
        XCTAssertEqual(generic.warnings.count, 1)
    }

    func testComicInfoEmptyUpstreamFieldsUseGenericFallback() throws {
        let xml = """
        <ComicInfo xmlns:ty="http://www.w3.org/2001/XMLSchema" xmlns:mh="http://www.w3.org/2001/XMLSchema">
        <ty:PublishingStatusTachiyomi> </ty:PublishingStatusTachiyomi><mh:SourceMihon/>
        <Status>HIATUS</Status><Source>https://example.invalid/legacy</Source>
        </ComicInfo>
        """
        let metadata = try ComicInfo.parse(Data(xml.utf8), fallback: "X")
        XCTAssertEqual(metadata.series.status, .hiatus)
        XCTAssertEqual(metadata.source, "https://example.invalid/legacy")
        XCTAssertTrue(metadata.warnings.isEmpty)
    }

    func testComicInfoRejectsMalformedDTDXXEEncodingAndLimitsBeforeIO() {
        for xml in [
            "<ComicInfo>",
            "<Other/>",
            "<!DOCTYPE ComicInfo SYSTEM 'https://example.invalid/private'><ComicInfo/>",
            "<!DOCTYPE ComicInfo [<!ENTITY x SYSTEM 'file:///nonexistent/private'>]><ComicInfo><Series>&x;</Series></ComicInfo>",
            "<ComicInfo><Series>&missing;</Series></ComicInfo>",
            "<ComicInfo>" + String(repeating: "<x>", count: 17) + String(repeating: "</x>", count: 17) + "</ComicInfo>"
        ] {
            XCTAssertThrowsError(try ComicInfo.parse(Data(xml.utf8), fallback: "X"))
        }
        XCTAssertThrowsError(try ComicInfo.parse(Data("<ComicInfo/>".utf8), fallback: "X", limit: 3))
        XCTAssertThrowsError(try ComicInfo.parse(Data([0xff, 0xfe, 0x3c, 0x00]), fallback: "X"))
    }
}
