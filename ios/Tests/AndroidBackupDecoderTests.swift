import Foundation
import XCTest
@testable import MangaiOS

final class AndroidBackupDecoderTests: XCTestCase {
    // Contrat également vérifié par AndroidInteropFixtureTest (kotlinx.serialization).
    // Voir Etape8.txt : le producteur Android n'a pas pu être exécuté sous Linux ici.
    static let goldenHex = "0a3008ffffffffffffffffff011201731a015468e8077002820117"
        + "0a016312014320012801300750feffffffffffffffff01"
    static var golden: Data {
        let hex = Array(goldenHex)
        return Data(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(String(hex[$0...($0 + 1)]), radix: 16)!
        })
    }
    private func varint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        repeat {
            let byte = UInt8(value & 127)
            value >>= 7
            data.append(byte | (value == 0 ? 0 : 128))
        } while value > 0
        return data
    }
    private func integer(_ field: Int, _ value: Int64) -> Data {
        varint(UInt64(field << 3)) + varint(UInt64(bitPattern: value))
    }
    private func blob(_ field: Int, _ bytes: Data) -> Data {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }
    private func text(_ field: Int, _ value: String) -> Data { blob(field, Data(value.utf8)) }
    private func manga(_ extra: Data = Data(), source: Int64 = 0) -> Data {
        blob(1, integer(1, source) + text(2, "s") + text(3, "Série") + extra)
    }
    private func baseline() -> LibraryBackupSnapshot {
        LibraryBackupSnapshot(series: [], categories: [
            CategorySnapshot(id: LibraryIdentity.uncategorizedID, name: "Sans catégorie", order: 0,
                             isSystem: true, seriesIDs: [])
        ], globalPreferences: ReadingPreferences())
    }

    func testGoldenNegativeLongIsNotZigZagAndDefaultFavorite() throws {
        let backup = try AndroidBackupDecoder.decode(Self.golden)
        let series = try XCTUnwrap(backup.series.first)
        XCTAssertEqual(series.source, -1)
        XCTAssertEqual(series.favoriteAt?.timeIntervalSince1970, 1)
        XCTAssertEqual(series.mode, .rightToLeft)
        XCTAssertEqual(series.chapters[0].pending.lastPage, 7)
        XCTAssertEqual(series.chapters[0].order, 0)
        XCTAssertTrue(series.chapters[0].pending.isRead)
        XCTAssertTrue(series.chapters[0].pending.isBookmarked)
    }
    func testFavoriteMillisecondsSecondsFallbackEpochAndFalse() throws {
        // Date passe par l’époque 2001 : tolérer l’arrondi, bien inférieur à une milliseconde.
        for (milliseconds, seconds): (Int64, Double) in [(1234, 1.234), (1235, 1.235)] {
            let favoriteAt = try XCTUnwrap(AndroidBackupDecoder.decode(manga(integer(13, milliseconds))).series[0].favoriteAt)
            XCTAssertEqual(favoriteAt.timeIntervalSince1970, seconds, accuracy: 0.000001)
        }
        XCTAssertEqual(try AndroidBackupDecoder.decode(manga(integer(107, 1234))).series[0].favoriteAt?.timeIntervalSince1970, 1234)
        XCTAssertEqual(try AndroidBackupDecoder.decode(manga()).series[0].favoriteAt?.timeIntervalSince1970, 0)
        XCTAssertNil(try AndroidBackupDecoder.decode(manga(integer(100, 0))).series[0].favoriteAt)
    }
    func testSignedLongExtremesAndInt32Overflow() throws {
        XCTAssertEqual(try AndroidBackupDecoder.decode(manga(source: Int64.min)).series[0].source, Int64.min)
        XCTAssertEqual(try AndroidBackupDecoder.decode(manga(source: Int64.max)).series[0].source, Int64.max)
        XCTAssertThrowsError(try AndroidBackupDecoder.decode(manga(integer(8, Int64.max))))
        XCTAssertEqual(try AndroidBackupDecoder.decode(manga(integer(13, Int64.min))).series[0].favoriteAt?.timeIntervalSince1970, 0)
    }
    func testViewerFlagsOverrideLegacyOnlyWhitelistedMode() throws {
        let series = try AndroidBackupDecoder.decode(manga(integer(14, 1) + integer(103, 12))).series[0]
        XCTAssertEqual(series.mode, .webtoon) // masque 7 ; autres bits non appliqués
        XCTAssertThrowsError(try AndroidBackupDecoder.decode(manga(integer(103, Int64.max))))
        let backup = try AndroidBackupDecoder.decode(manga(integer(14, 3)))
        let without = try AndroidLibraryMerge.plan(backup, baseline: baseline(), importID: UUID(), includeReaderModes: false)
        let with = try AndroidLibraryMerge.plan(backup, baseline: baseline(), importID: UUID(), includeReaderModes: true)
        XCTAssertNil(without.snapshot.series[0].preferences.mode)
        XCTAssertEqual(with.snapshot.series[0].preferences.mode, .vertical)
        XCTAssertEqual(with.snapshot.globalPreferences, baseline().globalPreferences)
    }
    func testIgnoredSensitivePayloadsAreNotDecodedOrLogged() throws {
        let secret = Data([0xff, 0x00, 0xff])
        let data = manga(blob(18, secret) + blob(112, secret)) + blob(104, secret) + blob(105, secret) + blob(106, secret)
        let result = try AndroidBackupDecoder.decode(data)
        XCTAssertTrue(result.diagnostics.contains { $0.contains("tracking") })
        XCTAssertTrue(result.diagnostics.contains { $0.contains("comptes") })
        XCTAssertTrue(result.diagnostics.contains { $0.contains("privées") })
        XCTAssertTrue(result.diagnostics.contains { $0.contains("extensions") })
        let plan = try AndroidLibraryMerge.plan(result, baseline: baseline(), importID: UUID(), includeReaderModes: false)
        XCTAssertTrue(plan.documents.isEmpty)
        XCTAssertFalse(String(describing: result.diagnostics).contains("ff00ff"))
    }
    func testUnknownFieldsWarnButUnknownGroupsReject() throws {
        let result = try AndroidBackupDecoder.decode(manga() + integer(900, 1) + blob(901, Data([0xff])))
        XCTAssertTrue(result.diagnostics.contains { $0.contains("champ inconnu") })
        XCTAssertThrowsError(try AndroidBackupDecoder.decode(manga() + Data([0x0b])))
    }
    func testMalformedTruncatedOverflowZeroTagAndUTF8Rejected() throws {
        for data in [Data(), Data([0]), Data([0x0a, 0x7f]), Data([0x08]) + Data(repeating: 0xff, count: 11),
                     Data([0x08]) + Data(repeating: 0xff, count: 9) + Data([2]),
                     blob(1, integer(1, 0) + text(2, "s") + blob(3, Data([0xff])))] {
            XCTAssertThrowsError(try AndroidBackupDecoder.decode(data))
        }
        for length in 1..<Self.golden.count {
            // Certaines frontières de champs donnent un message valide sans champs optionnels.
            if length < 2 || Self.golden[1] > UInt8(length - 2) {
                XCTAssertThrowsError(try AndroidBackupDecoder.decode(Self.golden.prefix(length)))
            }
        }
    }
    func testMissingRequiredFieldsWrongTypesDuplicateScalarsAndBoolReject() throws {
        for data in [blob(1, text(2, "s") + text(3, "T")),
                     blob(1, integer(1, 0) + text(3, "T")),
                     manga(integer(100, 2)), manga(integer(1, 2)), manga(text(13, "not a date"))] {
            XCTAssertThrowsError(try AndroidBackupDecoder.decode(data))
        }
    }
    func testFieldCountAndTextQuotas() throws {
        var data = manga()
        for _ in 0..<250_001 { data.append(integer(900, 0)) }
        XCTAssertThrowsError(try AndroidBackupDecoder.decode(data))
        XCTAssertThrowsError(try AndroidBackupDecoder.decode(manga(blob(6, Data(repeating: 65, count: 1_048_577)))))
    }
    func testNonfiniteChapterNumberRejectedAndNegativeNumberAbsent() throws {
        let chapter = text(1, "c") + text(2, "C")
        XCTAssertThrowsError(try AndroidBackupDecoder.decode(manga(blob(16, chapter + Data([0x4d, 0, 0, 0x80, 0x7f])))))
        let decoded = try AndroidBackupDecoder.decode(manga(blob(16, chapter + Data([0x4d, 0, 0, 0x80, 0xbf]))))
        XCTAssertNil(decoded.series[0].chapters[0].number)
    }
    func testPendingProgressDatesAndDurationMillisPreservedWithoutPages() throws {
        let chapter = text(1, "c") + text(2, "C") + integer(6, Int64.max) + integer(7, 1000) + integer(8, 2000)
        let history = text(1, "c") + integer(2, 1234) + integer(3, 2500)
        let backup = try AndroidBackupDecoder.decode(manga(blob(16, chapter) + blob(104, history)))
        let plan = try AndroidLibraryMerge.plan(backup, baseline: baseline(), importID: UUID(), includeReaderModes: false)
        let pending = try JSONDecoder().decode(AndroidPendingChapter.self, from: plan.documents[0].1)
        XCTAssertEqual(pending.lastPage, Int64(Int32.max))
        XCTAssertEqual(pending.fetchedMilliseconds, 1000)
        XCTAssertEqual(pending.uploadedMilliseconds, 2000)
        XCTAssertEqual(pending.historyMilliseconds, 1234)
        XCTAssertEqual(pending.durationMilliseconds, 2500)
        let saved = plan.snapshot.series[0].chapters[0]
        XCTAssertTrue(saved.pages.isEmpty)
        XCTAssertNil(saved.history)
        XCTAssertNil(saved.lastPageIndex)
        XCTAssertEqual(saved.files[0].kind, .document)
        try plan.snapshot.validate()
    }
    func testNegativeProgressClampedNegativeDurationRejected() throws {
        let chapter = text(1, "c") + text(2, "C") + integer(6, -1)
        XCTAssertEqual(try AndroidBackupDecoder.decode(manga(blob(16, chapter))).series[0].chapters[0].pending.lastPage, 0)
        XCTAssertThrowsError(try AndroidBackupDecoder.decode(manga(blob(104, text(1, "c") + integer(2, 1) + integer(3, -1)))))
    }
    func testInertRemoteMergeDuplicatesAndLocalIdentities() throws {
        let backup = try AndroidBackupDecoder.decode(Self.golden)
        let first = try AndroidLibraryMerge.plan(backup, baseline: baseline(), importID: UUID(), includeReaderModes: false)
        XCTAssertEqual(first.snapshot.series[0].sourceID, "android:-1")
        XCTAssertEqual(first.snapshot.series[0].sourceKey, "android:s")
        XCTAssertTrue(first.snapshot.series[0].chapters.allSatisfy { $0.pages.isEmpty })
        XCTAssertThrowsError(try AndroidLibraryMerge.plan(backup, baseline: first.snapshot, importID: UUID(), includeReaderModes: false))
        let local = try AndroidLibraryMerge.plan(AndroidBackupDecoder.decode(manga()), baseline: first.snapshot,
                                                 importID: UUID(), includeReaderModes: false)
        XCTAssertEqual(local.snapshot.series[0], first.snapshot.series[0])
        XCTAssertEqual(local.snapshot.series[1].sourceID, "local")
    }
    func testPackedAndUnpackedCategoriesAndMissingAssociationRejected() throws {
        let category = blob(2, text(1, "Catégorie") + integer(3, -2))
        let unpacked = try AndroidBackupDecoder.decode(manga(integer(17, -2)) + category)
        let packed = try AndroidBackupDecoder.decode(manga(blob(17, varint(UInt64(bitPattern: -2)))) + category)
        XCTAssertEqual(unpacked.series[0].categories, packed.series[0].categories)
        let plan = try AndroidLibraryMerge.plan(packed, baseline: baseline(), importID: UUID(), includeReaderModes: false)
        XCTAssertEqual(plan.snapshot.categories[1].seriesIDs, [plan.snapshot.series[0].id])
        XCTAssertThrowsError(try AndroidLibraryMerge.plan(AndroidBackupDecoder.decode(manga(integer(17, 99))),
            baseline: baseline(), importID: UUID(), includeReaderModes: false))
    }
    func testAttachmentClampsPreservesUserMarksTitleAndPendingDocument() throws {
        let backup = try AndroidBackupDecoder.decode(Self.golden)
        let plan = try AndroidLibraryMerge.plan(backup, baseline: baseline(), importID: UUID(), includeReaderModes: false)
        let original = plan.snapshot.series[0].chapters[0]
        let edited = ChapterSnapshot(id: original.id, seriesID: original.seriesID, key: original.key,
            title: "Titre personnel", number: original.number, order: original.order, isRead: false,
            isBookmarked: false, lastPageIndex: nil, files: original.files, pages: [], history: nil)
        var pending = backup.series[0].chapters[0].pending
        pending.historyMilliseconds = 1234
        pending.durationMilliseconds = 2500
        let file = FileSnapshot(id: UUID(), path: try RelativePath("imports/attachment/1.png"), kind: .image, byteCount: 1)
        let page = PageSnapshot(id: UUID(), index: 0, fileID: file.id, entryIndex: nil, width: 2, height: 3)
        let attached = try AndroidLibraryMerge.attaching(edited, files: [file], pages: [page], pending: pending)
        XCTAssertEqual(attached.title, "Titre personnel")
        XCTAssertFalse(attached.isRead)
        XCTAssertFalse(attached.isBookmarked)
        XCTAssertEqual(attached.id, original.id)
        XCTAssertEqual(attached.lastPageIndex, 0)
        XCTAssertEqual(attached.history?.duration, 2.5)
        let history = try XCTUnwrap(attached.history)
        XCTAssertEqual(history.lastReadAt.timeIntervalSince1970, 1.234, accuracy: 0.000001)
        XCTAssertEqual(attached.files.first, original.files.first)
        XCTAssertThrowsError(try AndroidLibraryMerge.attaching(attached, files: [file], pages: [page], pending: pending))
        pending.historyMilliseconds = 1235
        let adjacent = try AndroidLibraryMerge.attaching(edited, files: [file], pages: [page], pending: pending)
        let adjacentHistory = try XCTUnwrap(adjacent.history)
        XCTAssertEqual(adjacentHistory.lastReadAt.timeIntervalSince1970, 1.235, accuracy: 0.000001)
    }
}
