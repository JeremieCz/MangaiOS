import Foundation

/// Format indépendant des schémas SwiftData et de leurs fichiers internes.
struct LibraryBackupSnapshot: Codable, Equatable, Sendable {
    let series: [SeriesSnapshot]
    let categories: [CategorySnapshot]
    let globalPreferences: ReadingPreferences

    var files: [FileSnapshot] {
        series.flatMap { value in
            (value.cover.map { [$0] } ?? []) + value.chapters.flatMap(\.files)
        }
    }

    func validate() throws {
        var ids: Set<UUID> = [LibraryIdentity.globalSettingsID]
        func unique(_ id: UUID) throws {
            guard ids.insert(id).inserted else { throw DomainError.duplicate("identifiant de sauvegarde") }
        }
        func text(_ value: String) throws {
            guard value.utf8.count <= 1_048_576 else { throw DomainError.invalidValue("texte trop long") }
        }
        func date(_ value: Date?) throws {
            if let value, !value.timeIntervalSinceReferenceDate.isFinite {
                throw DomainError.invalidValue("date de sauvegarde")
            }
        }
        guard series.count <= 10_000, categories.count <= 10_000,
              categories.map(\.order).sorted() == Array(0..<categories.count),
              categories.filter(\.isSystem).count == 1,
              let system = categories.first(where: \.isSystem),
              system.id == LibraryIdentity.uncategorizedID, system.order == 0,
              system.name == "Sans catégorie" else { throw DomainError.invalidValue("catégories de sauvegarde") }
        let categoryIDs = Set(categories.filter { !$0.isSystem }.map(\.id))
        var identities: Set<String> = []
        var paths: [String: String] = [:]
        var fileSizes: [String: Int64] = [:]
        var chapterCount = 0
        var pageCount = 0
        func file(_ value: FileSnapshot) throws {
            try unique(value.id)
            try LocalFileInput(id: value.id, path: value.path, kind: value.kind, byteCount: value.byteCount).validate()
            let normalized = try ImportPolicy.normalized(value.path.value)
            // Réserver staging à l’import ; ne jamais restaurer ses fichiers de travail.
            guard normalized != "staging", !normalized.hasPrefix("staging/") else {
                throw DomainError.invalidPath
            }
            if let existing = paths[normalized], existing != value.path.value { throw DomainError.duplicate("chemin normalisé") }
            paths[normalized] = value.path.value
            if let size = value.byteCount {
                if let old = fileSizes[normalized], old != size { throw DomainError.invalidValue("tailles du même fichier") }
                fileSizes[normalized] = size
            }
        }
        for category in categories {
            try unique(category.id)
            try LibraryIdentity.validateKey(category.name)
            try text(category.name)
            guard Set(category.seriesIDs).count == category.seriesIDs.count else { throw DomainError.duplicate("association") }
        }
        for value in series {
            try unique(value.id)
            try LibraryIdentity.validateKey(value.sourceID)
            try LibraryIdentity.validateKey(value.sourceKey)
            try text(value.sourceID); try text(value.sourceKey)
            guard identities.insert(LibraryIdentity.key(value.sourceID, value.sourceKey)).inserted else {
                throw DomainError.duplicate("identité de série")
            }
            try value.metadata.validate()
            for string in [value.metadata.title, value.metadata.summary, value.metadata.notes]
                + value.metadata.authors + value.metadata.artists + value.metadata.genres { try text(string) }
            try date(value.favoriteAt)
            if let cover = value.cover { try file(cover) }
            guard Set(value.categoryIDs).count == value.categoryIDs.count,
                  Set(value.categoryIDs).isSubset(of: categoryIDs) else { throw DomainError.invalidValue("association de catégorie") }
            var keys: Set<String> = []
            for chapter in value.chapters {
                chapterCount += 1
                pageCount += chapter.pages.count
                guard chapterCount <= 30_000, pageCount <= 100_000, chapter.seriesID == value.id,
                      chapter.order >= 0, chapter.number.map({ $0.isFinite && $0 >= 0 }) ?? true,
                      keys.insert(chapter.key).inserted else { throw DomainError.invalidValue("chapitre de sauvegarde") }
                try unique(chapter.id)
                try LibraryIdentity.validateKey(chapter.key)
                try text(chapter.key); try text(chapter.title)
                for item in chapter.files { try file(item) }
                let fileIDs = Set(chapter.files.map(\.id))
                guard chapter.pages.map(\.index) == Array(0..<chapter.pages.count),
                      chapter.lastPageIndex.map({ chapter.pages.indices.contains($0) }) ?? true else {
                    throw DomainError.invalidValue("progression ou ordre des pages")
                }
                for page in chapter.pages {
                    try unique(page.id)
                    try LocalPageInput(id: page.id, fileID: page.fileID, entryIndex: page.entryIndex,
                                       width: page.width, height: page.height).validate()
                    guard fileIDs.contains(page.fileID) else { throw DomainError.notFound(page.fileID) }
                }
                if let history = chapter.history {
                    try unique(history.id)
                    try date(history.lastReadAt)
                    guard history.chapterID == chapter.id, chapter.pages.indices.contains(history.lastPageIndex),
                          history.duration.isFinite, history.duration >= 0 else { throw DomainError.invalidValue("historique") }
                }
            }
        }
        for category in categories {
            let expected = Set(series.filter {
                category.isSystem ? $0.categoryIDs.isEmpty : $0.categoryIDs.contains(category.id)
            }.map(\.id))
            guard Set(category.seriesIDs) == expected else { throw DomainError.invalidValue("association inverse") }
        }
        // Un fichier ne peut également servir de dossier à un autre.
        let normalizedPaths = Set(paths.keys)
        for path in normalizedPaths {
            var components = path.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                guard !normalizedPaths.contains(components.joined(separator: "/")) else { throw DomainError.invalidPath }
            }
        }
    }
}
