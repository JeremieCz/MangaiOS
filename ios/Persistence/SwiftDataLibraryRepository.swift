import Foundation
import SwiftData

@MainActor
final class SwiftDataLibraryRepository: LibraryRepository {
    // Ne pas utiliser mainContext : un rollback ne doit pas annuler les travaux d’un autre composant.
    private let context: ModelContext

    init(container: ModelContainer) throws {
        context = ModelContext(container)
        context.autosaveEnabled = false
        try transaction {
            let systemID = LibraryIdentity.uncategorizedID
            let existing = try context.fetch(FetchDescriptor<StoredCategory>(
                predicate: #Predicate { $0.id == systemID }
            ))
            if let category = existing.first {
                guard category.isSystem, category.order == 0, category.name == "Sans catégorie" else {
                    throw DomainError.invalidValue("catégorie système")
                }
            } else {
                context.insert(StoredCategory(id: systemID, name: "Sans catégorie", order: 0, isSystem: true))
            }
            let globals = try context.fetch(FetchDescriptor<StoredGlobalPreferences>())
            if globals.isEmpty {
                context.insert(StoredGlobalPreferences())
            } else {
                guard globals.count == 1, globals[0].id == LibraryIdentity.globalSettingsID,
                      globals[0].key == "global" else {
                    throw DomainError.invalidValue("réglages globaux")
                }
            }
        }
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        do {
            let result = try operation()
            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    private func storedSeries(_ id: UUID) throws -> StoredSeries {
        guard let value = try context.fetch(FetchDescriptor<StoredSeries>(
            predicate: #Predicate { $0.id == id }
        )).first else { throw DomainError.notFound(id) }
        return value
    }

    private func storedChapter(_ id: UUID) throws -> StoredChapter {
        guard let value = try context.fetch(FetchDescriptor<StoredChapter>(
            predicate: #Predicate { $0.id == id }
        )).first else { throw DomainError.notFound(id) }
        return value
    }

    private func storedCategory(_ id: UUID) throws -> StoredCategory {
        guard let value = try context.fetch(FetchDescriptor<StoredCategory>(
            predicate: #Predicate { $0.id == id }
        )).first else { throw DomainError.notFound(id) }
        return value
    }

    private func storedGlobalPreferences() throws -> StoredGlobalPreferences {
        guard let value = try context.fetch(FetchDescriptor<StoredGlobalPreferences>()).first else {
            throw DomainError.invalidValue("réglages globaux absents")
        }
        return value
    }

    private func validateDate(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw DomainError.invalidValue("date")
        }
    }

    private func requireNewFile(_ input: LocalFileInput) throws {
        try input.validate()
        let id = input.id
        guard try context.fetchCount(FetchDescriptor<StoredFile>(
            predicate: #Predicate { $0.id == id }
        )) == 0 else { throw DomainError.duplicate("fichier") }
    }

    private func freshPreferencesID() throws -> UUID {
        while true {
            let id = UUID()
            if try context.fetchCount(FetchDescriptor<StoredSeriesPreferences>(
                predicate: #Predicate { $0.id == id }
            )) == 0 { return id }
        }
    }

    private func freshHistoryID() throws -> UUID {
        while true {
            let id = UUID()
            if try context.fetchCount(FetchDescriptor<StoredHistory>(
                predicate: #Predicate { $0.id == id }
            )) == 0 { return id }
        }
    }

    func createSeries(_ input: NewSeries) throws -> SeriesSnapshot {
        try transaction { try insertSeries(input) }
    }

    private func insertSeries(_ input: NewSeries) throws -> SeriesSnapshot {
            try input.metadata.validate()
            try LibraryIdentity.validateKey(input.sourceID)
            try LibraryIdentity.validateKey(input.sourceKey)
            if let date = input.favoriteAt { try validateDate(date) }
            let id = input.id
            let identity = LibraryIdentity.key(input.sourceID, input.sourceKey)
            guard try context.fetchCount(FetchDescriptor<StoredSeries>(
                predicate: #Predicate { $0.id == id || $0.identityKey == identity }
            )) == 0 else { throw DomainError.duplicate("série") }
            guard try context.fetchCount(FetchDescriptor<StoredSeriesPreferences>(
                predicate: #Predicate { $0.seriesID == id }
            )) == 0 else { throw DomainError.duplicate("réglages de série") }
            let preferencesID = try freshPreferencesID()
            if let cover = input.cover { try requireNewFile(cover) }
            let value = StoredSeries(input)
            context.insert(value)
            if let cover = input.cover {
                let file = StoredFile(cover)
                context.insert(file)
                value.cover = file
            }
            let preferences = StoredSeriesPreferences(id: preferencesID, seriesID: id)
            context.insert(preferences)
            value.preferences = preferences
            return try snapshot(value)
    }

    func series(id: UUID) throws -> SeriesSnapshot {
        try snapshot(storedSeries(id))
    }

    func allSeries(inLibraryOnly: Bool = false) throws -> [SeriesSnapshot] {
        try context.fetch(FetchDescriptor<StoredSeries>())
            .filter { !inLibraryOnly || $0.favoriteAt != nil }
            .sorted { $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString : $0.title < $1.title }
            .map { try snapshot($0) }
    }

    func updateSeries(id: UUID, metadata: SeriesMetadata) throws {
        try transaction {
            try metadata.validate()
            let value = try storedSeries(id)
            value.title = metadata.title
            value.authors = metadata.authors
            value.artists = metadata.artists
            value.summary = metadata.summary
            value.genres = metadata.genres
            value.statusRaw = metadata.status.rawValue
            value.notes = metadata.notes
            value.rating = metadata.rating
        }
    }

    func setFavorite(id: UUID, at date: Date?) throws {
        try transaction {
            if let date { try validateDate(date) }
            try storedSeries(id).favoriteAt = date
        }
    }

    func deleteSeries(id: UUID) throws {
        try transaction { context.delete(try storedSeries(id)) }
    }

    func createChapter(_ input: NewChapter) throws -> ChapterSnapshot {
        try transaction { try insertChapter(input) }
    }

    func commitImport(series: NewSeries?, chapter: NewChapter) throws -> ChapterSnapshot {
        try transaction {
            if let series {
                guard series.id == chapter.seriesID else {
                    throw DomainError.invalidValue("série du chapitre importé")
                }
                if let cover = series.cover, chapter.files.contains(where: { $0.id == cover.id }) {
                    throw DomainError.duplicate("fichier de couverture et de chapitre")
                }
                _ = try insertSeries(series)
            }
            return try insertChapter(chapter)
        }
    }

    private func insertChapter(_ input: NewChapter) throws -> ChapterSnapshot {
            let parent = try storedSeries(input.seriesID)
            try LibraryIdentity.validateKey(input.key)
            guard input.order >= 0 else { throw DomainError.invalidValue("ordre") }
            if let number = input.number, !number.isFinite || number < 0 {
                throw DomainError.invalidValue("numéro")
            }
            let id = input.id
            let identity = LibraryIdentity.key(input.seriesID.uuidString, input.key)
            guard try context.fetchCount(FetchDescriptor<StoredChapter>(
                predicate: #Predicate { $0.id == id || $0.identityKey == identity }
            )) == 0 else { throw DomainError.duplicate("chapitre") }
            guard Set(input.files.map(\.id)).count == input.files.count,
                  Set(input.pages.map(\.id)).count == input.pages.count else {
                throw DomainError.duplicate("contenu local")
            }
            let fileIDs = Set(input.files.map(\.id))
            for file in input.files { try requireNewFile(file) }
            for page in input.pages {
                try page.validate()
                guard fileIDs.contains(page.fileID) else { throw DomainError.notFound(page.fileID) }
                let pageID = page.id
                guard try context.fetchCount(FetchDescriptor<StoredPage>(
                    predicate: #Predicate { $0.id == pageID }
                )) == 0 else { throw DomainError.duplicate("page") }
            }
            let value = StoredChapter(input)
            context.insert(value)
            value.series = parent
            var files: [UUID: StoredFile] = [:]
            for inputFile in input.files {
                let file = StoredFile(inputFile)
                context.insert(file)
                file.chapter = value
                files[file.id] = file
            }
            for (index, inputPage) in input.pages.enumerated() {
                let page = StoredPage(inputPage, index: index)
                context.insert(page)
                page.chapter = value
                page.file = files[inputPage.fileID]
            }
            return try snapshot(value)
    }

    func chapter(id: UUID) throws -> ChapterSnapshot {
        try snapshot(storedChapter(id))
    }

    func deleteChapter(id: UUID) throws {
        try transaction { context.delete(try storedChapter(id)) }
    }

    func setRead(chapterID: UUID, isRead: Bool) throws {
        try transaction {
            let value = try storedChapter(chapterID)
            value.isRead = isRead
            if !isRead { value.lastPageIndex = nil }
        }
    }

    func setBookmark(chapterID: UUID, isBookmarked: Bool) throws {
        try transaction { try storedChapter(chapterID).isBookmarked = isBookmarked }
    }

    func recordProgress(chapterID: UUID, pageIndex: Int, duration: TimeInterval, at date: Date) throws {
        try recordReaderProgress(chapterID: chapterID, pageIndex: pageIndex, duration: duration, at: date,
                                 completed: true)
    }

    func recordReaderProgress(chapterID: UUID, pageIndex: Int, duration: TimeInterval, at date: Date,
                              completed: Bool) throws {
        try transaction {
            try validateDate(date)
            guard duration.isFinite, duration >= 0 else { throw DomainError.invalidValue("durée") }
            let value = try storedChapter(chapterID)
            guard pageIndex >= 0, pageIndex < value.pages.count else {
                throw DomainError.invalidValue("page")
            }
            let total = (value.history?.duration ?? 0) + duration
            guard total.isFinite else { throw DomainError.invalidValue("durée cumulée") }
            value.lastPageIndex = pageIndex
            if completed && pageIndex == value.pages.count - 1 { value.isRead = true }
            if let history = value.history {
                history.duration = total
                // Un événement ancien contribue à la durée, sans reculer la date agrégée.
                if date >= history.lastReadAt {
                    history.lastReadAt = date
                    history.lastPageIndex = pageIndex
                }
            } else {
                guard try context.fetchCount(FetchDescriptor<StoredHistory>(
                    predicate: #Predicate { $0.chapterID == chapterID }
                )) == 0 else { throw DomainError.duplicate("historique") }
                let history = StoredHistory(
                    id: try freshHistoryID(), chapterID: chapterID, date: date, page: pageIndex, duration: total
                )
                context.insert(history)
                value.history = history
            }
        }
    }

    func history() throws -> [HistorySnapshot] {
        try context.fetch(FetchDescriptor<StoredHistory>())
            .sorted {
                $0.lastReadAt == $1.lastReadAt
                    ? $0.chapterID.uuidString < $1.chapterID.uuidString : $0.lastReadAt > $1.lastReadAt
            }
            .map(historySnapshot)
    }

    func categories() throws -> [CategorySnapshot] {
        let all = try context.fetch(FetchDescriptor<StoredSeries>())
        return try orderedCategories().map { value in
            CategorySnapshot(
                id: value.id, name: value.name, order: value.order, isSystem: value.isSystem,
                seriesIDs: (value.isSystem ? all.filter { $0.categories.isEmpty } : value.series)
                    .map(\.id).sorted { $0.uuidString < $1.uuidString }
            )
        }
    }

    private func orderedCategories() throws -> [StoredCategory] {
        try context.fetch(FetchDescriptor<StoredCategory>())
            .sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
    }

    private func validateCategoryName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainError.invalidValue("nom de catégorie")
        }
    }

    func createCategory(id: UUID = UUID(), name: String) throws -> CategorySnapshot {
        try transaction {
            try validateCategoryName(name)
            guard try context.fetchCount(FetchDescriptor<StoredCategory>(
                predicate: #Predicate { $0.id == id }
            )) == 0 else { throw DomainError.duplicate("catégorie") }
            let order = try orderedCategories().count
            context.insert(StoredCategory(id: id, name: name, order: order))
            return CategorySnapshot(id: id, name: name, order: order, isSystem: false, seriesIDs: [])
        }
    }

    func renameCategory(id: UUID, name: String) throws {
        try transaction {
            let value = try storedCategory(id)
            guard !value.isSystem else { throw DomainError.protectedCategory }
            try validateCategoryName(name)
            value.name = name
        }
    }

    func reorderCategories(ids: [UUID]) throws {
        try transaction {
            let users = try orderedCategories().filter { !$0.isSystem }
            guard ids.count == users.count, Set(ids).count == ids.count,
                  Set(ids) == Set(users.map(\.id)) else {
                throw DomainError.invalidValue("ordre des catégories")
            }
            let byID = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
            for (index, id) in ids.enumerated() { byID[id]?.order = index + 1 }
        }
    }

    func deleteCategory(id: UUID) throws {
        try transaction {
            let value = try storedCategory(id)
            guard !value.isSystem else { throw DomainError.protectedCategory }
            // Détacher explicitement les deux côtés avant suppression d’une catégorie.
            for series in value.series { series.categories.removeAll { $0.id == id } }
            value.series = []
            context.delete(value)
            let remaining = try orderedCategories().filter { $0.id != id && !$0.isSystem }
            for (index, category) in remaining.enumerated() { category.order = index + 1 }
        }
    }

    func setCategories(seriesID: UUID, categoryIDs: [UUID]) throws {
        try transaction {
            let value = try storedSeries(seriesID)
            guard Set(categoryIDs).count == categoryIDs.count else {
                throw DomainError.duplicate("association série-catégorie")
            }
            var categories: [StoredCategory] = []
            for id in categoryIDs {
                let category = try storedCategory(id)
                guard !category.isSystem else { throw DomainError.protectedCategory }
                categories.append(category)
            }
            value.categories = categories
        }
    }

    func globalPreferences() throws -> ReadingPreferences {
        let value = try storedGlobalPreferences()
        guard let mode = ReadingMode(rawValue: value.modeRaw),
              let doublePages = DoublePagePolicy(rawValue: value.doublePagesRaw) else {
            throw DomainError.invalidValue("réglages globaux")
        }
        return ReadingPreferences(mode: mode, doublePages: doublePages, isolateCover: value.isolateCover)
    }

    func setGlobalPreferences(_ value: ReadingPreferences) throws {
        try transaction {
            let stored = try storedGlobalPreferences()
            stored.modeRaw = value.mode.rawValue
            stored.doublePagesRaw = value.doublePages.rawValue
            stored.isolateCover = value.isolateCover
        }
    }

    func setSeriesPreferences(seriesID: UUID, value: SeriesReadingPreferences) throws {
        try transaction {
            let series = try storedSeries(seriesID)
            guard let stored = series.preferences else {
                throw DomainError.invalidValue("réglages de série absents")
            }
            stored.modeRaw = value.mode?.rawValue
            stored.doublePagesRaw = value.doublePages?.rawValue
            stored.isolateCover = value.isolateCover
        }
    }

    func resolvedPreferences(seriesID: UUID) throws -> ReadingPreferences {
        try series(id: seriesID).preferences.resolved(over: globalPreferences())
    }

    private func snapshot(_ value: StoredSeries) throws -> SeriesSnapshot {
        guard let status = SeriesStatus(rawValue: value.statusRaw), let stored = value.preferences else {
            throw DomainError.invalidValue("série persistée")
        }
        if let raw = stored.modeRaw, ReadingMode(rawValue: raw) == nil {
            throw DomainError.invalidValue("mode de série")
        }
        if let raw = stored.doublePagesRaw, DoublePagePolicy(rawValue: raw) == nil {
            throw DomainError.invalidValue("doubles pages de série")
        }
        return SeriesSnapshot(
            id: value.id, sourceID: value.sourceID, sourceKey: value.sourceKey,
            metadata: SeriesMetadata(
                title: value.title, authors: value.authors, artists: value.artists,
                summary: value.summary, genres: value.genres, status: status, notes: value.notes, rating: value.rating
            ),
            favoriteAt: value.favoriteAt, cover: try value.cover.map { try snapshot($0) },
            categoryIDs: value.categories.sorted { $0.order < $1.order }.map(\.id),
            preferences: SeriesReadingPreferences(
                mode: stored.modeRaw.flatMap(ReadingMode.init(rawValue:)),
                doublePages: stored.doublePagesRaw.flatMap(DoublePagePolicy.init(rawValue:)),
                isolateCover: stored.isolateCover
            ),
            chapters: try value.chapters.sorted {
                $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
            }.map { try snapshot($0) }
        )
    }

    private func snapshot(_ value: StoredFile) throws -> FileSnapshot {
        guard let kind = LocalFileKind(rawValue: value.kindRaw) else {
            throw DomainError.invalidValue("type de fichier")
        }
        return FileSnapshot(
            id: value.id, path: try RelativePath(value.relativePath), kind: kind, byteCount: value.byteCount
        )
    }

    private func snapshot(_ value: StoredChapter) throws -> ChapterSnapshot {
        guard let seriesID = value.series?.id else { throw DomainError.invalidValue("chapitre orphelin") }
        return ChapterSnapshot(
            id: value.id, seriesID: seriesID, key: value.key, title: value.title,
            number: value.number, order: value.order, isRead: value.isRead, isBookmarked: value.isBookmarked,
            lastPageIndex: value.lastPageIndex,
            files: try value.files.sorted { $0.id.uuidString < $1.id.uuidString }.map { try snapshot($0) },
            pages: try value.pages.sorted { $0.index < $1.index }.map { page in
                guard let fileID = page.file?.id else { throw DomainError.invalidValue("page sans fichier") }
                return PageSnapshot(
                    id: page.id, index: page.index, fileID: fileID, entryIndex: page.entryIndex,
                    width: page.width, height: page.height
                )
            },
            history: value.history.map(historySnapshot)
        )
    }

    private func historySnapshot(_ value: StoredHistory) -> HistorySnapshot {
        HistorySnapshot(
            id: value.id, chapterID: value.chapterID, lastReadAt: value.lastReadAt,
            lastPageIndex: value.lastPageIndex, duration: value.duration
        )
    }
}
