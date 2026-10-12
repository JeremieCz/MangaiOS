import Foundation
import XCTest
@testable import MangaiOS

final class LegalDocumentTests: XCTestCase {
    func testApacheLicenseIsBundled() throws {
        let text = try LegalDocument.license.text()

        XCTAssertTrue(text.contains("Apache License"))
        XCTAssertTrue(text.contains("Version 2.0, January 2004"))
    }

    func testNoticePreservesAttributionsAndDisclosesMissingOriginal() throws {
        let text = try LegalDocument.projectNotice.text()

        XCTAssertTrue(text.contains("Copyright © 2015 Javier Tomás"))
        XCTAssertTrue(text.contains("Copyright © 2024 Mihon Open Source Project"))
        XCTAssertTrue(text.contains("Aucun fichier NOTICE original"))
    }

    func testMissingResourceThrows() {
        XCTAssertThrowsError(try LegalDocument.license.text(in: Bundle(for: Self.self)))
    }
}
