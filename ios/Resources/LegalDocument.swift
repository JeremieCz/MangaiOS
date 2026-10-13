import Foundation

enum LegalDocument: String, CaseIterable, Identifiable {
    case projectNotice = "NOTICE"
    case license = "LICENSE"
    case zipFoundation = "ZIPFoundation-LICENSE"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projectNotice: "Notice du projet iOS"
        case .license: "Licence Apache 2.0"
        case .zipFoundation: "ZIPFoundation 0.9.20 — MIT"
        }
    }

    func text(in bundle: Bundle = .main) throws -> String {
        guard let url = bundle.url(forResource: rawValue, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
