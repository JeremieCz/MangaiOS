import Foundation
import XCTest
@testable import MangaiOS

final class ReaderLayoutTests: XCTestCase {
    private func pages(_ count: Int, wide: Set<Int> = []) -> [PageSnapshot] {
        (0..<count).map {
            PageSnapshot(id: UUID(), index: $0, fileID: UUID(), entryIndex: nil,
                         width: wide.contains($0) ? 1600 : 600, height: 900)
        }
    }
    func testSinglePageModesPreserveOriginalIndices() {
        for mode in ReadingMode.allCases {
            let result = ReaderLayout.units(pages: pages(3), preferences: ReadingPreferences(mode: mode),
                                            landscape: false, splitPanoramas: false)
            XCTAssertEqual(result.map(\.logicalPages), [[0], [1], [2]])
        }
    }
    func testPairsCoverAndOddTailLTR() {
        let preferences = ReadingPreferences(mode: .leftToRight, doublePages: .enabled, isolateCover: true)
        let result = ReaderLayout.units(pages: pages(6), preferences: preferences, landscape: false, splitPanoramas: false)
        XCTAssertEqual(result.map(\.logicalPages), [[0], [1, 2], [3, 4], [5]])
        XCTAssertEqual(result[1].parts.map(\.page), [1, 2])
    }
    func testPairsRTLAndNoCoverIsolation() {
        let result = ReaderLayout.units(pages: pages(3),
            preferences: ReadingPreferences(mode: .rightToLeft, doublePages: .enabled, isolateCover: false),
            landscape: true, splitPanoramas: false)
        XCTAssertEqual(result[0].parts.map(\.page), [1, 0])
        XCTAssertEqual(result.map(\.logicalPages), [[0, 1], [2]])
    }
    func testAutomaticRotationAndResumeMapping() {
        let preferences = ReadingPreferences(mode: .vertical, doublePages: .automatic, isolateCover: true)
        let portrait = ReaderLayout.units(pages: pages(5), preferences: preferences, landscape: false, splitPanoramas: false)
        let landscape = ReaderLayout.units(pages: pages(5), preferences: preferences, landscape: true, splitPanoramas: false)
        XCTAssertEqual(ReaderLayout.unitIndex(for: 4, units: portrait), 4)
        XCTAssertEqual(ReaderLayout.unitIndex(for: 4, units: landscape), 2)
        XCTAssertEqual(landscape.map(\.logicalPages), [[0], [1, 2], [3, 4]])
    }
    func testPanoramaHalvesRespectRTLAndLogicalIndex() {
        for mode in [ReadingMode.leftToRight, .rightToLeft] {
            let result = ReaderLayout.units(pages: pages(2, wide: [1]), preferences: ReadingPreferences(mode: mode),
                                            landscape: false, splitPanoramas: true)
            XCTAssertEqual(result.map(\.logicalPages), [[0], [1], [1]])
            XCTAssertEqual(result.dropFirst().compactMap { $0.parts.first?.half }, mode == .rightToLeft ? [1, 0] : [0, 1])
            XCTAssertEqual(ReaderLayout.unitIndex(for: 1, units: result), 1)
        }
    }
    func testContinuousModesIgnorePairingAndSplitting() {
        for mode in [ReadingMode.webtoon, .continuousVertical] {
            let result = ReaderLayout.units(pages: pages(3, wide: [1]),
                preferences: ReadingPreferences(mode: mode, doublePages: .enabled, isolateCover: false),
                landscape: true, splitPanoramas: true)
            XCTAssertEqual(result.map(\.logicalPages), [[0], [1], [2]])
            XCTAssertTrue(result.allSatisfy { $0.parts.first?.half == nil })
        }
    }
    func testWholePanoramaInterruptsPairs() {
        let result = ReaderLayout.units(pages: pages(5, wide: [2]),
            preferences: ReadingPreferences(mode: .leftToRight, doublePages: .enabled, isolateCover: false),
            landscape: true, splitPanoramas: false)
        XCTAssertEqual(result.map(\.logicalPages), [[0, 1], [2], [3, 4]])
    }
    func testProgressDurationIsCountedOnlyOnceAcrossPause() {
        var gate = ReaderProgressGate()
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertNil(gate.pause(at: date))
        gate.visible(2, at: date)
        let first = gate.checkpoint(at: date.addingTimeInterval(3))
        XCTAssertEqual(first?.page, 2); XCTAssertEqual(first?.duration, 3)
        XCTAssertNil(gate.checkpoint(at: date.addingTimeInterval(4)))
        XCTAssertEqual(gate.pause(at: date.addingTimeInterval(5))?.duration, 2)
        XCTAssertNil(gate.pause(at: date.addingTimeInterval(5)))
        gate.visible(3, at: date.addingTimeInterval(15))
        XCTAssertEqual(gate.pause(at: date.addingTimeInterval(16))?.duration, 1)
    }
    func testImageBudgetAndOverflow() {
        XCTAssertEqual(ReaderImageBudget.bytes, 64 * 1024 * 1024)
        XCTAssertEqual(ReaderImageBudget.maximumDimension, 4096)
        XCTAssertEqual(ReaderImageBudget.cost(width: 4096, height: 4096), ReaderImageBudget.bytes)
        XCTAssertEqual(ReaderImageBudget.cost(width: Int.max, height: 2), Int.max)
    }
    func testContinuousVisibilityUsesViewportNotAppearance() {
        let frames = [CGRect(x: 0, y: 0, width: 400, height: 3000),
                      CGRect(x: 0, y: 3012, width: 400, height: 200)]
        XCTAssertEqual(ReaderLayout.activeUnit(frames: frames,
            viewport: CGRect(x: 0, y: 2600, width: 400, height: 500)), 0)
        XCTAssertEqual(ReaderLayout.activeUnit(frames: frames,
            viewport: CGRect(x: 0, y: 2900, width: 400, height: 400)), 1)
        XCTAssertNil(ReaderLayout.activeUnit(frames: [], viewport: .zero))
    }
    func testSplitLastPageCompletesOnlyAfterSecondHalf() {
        let units = ReaderLayout.units(pages: pages(1, wide: [0]), preferences: ReadingPreferences(),
                                       landscape: false, splitPanoramas: true)
        XCTAssertFalse(ReaderLayout.completesLogicalPage(unit: 0, units: units))
        XCTAssertTrue(ReaderLayout.completesLogicalPage(unit: 1, units: units))
        let paired = ReaderLayout.units(pages: pages(2),
            preferences: ReadingPreferences(doublePages: .enabled, isolateCover: false),
            landscape: true, splitPanoramas: false)
        XCTAssertEqual(paired[0].logicalPages.max(), 1)
        XCTAssertTrue(ReaderLayout.completesLogicalPage(unit: 0, units: paired))
    }
    func testReaderRejectsArchiveAndMissingFile() throws {
        let id = UUID()
        let file = FileSnapshot(id: id, path: try RelativePath("archive.cbz"), kind: .archive, byteCount: nil)
        let chapter = ChapterSnapshot(id: UUID(), seriesID: UUID(), key: "a", title: "a", number: nil,
            order: 0, isRead: false, isBookmarked: false, lastPageIndex: nil, files: [file],
            pages: [PageSnapshot(id: UUID(), index: 0, fileID: id, entryIndex: nil, width: nil, height: nil)],
            history: nil)
        XCTAssertThrowsError(try ReaderFiles.image(chapter: chapter, page: 0))
        XCTAssertThrowsError(try ReaderFiles.image(chapter: chapter, page: 1))
    }
    func testReaderResolvesImageAndRejectsSymlink() throws {
        #if os(Linux)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        #else
        let directory = FileManager.default.temporaryDirectory
        #endif
        let root = directory.appendingPathComponent(".reader-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root.appendingPathComponent("image.jpg"))
        XCTAssertEqual(try ReaderFiles.resolve(root: root, path: RelativePath("image.jpg")).path,
                       root.resolvingSymlinksInPath().appendingPathComponent("image.jpg").path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("image.jpg"))
        XCTAssertThrowsError(try ReaderFiles.resolve(root: root, path: RelativePath("link")))
        XCTAssertThrowsError(try ReaderFiles.resolve(root: root, path: RelativePath("absent.jpg")))
    }
}
