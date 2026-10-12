import Foundation
import SwiftData

// Les objets persistants restent internes au dépôt ; ses consommateurs reçoivent des valeurs.
@Model
final class StoredSeries {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var identityKey: String
    var sourceID: String
    var sourceKey: String
    var title: String
    var authors: [String]
    var artists: [String]
    var summary: String
    var genres: [String]
    var statusRaw: String
    var notes: String
    var rating: Double?
    var favoriteAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \StoredChapter.series)
    var chapters: [StoredChapter] = []
    @Relationship(deleteRule: .nullify, inverse: \StoredCategory.series)
    var categories: [StoredCategory] = []
    @Relationship(deleteRule: .cascade, inverse: \StoredSeriesPreferences.series)
    var preferences: StoredSeriesPreferences?
    @Relationship(deleteRule: .cascade, inverse: \StoredFile.coverSeries)
    var cover: StoredFile?

    init(_ input: NewSeries) {
        id = input.id
        sourceID = input.sourceID
        sourceKey = input.sourceKey
        identityKey = LibraryIdentity.key(input.sourceID, input.sourceKey)
        title = input.metadata.title
        authors = input.metadata.authors
        artists = input.metadata.artists
        summary = input.metadata.summary
        genres = input.metadata.genres
        statusRaw = input.metadata.status.rawValue
        notes = input.metadata.notes
        rating = input.metadata.rating
        favoriteAt = input.favoriteAt
    }
}

@Model
final class StoredChapter {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var identityKey: String
    var key: String
    var title: String
    var number: Double?
    var order: Int
    var isRead: Bool = false
    var isBookmarked: Bool = false
    var lastPageIndex: Int?
    var series: StoredSeries?
    @Relationship(deleteRule: .cascade, inverse: \StoredFile.chapter)
    var files: [StoredFile] = []
    @Relationship(deleteRule: .cascade, inverse: \StoredPage.chapter)
    var pages: [StoredPage] = []
    @Relationship(deleteRule: .cascade, inverse: \StoredHistory.chapter)
    var history: StoredHistory?

    init(_ input: NewChapter) {
        id = input.id
        identityKey = LibraryIdentity.key(input.seriesID.uuidString, input.key)
        key = input.key
        title = input.title
        number = input.number
        order = input.order
    }
}

@Model
final class StoredCategory {
    @Attribute(.unique) var id: UUID
    var name: String
    var order: Int
    var isSystem: Bool
    var series: [StoredSeries] = []

    init(id: UUID, name: String, order: Int, isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.order = order
        self.isSystem = isSystem
    }
}

@Model
final class StoredFile {
    @Attribute(.unique) var id: UUID
    var relativePath: String
    var kindRaw: String
    var byteCount: Int64?
    var chapter: StoredChapter?
    var coverSeries: StoredSeries?
    @Relationship(deleteRule: .nullify, inverse: \StoredPage.file)
    var pages: [StoredPage] = []

    init(_ input: LocalFileInput) {
        id = input.id
        relativePath = input.path.value
        kindRaw = input.kind.rawValue
        byteCount = input.byteCount
    }
}

@Model
final class StoredPage {
    @Attribute(.unique) var id: UUID
    var index: Int
    var entryIndex: Int?
    var width: Int?
    var height: Int?
    var chapter: StoredChapter?
    var file: StoredFile?

    init(_ input: LocalPageInput, index: Int) {
        id = input.id
        self.index = index
        entryIndex = input.entryIndex
        width = input.width
        height = input.height
    }
}

@Model
final class StoredHistory {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var chapterID: UUID
    var lastReadAt: Date
    var lastPageIndex: Int
    var duration: Double
    var chapter: StoredChapter?

    init(id: UUID = UUID(), chapterID: UUID, date: Date, page: Int, duration: TimeInterval) {
        self.id = id
        self.chapterID = chapterID
        lastReadAt = date
        lastPageIndex = page
        self.duration = duration
    }
}

@Model
final class StoredGlobalPreferences {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var key: String
    var modeRaw: String
    var doublePagesRaw: String
    var isolateCover: Bool

    init() {
        id = LibraryIdentity.globalSettingsID
        key = "global"
        let defaults = ReadingPreferences()
        modeRaw = defaults.mode.rawValue
        doublePagesRaw = defaults.doublePages.rawValue
        isolateCover = defaults.isolateCover
    }
}

@Model
final class StoredSeriesPreferences {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var seriesID: UUID
    var modeRaw: String?
    var doublePagesRaw: String?
    var isolateCover: Bool?
    var series: StoredSeries?

    init(id: UUID = UUID(), seriesID: UUID) {
        self.id = id
        self.seriesID = seriesID
    }
}
