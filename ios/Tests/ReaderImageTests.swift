import Foundation
import UIKit
import XCTest
@testable import MangaiOS

final class ReaderImageTests: XCTestCase {
    @MainActor
    func testDownsamplingBudgetAndMemoryClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-image-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 5000, height: 100), format: format).jpegData(withCompressionQuality: 0.8) {
            UIColor.white.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 5000, height: 100))
        }
        try data.write(to: root.appendingPathComponent("page.jpg"))
        let file = FileSnapshot(id: UUID(), path: try RelativePath("page.jpg"), kind: .image, byteCount: nil)
        let loader = ReaderImages()
        let decoded = try await loader.load(root: root, file: file)
        XCTAssertLessThanOrEqual(decoded.image.cgImage?.width ?? Int.max, 4096)
        let cost = await loader.cachedByteCount
        XCTAssertGreaterThan(cost, 0)
        XCTAssertLessThanOrEqual(cost, ReaderImageBudget.bytes)
        await loader.clear()
        let cleared = await loader.cachedByteCount
        XCTAssertEqual(cleared, 0)
        let generation = UUID()
        let first = try await loader.load(root: root, file: file, generation: generation)
        let cached = try await loader.load(root: root, file: file, generation: generation)
        XCTAssertTrue(first === cached)
        let replacement = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format)
            .jpegData(withCompressionQuality: 0.8) {
                UIColor.black.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
            }
        try replacement.write(to: root.appendingPathComponent("page.jpg"))
        let restored = try await loader.load(root: root, file: file, generation: UUID())
        XCTAssertFalse(first === restored)
        XCTAssertEqual(restored.image.cgImage?.width, 20)
        await loader.clear()
    }

    func testCorruptPageFailsWithoutEnteringCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-corrupt-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("page.jpg"))
        let loader = ReaderImages()
        let file = FileSnapshot(id: UUID(), path: try RelativePath("page.jpg"), kind: .image, byteCount: nil)
        do { _ = try await loader.load(root: root, file: file); XCTFail("Image corrompue acceptée") }
        catch { }
        let cost = await loader.cachedByteCount
        XCTAssertEqual(cost, 0)
    }
}
