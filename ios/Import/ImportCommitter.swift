import Foundation

enum ImportTarget: Sendable {
    case newSeries(SeriesMetadata)
    case existingSeries(UUID)
}

@MainActor
enum ImportCommitter {
    private static var active: Set<UUID> = []

    static func commit(_ prepared: PreparedImport, target: ImportTarget, allowDuplicate: Bool = false,
                       repository: any LibraryRepository, service: LocalImportService) async throws -> ChapterSnapshot {
        try Task.checkCancellation()
        try MutationGate.requireWritable()
        guard active.insert(prepared.id).inserted else { throw ImportFailure.rejected("import déjà en cours") }
        defer { active.remove(prepared.id) }
        let series: NewSeries?
        let seriesID: UUID
        let order: Int
        let fingerprintKey = "import:\(prepared.manifest.fingerprint)"
        switch target {
        case .newSeries(let metadata):
            try metadata.validate()
            let value = NewSeries(sourceKey: allowDuplicate ? "\(fingerprintKey):\(UUID())" : fingerprintKey,
                                  metadata: metadata, favoriteAt: Date())
            // Refuser le doublon avant de déplacer les fichiers ; le dépôt revérifie dans sa transaction.
            if !allowDuplicate, try repository.allSeries(inLibraryOnly: false).contains(where: {
                $0.sourceID == "local" && ($0.sourceKey == fingerprintKey || $0.sourceKey.hasPrefix(fingerprintKey + ":"))
            }) { throw DomainError.duplicate("import déjà présent ; choisir explicitement une copie séparée") }
            series = value
            seriesID = value.id
            order = 0
        case .existingSeries(let id):
            let existing = try repository.series(id: id)
            if !allowDuplicate, existing.chapters.contains(where: {
                $0.key == fingerprintKey || $0.key.hasPrefix(fingerprintKey + ":")
            }) { throw DomainError.duplicate("chapitre déjà importé ; choisir explicitement une copie séparée") }
            series = nil
            seriesID = id
            guard (existing.chapters.map(\.order).max() ?? -1) < Int.max else {
                throw DomainError.invalidValue("ordre du chapitre")
            }
            order = (existing.chapters.map(\.order).max() ?? -1) + 1
        }
        let prefix = "imports/\(prepared.id.uuidString)"
        var files: [LocalFileInput] = []
        var pages: [LocalPageInput] = []
        for page in prepared.manifest.pages {
            let file = LocalFileInput(path: try RelativePath("\(prefix)/\(page.filename)"), kind: .image,
                                      byteCount: page.byteCount)
            files.append(file)
            pages.append(LocalPageInput(fileID: file.id, width: page.width, height: page.height))
        }
        files.append(LocalFileInput(path: try RelativePath("\(prefix)/manifest.json"), kind: .document))
        if let xml = prepared.manifest.comicInfoFilename {
            files.append(LocalFileInput(path: try RelativePath("\(prefix)/\(xml)"), kind: .document))
        }
        let chapter = NewChapter(seriesID: seriesID,
            key: allowDuplicate ? "\(fingerprintKey):\(UUID())" : fingerprintKey,
            title: prepared.manifest.metadata.chapterTitle, number: prepared.manifest.metadata.number,
            order: order, files: files, pages: pages)
        var installed = false
        do {
            try await service.install(prepared)
            installed = true
            // Aucune suspension entre ce contrôle et la transaction : une annulation tardive
            // ne doit jamais supprimer les fichiers d’un chapitre déjà sauvegardé.
            try Task.checkCancellation()
            let saved = try repository.commitImport(series: series, chapter: chapter)
            await service.acknowledge(prepared)
            return saved
        } catch {
            if installed { try await service.rollbackInstall(prepared, original: error) }
            throw error
        }
    }
}
