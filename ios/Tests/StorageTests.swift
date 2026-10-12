import Foundation
import SwiftData
import XCTest
@testable import MangaiOS

final class StorageTests: XCTestCase {
    func testMetadataDefaults() {
        let date = Date(timeIntervalSince1970: 123)
        let metadata = StorageMetadata(createdAt: date)

        XCTAssertEqual(metadata.key, "application")
        XCTAssertEqual(metadata.createdAt, date)
    }

    @MainActor
    func testMetadataRoundTrip() throws {
        let container = try StorageFactory.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 456)
        context.insert(StorageMetadata(createdAt: date))
        try context.save()

        let readingContext = ModelContext(container)
        let records = try readingContext.fetch(FetchDescriptor<StorageMetadata>())

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.key, "application")
        XCTAssertEqual(records.first?.createdAt, date)
    }

    @MainActor
    func testInMemoryContainersAreIsolated() throws {
        let first = try StorageFactory.makeContainer(inMemory: true)
        let firstContext = ModelContext(first)
        firstContext.insert(StorageMetadata())
        try firstContext.save()

        let second = try StorageFactory.makeContainer(inMemory: true)
        let secondContext = ModelContext(second)

        XCTAssertEqual(
            try secondContext.fetchCount(FetchDescriptor<StorageMetadata>()),
            0
        )
    }
}
