import Foundation
#if canImport(zlib)
import zlib
#endif

/// Lecture en blocs bornés : jamais de décompression gzip arbitraire par NSData.
enum AndroidBackupFile {
    static func read(_ url: URL) throws -> Data {
        #if canImport(Darwin)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        #endif
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 16 * 1_024 * 1_024 else {
            throw AndroidBackupError.limit
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 2) ?? Data()
        try handle.seek(toOffset: 0)
        if magic == Data([0x1f, 0x8b]) { return try gunzip(handle) }
        var result = Data()
        while let chunk = try handle.read(upToCount: 32_768), !chunk.isEmpty {
            guard result.count <= 16 * 1_024 * 1_024 - chunk.count else { throw AndroidBackupError.limit }
            result.append(chunk)
        }
        return result
    }

    private static func gunzip(_ handle: FileHandle) throws -> Data {
        #if canImport(zlib)
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AndroidBackupError.invalid
        }
        defer { inflateEnd(&stream) }
        var result = Data()
        var compressed = 0
        var output = [UInt8](repeating: 0, count: 32_768)
        while let chunk = try handle.read(upToCount: 32_768), !chunk.isEmpty {
            compressed += chunk.count
            guard compressed <= 16 * 1_024 * 1_024 else { throw AndroidBackupError.limit }
            var ended = false
            try chunk.withUnsafeBytes { raw in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(chunk.count)
                repeat {
                    let before = stream.avail_in
                    let status = output.withUnsafeMutableBytes { buffer -> Int32 in
                        stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress!
                        stream.avail_out = uInt(buffer.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    let count = output.count - Int(stream.avail_out)
                    guard result.count <= AndroidBackupDecoder.maximumBytes - count,
                          result.count + count <= max(1_024 * 1_024, compressed * 200) else {
                        throw AndroidBackupError.limit
                    }
                    result.append(contentsOf: output.prefix(count))
                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0 else { throw AndroidBackupError.invalid }
                        ended = true
                        break
                    }
                    // Une sortie exactement pleine peut nécessiter le bloc d’entrée suivant.
                    if status == Z_BUF_ERROR && stream.avail_in == 0 && count == 0 { break }
                    guard status == Z_OK, count > 0 || stream.avail_in < before else { throw AndroidBackupError.invalid }
                } while stream.avail_in > 0 || stream.avail_out == 0
            }
            if ended {
                guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw AndroidBackupError.invalid }
                return result
            }
        }
        throw AndroidBackupError.invalid
        #else
        throw AndroidBackupError.invalid
        #endif
    }
}

struct AndroidMergePlan {
    let snapshot: LibraryBackupSnapshot
    let documents: [(RelativePath, Data)]
}

enum AndroidLibraryMerge {
    /// UUID créés une seule fois ici ; aucune identité ni métadonnée existante n’est remplacée.
    static func plan(_ backup: AndroidBackup, baseline: LibraryBackupSnapshot,
                     importID: UUID, includeReaderModes: Bool) throws -> AndroidMergePlan {
        try baseline.validate()
        var categories = baseline.categories
        var categoryMap: [Int64: UUID] = [:]
        var categoryIDs: Set<Int64> = []
        for category in backup.categories.sorted(by: { $0.order < $1.order }) {
            try LibraryIdentity.validateKey(category.name)
            guard categoryIDs.insert(category.id).inserted else { throw DomainError.duplicate("catégorie Android") }
            if category.id == 0 { continue } // catégorie virtuelle Android, jamais une catégorie iOS persistée
            if let existing = categories.first(where: { !$0.isSystem && $0.name == category.name }) {
                categoryMap[category.id] = existing.id
            } else {
                let id = UUID()
                categoryMap[category.id] = id
                categories.append(CategorySnapshot(id: id, name: category.name, order: categories.count,
                                                   isSystem: false, seriesIDs: []))
            }
        }
        var series = baseline.series
        var identities = Set(series.map { LibraryIdentity.key($0.sourceID, $0.sourceKey) })
        var documents: [(RelativePath, Data)] = []
        for manga in backup.series {
            let sourceID = manga.source == 0 ? "local" : "android:\(manga.source)"
            let key = "android:\(manga.key)"
            guard identities.insert(LibraryIdentity.key(sourceID, key)).inserted else {
                throw DomainError.duplicate("identité Android déjà présente ; aucune donnée modifiée")
            }
            let id = UUID()
            var chapters: [ChapterSnapshot] = []
            for chapter in manga.chapters {
                let chapterID = UUID()
                let path = try RelativePath("android/\(importID.uuidString)/\(chapterID.uuidString).json")
                let data = try JSONEncoder().encode(chapter.pending)
                guard data.count <= 1_048_576 else { throw AndroidBackupError.limit }
                documents.append((path, data))
                chapters.append(ChapterSnapshot(id: chapterID, seriesID: id, key: "android:\(chapter.pending.key)",
                    title: chapter.title, number: chapter.number, order: chapter.order,
                    isRead: chapter.pending.isRead, isBookmarked: chapter.pending.isBookmarked,
                    lastPageIndex: nil, files: [FileSnapshot(id: UUID(), path: path, kind: .document,
                                                           byteCount: Int64(data.count))], pages: [], history: nil))
            }
            let selected = Set(manga.categories.filter { $0 != 0 })
            guard selected.allSatisfy({ categoryMap[$0] != nil }) else { throw DomainError.invalidValue("catégorie Android absente") }
            series.append(SeriesSnapshot(id: id, sourceID: sourceID, sourceKey: key, metadata: manga.metadata,
                favoriteAt: manga.favoriteAt, cover: nil, categoryIDs: selected.sorted().compactMap { categoryMap[$0] },
                preferences: SeriesReadingPreferences(mode: includeReaderModes ? manga.mode : nil), chapters: chapters))
        }
        categories = categories.map { category in
            CategorySnapshot(id: category.id, name: category.name, order: category.order, isSystem: category.isSystem,
                seriesIDs: series.filter {
                    category.isSystem ? $0.categoryIDs.isEmpty : $0.categoryIDs.contains(category.id)
                }.map(\.id))
        }
        let snapshot = LibraryBackupSnapshot(series: series, categories: categories, globalPreferences: baseline.globalPreferences)
        try snapshot.validate()
        return AndroidMergePlan(snapshot: snapshot, documents: documents)
    }

    static func attaching(_ chapter: ChapterSnapshot, files: [FileSnapshot], pages: [PageSnapshot],
                          pending: AndroidPendingChapter) throws -> ChapterSnapshot {
        guard chapter.pages.isEmpty, chapter.key == "android:\(pending.key)", !pages.isEmpty,
              pending.lastPage >= 0, pending.lastPage <= Int64(Int32.max),
              pending.durationMilliseconds.map({ $0 >= 0 }) ?? true,
              pending.historyMilliseconds.map({ $0 > 0 }) ?? true else {
            throw DomainError.invalidValue("rattachement Android")
        }
        let index = min(Int(clamping: pending.lastPage), pages.count - 1)
        let history = pending.historyMilliseconds.map {
            HistorySnapshot(id: UUID(), chapterID: chapter.id, lastReadAt: Date(timeIntervalSince1970: Double($0) / 1_000),
                            lastPageIndex: index, duration: Double(pending.durationMilliseconds ?? 0) / 1_000)
        }
        // Les marques modifiées par l’utilisateur depuis l’import sont prioritaires.
        return ChapterSnapshot(id: chapter.id, seriesID: chapter.seriesID, key: chapter.key, title: chapter.title,
            number: chapter.number, order: chapter.order, isRead: chapter.isRead, isBookmarked: chapter.isBookmarked,
            lastPageIndex: index, files: chapter.files + files, pages: pages, history: history)
    }
}

@MainActor
enum AndroidBackupCommitter {
    static func attach(id: UUID, content: NewChapter, root: URL,
                       repository: any LibraryRepository) throws -> ChapterSnapshot {
        try MutationGate.requireWritable()
        let baseline = try repository.exportSnapshot()
        let chapter = try repository.chapter(id: id)
        let pending = try pending(chapter: chapter, root: root)
        let files = content.files.map { FileSnapshot(id: $0.id, path: $0.path, kind: $0.kind, byteCount: $0.byteCount) }
        let pages = content.pages.enumerated().map { index, value in
            PageSnapshot(id: value.id, index: index, fileID: value.fileID, entryIndex: value.entryIndex,
                         width: value.width, height: value.height)
        }
        let attached = try AndroidLibraryMerge.attaching(chapter, files: files, pages: pages, pending: pending)
        let series = baseline.series.map { value in
            SeriesSnapshot(id: value.id, sourceID: value.sourceID, sourceKey: value.sourceKey, metadata: value.metadata,
                favoriteAt: value.favoriteAt, cover: value.cover, categoryIDs: value.categoryIDs, preferences: value.preferences,
                chapters: value.chapters.map { $0.id == id ? attached : $0 })
        }
        let snapshot = LibraryBackupSnapshot(series: series, categories: baseline.categories,
                                             globalPreferences: baseline.globalPreferences)
        try snapshot.validate()
        try repository.attachAndroidChapter(attached)
        return attached
    }

    static func commit(_ backup: AndroidBackup, root: URL, repository: any LibraryRepository,
                       includeReaderModes: Bool = false) throws {
        try MutationGate.requireWritable()
        let id = UUID()
        try MutationGate.beginImport(id, root: root)
        defer { MutationGate.endImport(id) }
        let plan = try AndroidLibraryMerge.plan(backup, baseline: repository.exportSnapshot(),
                                               importID: id, includeReaderModes: includeReaderModes)
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let directory = root.appendingPathComponent("android/\(id.uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let parent = root.appendingPathComponent("android", isDirectory: true)
        if manager.fileExists(atPath: parent.path) {
            let values = try parent.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw DomainError.invalidPath
            }
        }
        try manager.createDirectory(at: parent, withIntermediateDirectories: false)
        guard !manager.fileExists(atPath: directory.path) else { throw DomainError.duplicate("dossier Android") }
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            for (path, data) in plan.documents {
                try data.write(to: root.appendingPathComponent(path.value), options: .withoutOverwriting)
            }
            // Transaction SwiftData unique, sans suspension : les UUID et données existants sont conservés.
            try repository.commitAndroidMerge(plan.snapshot)
        } catch {
            do { try manager.removeItem(at: directory) }
            catch { MutationGate.requireRecovery(); throw DomainError.invalidValue("nettoyage Android impossible ; récupération requise") }
            throw error
        }
    }

    static func pending(chapter: ChapterSnapshot, root: URL) throws -> AndroidPendingChapter {
        guard chapter.key.hasPrefix("android:"), chapter.pages.isEmpty,
              let file = chapter.files.first(where: { $0.kind == .document && $0.path.value.hasPrefix("android/") }) else {
            throw DomainError.invalidValue("chapitre Android sans état en attente")
        }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(file.path.value)
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/"),
              try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]).isSymbolicLink != true,
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576 else {
            throw AndroidBackupError.limit
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw AndroidBackupError.limit }
        let value = try JSONDecoder().decode(AndroidPendingChapter.self, from: data)
        guard value.lastPage >= 0, value.lastPage <= Int64(Int32.max),
              value.durationMilliseconds.map({ $0 >= 0 }) ?? true,
              value.historyMilliseconds.map({ $0 > 0 }) ?? true else { throw AndroidBackupError.invalid }
        return value
    }
}
