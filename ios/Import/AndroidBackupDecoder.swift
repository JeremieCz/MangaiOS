import Foundation

enum AndroidBackupError: Error, LocalizedError {
    case invalid
    case limit
    var errorDescription: String? {
        switch self {
        case .invalid: "Sauvegarde Android mal formée ou incompatible."
        case .limit: "Sauvegarde Android au-delà des limites de sécurité."
        }
    }
}

struct AndroidPendingChapter: Codable, Equatable, Sendable {
    let key: String
    let isRead: Bool
    let isBookmarked: Bool
    let lastPage: Int64
    let fetchedMilliseconds: Int64
    let uploadedMilliseconds: Int64
    var historyMilliseconds: Int64?
    var durationMilliseconds: Int64?
}

struct AndroidChapter: Sendable {
    let title: String
    let number: Double?
    let order: Int
    var pending: AndroidPendingChapter
}

struct AndroidSeries: Sendable {
    let source: Int64
    let key: String
    let metadata: SeriesMetadata
    let favoriteAt: Date?
    let mode: ReadingMode?
    let categories: [Int64]
    var chapters: [AndroidChapter]
}

struct AndroidCategory: Sendable {
    let id: Int64
    let name: String
    let order: Int64
}

struct AndroidBackup: Sendable {
    let series: [AndroidSeries]
    let categories: [AndroidCategory]
    let diagnostics: [String]
    var localCount: Int { series.filter { $0.source == 0 }.count }
}

/// kotlinx.serialization DEFAULT = int64 varint complément à deux, PAS sint64 ZigZag.
/// Seuls les messages du schéma connu sont ouverts ; les champs inconnus restent opaques.
enum AndroidBackupDecoder {
    static let maximumBytes = 64 * 1_024 * 1_024
    private struct Field {
        let number: Int
        let wire: Int
        let integer: UInt64
        let bytes: Data
    }
    private final class Budget {
        var fields = 0
        var chapters = 0
        var diagnostics: Set<String> = [
            "EXPERIMENTAL : format courant sans numéro de version ; compatibilité ancienne/future non garantie.",
            "Aucune page, couverture distante, extension, compte ou préférence privée n’est importé."
        ]
    }
    private struct Wire {
        let data: Data
        var offset = 0
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < data.count else { throw AndroidBackupError.invalid }
                let byte = data[data.startIndex + offset]
                offset += 1
                if index == 9 && byte > 1 { throw AndroidBackupError.invalid }
                value |= UInt64(byte & 127) << (index * 7)
                if byte < 128 { return value }
            }
            throw AndroidBackupError.invalid
        }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw AndroidBackupError.invalid }
            let result = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
            offset += count
            return result
        }
    }
    private static func fields(_ data: Data, budget: Budget) throws -> [Field] {
        var wire = Wire(data: data)
        var result: [Field] = []
        while wire.offset < data.count {
            budget.fields += 1
            guard budget.fields <= 250_000 else { throw AndroidBackupError.limit }
            let tag = try wire.varint()
            guard tag >> 3 > 0, tag >> 3 <= 536_870_911 else { throw AndroidBackupError.invalid }
            let type = Int(tag & 7)
            var integer: UInt64 = 0
            var bytes = Data()
            switch type {
            case 0: integer = try wire.varint()
            case 1: bytes = try wire.take(8)
            case 2:
                let length = try wire.varint()
                guard length <= UInt64(maximumBytes) else { throw AndroidBackupError.limit }
                bytes = try wire.take(Int(length))
            case 5: bytes = try wire.take(4)
            default: throw AndroidBackupError.invalid
            }
            result.append(Field(number: Int(tag >> 3), wire: type, integer: integer, bytes: bytes))
        }
        return result
    }
    private static func one(_ fields: [Field], _ number: Int, wire: Int) throws -> Field? {
        let matches = fields.filter { $0.number == number }
        guard matches.count <= 1, matches.first.map({ $0.wire == wire }) ?? true else {
            throw AndroidBackupError.invalid
        }
        return matches.first
    }
    private static func integer(_ fields: [Field], _ number: Int, default value: Int64 = 0) throws -> Int64 {
        guard let field = try one(fields, number, wire: 0) else { return value }
        return Int64(bitPattern: field.integer)
    }
    private static func boolean(_ fields: [Field], _ number: Int, default value: Bool = false) throws -> Bool {
        let raw = try integer(fields, number, default: value ? 1 : 0)
        guard raw == 0 || raw == 1 else { throw AndroidBackupError.invalid }
        return raw == 1
    }
    private static func string(_ field: Field) throws -> String {
        guard field.wire == 2, field.bytes.count <= 1_048_576 else { throw AndroidBackupError.limit }
        guard let value = String(data: field.bytes, encoding: .utf8) else { throw AndroidBackupError.invalid }
        return value
    }
    private static func text(_ fields: [Field], _ number: Int, required: Bool = false) throws -> String {
        guard let field = try one(fields, number, wire: 2) else {
            if required { throw AndroidBackupError.invalid }
            return ""
        }
        return try string(field)
    }
    private static func messages(_ fields: [Field], _ number: Int, budget: Budget) throws -> [[Field]] {
        try fields.filter { $0.number == number }.map {
            guard $0.wire == 2 else { throw AndroidBackupError.invalid }
            return try self.fields($0.bytes, budget: budget)
        }
    }
    private static func skipped(_ fields: [Field], supported: Set<Int>, names: [Int: String], budget: Budget) {
        for field in fields where !supported.contains(field.number) {
            budget.diagnostics.insert("Ignoré : " + (names[field.number] ?? "champ inconnu (compatibilité non garantie)"))
        }
    }
    static func decode(_ data: Data) throws -> AndroidBackup {
        guard !data.isEmpty, data.count <= maximumBytes else { throw AndroidBackupError.limit }
        let budget = Budget()
        let root = try fields(data, budget: budget)
        skipped(root, supported: [1, 2, 101], names: [
            100: "sources anciennes", 104: "préférences globales/comptes",
            105: "préférences privées des sources", 106: "dépôts d’extensions"
        ], budget: budget)
        // Les sources sont des données inertes ; aucune URL ni installation n’est utilisée.
        for source in try messages(root, 101, budget: budget) {
            _ = try text(source, 1)
            guard try one(source, 2, wire: 0) != nil else { throw AndroidBackupError.invalid }
            budget.diagnostics.insert("Ignoré : catalogue de sources (inactif sur iOS)")
        }
        let categories = try messages(root, 2, budget: budget).map { fields in
            skipped(fields, supported: [1, 2, 3], names: [100: "drapeaux des catégories"], budget: budget)
            return AndroidCategory(id: try integer(fields, 3), name: try text(fields, 1, required: true),
                                   order: try integer(fields, 2))
        }
        let mangas = try messages(root, 1, budget: budget)
        guard mangas.count <= 10_000, categories.count <= 10_000 else { throw AndroidBackupError.limit }
        var series: [AndroidSeries] = []
        for manga in mangas {
            guard try one(manga, 1, wire: 0) != nil else { throw AndroidBackupError.invalid }
            skipped(manga, supported: [1, 2, 3, 4, 5, 6, 7, 8, 13, 14, 16, 17, 100, 103, 104, 107, 110],
                    names: [9: "couverture distante", 18: "suivi/tracking et comptes", 112: "memo privé",
                            101: "filtres de chapitres", 105: "stratégie de mise à jour", 108: "scanlateurs exclus",
                            111: "initialisation", 113: "mise à jour distante"], budget: budget)
            let status: SeriesStatus
            let statusValue = try integer(manga, 8)
            guard statusValue >= Int64(Int32.min), statusValue <= Int64(Int32.max) else {
                throw AndroidBackupError.invalid
            }
            switch statusValue {
            case 1: status = .ongoing
            case 2: status = .completed
            case 5: status = .cancelled
            case 6: status = .hiatus
            default: status = .unknown
            }
            let author = try text(manga, 5), artist = try text(manga, 4)
            let metadata = SeriesMetadata(title: try text(manga, 3), authors: author.isEmpty ? [] : [author],
                artists: artist.isEmpty ? [] : [artist], summary: try text(manga, 6),
                genres: try manga.filter { $0.number == 7 }.map(string), status: status, notes: try text(manga, 110))
            try metadata.validate()
            let favorite = try boolean(manga, 100, default: true)
            let added = try integer(manga, 13)
            let modified = try integer(manga, 107)
            let favoriteAt = favorite ? Date(timeIntervalSince1970: added > 0 ? Double(added) / 1_000
                : (modified > 0 ? Double(modified) : 0)) : nil
            let flags = try integer(manga, 103, default: integer(manga, 14))
            guard flags >= Int64(Int32.min), flags <= Int64(Int32.max) else { throw AndroidBackupError.invalid }
            let modes: [ReadingMode] = [.leftToRight, .rightToLeft, .vertical, .webtoon, .continuousVertical]
            let masked = Int(flags & 7)
            let mode = (1...5).contains(masked) ? modes[masked - 1] : nil
            if flags & ~7 != 0 || masked > 5 { budget.diagnostics.insert("Ignoré : bits lecteur non reconnus") }
            var chapterValues: [AndroidChapter] = []
            for chapter in try messages(manga, 16, budget: budget) {
                budget.chapters += 1
                guard budget.chapters <= 30_000 else { throw AndroidBackupError.limit }
                skipped(chapter, supported: Set(1...10), names: [13: "memo privé du chapitre"], budget: budget)
                if try one(chapter, 3, wire: 2) != nil {
                    _ = try text(chapter, 3)
                    budget.diagnostics.insert("Ignoré : scanlateur du chapitre")
                }
                let key = try text(chapter, 1, required: true)
                let float = try one(chapter, 9, wire: 5)
                let bits = float?.bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) } ?? 0
                let number = Double(Float(bitPattern: bits))
                guard number.isFinite else { throw AndroidBackupError.invalid }
                if number < 0 { budget.diagnostics.insert("Numéro de chapitre négatif : conservé comme absent.") }
                let page = try integer(chapter, 6)
                if page < 0 || page > Int64(Int32.max) { budget.diagnostics.insert("Progression Android bornée à 0…2147483647.") }
                let order = try integer(chapter, 10)
                let pending = AndroidPendingChapter(key: key, isRead: try boolean(chapter, 4),
                    isBookmarked: try boolean(chapter, 5), lastPage: min(max(page, 0), Int64(Int32.max)),
                    fetchedMilliseconds: try integer(chapter, 7), uploadedMilliseconds: try integer(chapter, 8))
                chapterValues.append(AndroidChapter(title: try text(chapter, 2, required: true),
                    number: number < 0 ? nil : number, order: Int(clamping: max(order, 0)), pending: pending))
            }
            for history in try messages(manga, 104, budget: budget) {
                skipped(history, supported: [1, 2, 3], names: [:], budget: budget)
                let key = try text(history, 1, required: true)
                guard try one(history, 2, wire: 0) != nil else { throw AndroidBackupError.invalid }
                let date = try integer(history, 2), duration = try integer(history, 3)
                guard duration >= 0 else { throw AndroidBackupError.invalid }
                if let index = chapterValues.firstIndex(where: { $0.pending.key == key }) {
                    chapterValues[index].pending.historyMilliseconds = date > 0 ? date : nil
                    chapterValues[index].pending.durationMilliseconds = duration
                } else { budget.diagnostics.insert("Ignoré : historique sans chapitre correspondant") }
            }
            var categoryIDs: [Int64] = []
            for field in manga where field.number == 17 {
                if field.wire == 0 { categoryIDs.append(Int64(bitPattern: field.integer)) }
                else if field.wire == 2 {
                    var packed = Wire(data: field.bytes)
                    while packed.offset < packed.data.count {
                        guard categoryIDs.count < 10_000 else { throw AndroidBackupError.limit }
                        categoryIDs.append(Int64(bitPattern: try packed.varint()))
                    }
                } else { throw AndroidBackupError.invalid }
            }
            series.append(AndroidSeries(source: try integer(manga, 1), key: try text(manga, 2, required: true),
                metadata: metadata, favoriteAt: favoriteAt, mode: mode, categories: categoryIDs, chapters: chapterValues))
        }
        guard !series.isEmpty else { throw AndroidBackupError.invalid }
        return AndroidBackup(series: series, categories: categories, diagnostics: budget.diagnostics.sorted())
    }
}
