import Foundation

enum DomainError: Error, Equatable {
    case invalidPath
    case invalidValue(String)
    case duplicate(String)
    case notFound(UUID)
    case protectedCategory
}

/// Chemin relatif à la racine locale future, jamais une URL ni un chemin décodé.
struct RelativePath: Hashable, Codable, Sendable {
    let value: String

    init(_ value: String) throws {
        // Le système de fichiers interprète les séparateurs scalaires, même suivis d’un signe combinant.
        let segments = value.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
        let alternativeSeparators = Set("\\\u{2044}\u{2215}\u{29f8}\u{ff0f}\u{ff3c}".unicodeScalars)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: {
                  alternativeSeparators.contains($0) || $0 == ":" || $0 == "%"
                      || CharacterSet.controlCharacters.contains($0)
              }),
              segments.allSatisfy({
                  !$0.isEmpty && !$0.elementsEqual(".".unicodeScalars) && !$0.elementsEqual("..".unicodeScalars)
              }),
              value.unicodeScalars.first != "~" else {
            throw DomainError.invalidPath
        }
        self.value = value
    }

    init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

enum ReadingMode: String, Codable, CaseIterable, Sendable {
    case leftToRight
    case rightToLeft
    case vertical
    case webtoon
    case continuousVertical
}

enum DoublePagePolicy: String, Codable, CaseIterable, Sendable {
    case disabled
    case automatic
    case enabled
}

struct ReadingPreferences: Equatable, Codable, Sendable {
    var mode: ReadingMode = .rightToLeft
    var doublePages: DoublePagePolicy = .disabled
    var isolateCover: Bool = true
}

/// Une valeur absente hérite du réglage global, indépendamment des autres options.
struct SeriesReadingPreferences: Equatable, Codable, Sendable {
    var mode: ReadingMode?
    var doublePages: DoublePagePolicy?
    var isolateCover: Bool?

    func resolved(over global: ReadingPreferences) -> ReadingPreferences {
        ReadingPreferences(
            mode: mode ?? global.mode,
            doublePages: doublePages ?? global.doublePages,
            isolateCover: isolateCover ?? global.isolateCover
        )
    }
}

enum SeriesStatus: String, Codable, CaseIterable, Sendable {
    case unknown, ongoing, completed, hiatus, cancelled
}

enum LocalFileKind: String, Codable, CaseIterable, Sendable {
    case image, archive, document
}

struct SeriesMetadata: Equatable, Sendable {
    var title: String
    var authors: [String] = []
    var artists: [String] = []
    var summary: String = ""
    var genres: [String] = []
    var status: SeriesStatus = .unknown
    var notes: String = ""
    var rating: Double?

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainError.invalidValue("titre")
        }
        if let rating, !rating.isFinite || !(0...10).contains(rating) {
            throw DomainError.invalidValue("note")
        }
    }
}

struct LocalFileInput: Equatable, Sendable {
    var id: UUID = UUID()
    var path: RelativePath
    var kind: LocalFileKind
    var byteCount: Int64?

    func validate() throws {
        if let byteCount, byteCount < 0 {
            throw DomainError.invalidValue("taille")
        }
    }
}

struct LocalPageInput: Equatable, Sendable {
    var id: UUID = UUID()
    var fileID: UUID
    /// Index de l’entrée dans une archive/document ; nil pour une image individuelle.
    var entryIndex: Int?
    var width: Int?
    var height: Int?

    func validate() throws {
        if let entryIndex, entryIndex < 0 { throw DomainError.invalidValue("entrée") }
        if let width, width <= 0 { throw DomainError.invalidValue("largeur") }
        if let height, height <= 0 { throw DomainError.invalidValue("hauteur") }
    }
}

struct NewSeries: Sendable {
    var id: UUID = UUID()
    var sourceID: String = "local"
    var sourceKey: String
    var metadata: SeriesMetadata
    var favoriteAt: Date?
    var cover: LocalFileInput?
}

struct NewChapter: Sendable {
    var id: UUID = UUID()
    var seriesID: UUID
    var key: String
    var title: String
    var number: Double?
    var order: Int
    var files: [LocalFileInput] = []
    /// L’ordre du tableau définit les indices de page, à partir de zéro.
    var pages: [LocalPageInput] = []
}

struct FileSnapshot: Equatable, Sendable {
    let id: UUID
    let path: RelativePath
    let kind: LocalFileKind
    let byteCount: Int64?
}

struct PageSnapshot: Equatable, Sendable {
    let id: UUID
    let index: Int
    let fileID: UUID
    let entryIndex: Int?
    let width: Int?
    let height: Int?
}

struct HistorySnapshot: Equatable, Sendable {
    let id: UUID
    let chapterID: UUID
    let lastReadAt: Date
    let lastPageIndex: Int
    let duration: TimeInterval
}

struct ChapterSnapshot: Equatable, Sendable {
    let id: UUID
    let seriesID: UUID
    let key: String
    let title: String
    let number: Double?
    let order: Int
    let isRead: Bool
    let isBookmarked: Bool
    let lastPageIndex: Int?
    let files: [FileSnapshot]
    let pages: [PageSnapshot]
    let history: HistorySnapshot?
    var pageCount: Int { pages.count }
}

struct SeriesSnapshot: Equatable, Sendable {
    let id: UUID
    let sourceID: String
    let sourceKey: String
    let metadata: SeriesMetadata
    let favoriteAt: Date?
    let cover: FileSnapshot?
    let categoryIDs: [UUID]
    let preferences: SeriesReadingPreferences
    let chapters: [ChapterSnapshot]
    var isInLibrary: Bool { favoriteAt != nil }
}

struct CategorySnapshot: Equatable, Sendable {
    let id: UUID
    let name: String
    let order: Int
    let isSystem: Bool
    let seriesIDs: [UUID]
}

enum LibraryIdentity {
    static let uncategorizedID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let globalSettingsID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    /// Préfixes de longueur UTF-8 : aucun séparateur présent dans une clé ne peut créer de collision.
    static func key(_ first: String, _ second: String) -> String {
        "\(first.utf8.count):\(first)\(second.utf8.count):\(second)"
    }

    static func validateKey(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DomainError.invalidValue("clé")
        }
    }
}
