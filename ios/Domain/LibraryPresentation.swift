import Foundation

enum LibrarySort: String, CaseIterable {
    case title = "Titre", recent = "Lecture récente", unread = "Non lus"
}

enum LibrarySelection {
    static func counters(_ series: SeriesSnapshot) -> (read: Int, unread: Int, bookmarked: Int) {
        (series.chapters.filter(\.isRead).count, series.chapters.filter { !$0.isRead }.count,
         series.chapters.filter(\.isBookmarked).count)
    }

    static func filtered(_ series: [SeriesSnapshot], query: String, category: UUID?,
                         inLibraryOnly: Bool, sort: LibrarySort) -> [SeriesSnapshot] {
        series.filter { item in
            (!inLibraryOnly || item.isInLibrary)
                && (query.isEmpty || item.metadata.title.localizedCaseInsensitiveContains(query))
                && (category.map { selected in
                    selected == LibraryIdentity.uncategorizedID
                        ? item.categoryIDs.isEmpty : item.categoryIDs.contains(selected)
                } ?? true)
        }.sorted {
            if sort == .recent {
                let a = $0.chapters.compactMap { $0.history?.lastReadAt }.max() ?? .distantPast
                let b = $1.chapters.compactMap { $0.history?.lastReadAt }.max() ?? .distantPast
                if a != b { return a > b }
            }
            if sort == .unread {
                let a = counters($0).unread, b = counters($1).unread
                if a != b { return a > b }
            }
            let result = $0.metadata.title.localizedStandardCompare($1.metadata.title)
            return result == .orderedSame ? $0.id.uuidString < $1.id.uuidString : result == .orderedAscending
        }
    }

    static func orderedChapters(_ series: SeriesSnapshot) -> [ChapterSnapshot] {
        series.chapters.sorted {
            $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
        }
    }

    static func resume(_ series: SeriesSnapshot) -> ChapterSnapshot? {
        let unread = orderedChapters(series).filter { !$0.isRead && !$0.pages.isEmpty }
        return unread.filter { $0.history != nil }.sorted {
            let a = $0.history?.lastReadAt ?? .distantPast, b = $1.history?.lastReadAt ?? .distantPast
            if a != b { return a > b }
            return $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
        }.first ?? unread.first ?? orderedChapters(series).first { !$0.pages.isEmpty }
    }
}

extension ReadingMode {
    var label: String {
        switch self {
        case .leftToRight: return "Horizontal gauche → droite"
        case .rightToLeft: return "Horizontal droite → gauche"
        case .vertical: return "Vertical paginé"
        case .webtoon: return "Webtoon"
        case .continuousVertical: return "Vertical continu"
        }
    }
}

extension DoublePagePolicy {
    var label: String {
        switch self {
        case .disabled: return "Désactivées"
        case .automatic: return "Automatiques en paysage"
        case .enabled: return "Toujours"
        }
    }
}
