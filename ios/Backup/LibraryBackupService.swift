import CryptoKit
import Foundation
import ZIPFoundation

struct BackupFile: Codable, Equatable, Sendable {
    let path: RelativePath
    let byteCount: Int64
    let sha256: String
}

struct BackupManifest: Codable, Equatable, Sendable {
    let format: String
    let version: Int
    let createdAt: Date
    let snapshot: LibraryBackupSnapshot
    let files: [BackupFile]
}

struct PreparedBackup {
    let id: UUID
    let manifest: BackupManifest
}

/// I/O synchrone sous MainActor : aucun écrivain ne peut s’intercaler entre capture et commit.
/// Les imports asynchrones détiennent une réservation jusqu’à leur abandon/confirmation.
@MainActor
final class LibraryBackupService {
    struct Journal: Codable {
        enum Phase: String, Codable { case pending, recovering, committed }
        let id: UUID
        let rootExisted: Bool
        var phase: Phase
    }

    let root: URL
    let workspace: URL
    let limits: ImportLimits
    let manifestBytes = 16 * 1_024 * 1_024
    private let manager = FileManager()
    private let availableSpace: ((URL) throws -> Int64)?
    private var prepared: Set<UUID> = []
    private var exports: Set<URL> = []
    private var journalURL: URL { workspace.appendingPathComponent("journal.json") }

    init(root: URL, limits: ImportLimits = ImportLimits(),
         availableSpace: ((URL) throws -> Int64)? = nil) {
        let parent = root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        self.root = parent.appendingPathComponent(root.lastPathComponent, isDirectory: true)
        workspace = parent.appendingPathComponent("BackupRecovery", isDirectory: true)
        self.limits = limits
        self.availableSpace = availableSpace
    }

    private func directory(_ id: UUID) -> URL { workspace.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func reject(_ message: String) -> ImportFailure { .rejected("sauvegarde : \(message)") }

    private func initialize() throws {
        guard limits.entries > 0, limits.fileBytes > 0, limits.totalBytes > 0,
              limits.archiveBytes > 0, limits.reserveBytes >= 0 else { throw reject("limites invalides") }
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try regularDirectory(workspace)
        if manager.fileExists(atPath: root.path) { try regularDirectory(root) }
    }

    private func regularDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw reject("dossier ou lien symbolique invalide")
        }
    }

    private func space(_ needed: Int64) throws {
        let available: Int64
        if let availableSpace { available = try availableSpace(workspace) }
        else {
            guard let value = try workspace.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage else { throw reject("capacité disque inconnue") }
            available = value
        }
        try ImportPolicy.requireSpace(available: available, needed: needed, reserve: limits.reserveBytes)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= manifestBytes else { throw reject("manifeste trop volumineux") }
        return data
    }

    private func durableWrite<T: Encodable>(_ value: T, to url: URL) throws {
        try encode(value).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= manifestBytes else { throw reject("journal trop volumineux ou invalide") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: manifestBytes + 1) ?? Data()
        guard data.count <= manifestBytes else { throw reject("journal trop volumineux") }
        return try JSONDecoder().decode(type, from: data)
    }

    private func hash(_ url: URL, expected: Int64, cancellable: Bool = true) throws -> String {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw reject("lien symbolique dans le contenu")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == expected else { throw reject("fichier absent ou taille incohérente") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            if cancellable { try Task.checkCancellation() }
            guard Int64(chunk.count) <= expected - count else { throw reject("fichier modifié") }
            count += Int64(chunk.count)
            digest.update(data: chunk)
        }
        guard count == expected else { throw reject("fichier tronqué") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func contentFiles() throws -> [BackupFile] {
        guard manager.fileExists(atPath: root.path) else { return [] }
        var traversalError: Error?
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys:
            [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            errorHandler: { _, error in traversalError = error; return false }) else { throw reject("contenu illisible") }
        var result: [BackupFile] = []
        var names: Set<String> = []
        var total: Int64 = 0
        var entries = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let path = String(url.path.dropFirst(root.path.count + 1))
            if path == "staging" { enumerator.skipDescendants(); continue }
            entries += 1
            guard entries < limits.entries else { throw reject("trop d’entrées locales") }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw reject("lien symbolique local") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize else { throw reject("fichier non régulier") }
            let normalized = try ImportPolicy.normalized(path)
            guard names.insert(normalized).inserted else { throw reject("chemins ambigus") }
            let bytes = Int64(size)
            guard bytes >= 0, bytes <= limits.fileBytes, bytes <= limits.totalBytes - total else { throw reject("limite de contenu") }
            total += bytes
            result.append(BackupFile(path: try RelativePath(path), byteCount: bytes, sha256: try hash(url, expected: bytes)))
        }
        if let traversalError { throw traversalError }
        return result.sorted { $0.path.value < $1.path.value }
    }

    private func validate(_ manifest: BackupManifest) throws {
        guard manifest.format == "org.mangaios.library-backup", manifest.version == 1,
              manifest.createdAt.timeIntervalSinceReferenceDate.isFinite,
              manifest.files.count < limits.entries else { throw reject("format, version ou limites incompatibles") }
        try manifest.snapshot.validate()
        var names: Set<String> = []
        var paths: Set<String> = []
        var total: Int64 = 0
        var byPath: [String: BackupFile] = [:]
        for file in manifest.files {
            let normalized = try ImportPolicy.normalized(file.path.value)
            guard normalized != "staging", !normalized.hasPrefix("staging/"),
                  names.insert(normalized).inserted,
                  paths.insert(file.path.value).inserted,
                  file.byteCount >= 0, file.byteCount <= limits.fileBytes,
                  file.byteCount <= limits.totalBytes - total,
                  file.sha256.utf8.count == 64,
                  file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw reject("table des fichiers invalide")
            }
            total += file.byteCount
            byPath[file.path.value] = file
        }
        for path in names {
            var components = path.split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                guard !names.contains(components.joined(separator: "/")) else { throw reject("conflit fichier/dossier") }
            }
        }
        for file in manifest.snapshot.files {
            guard let record = byPath[file.path.value], file.byteCount.map({ $0 == record.byteCount }) ?? true else {
                throw reject("fichier référencé absent ou taille déclarée incorrecte")
            }
        }
    }

    @discardableResult
    private func writeArchive(snapshot: LibraryBackupSnapshot, to url: URL,
                              metadataReserve: Int64 = 0) throws -> BackupManifest {
        let files = try contentFiles()
        let manifest = BackupManifest(format: "org.mangaios.library-backup", version: 1,
                                      createdAt: Date(), snapshot: snapshot, files: files)
        try validate(manifest)
        let data = try encode(manifest)
        let total = files.reduce(Int64(data.count)) { $0 + $1.byteCount }
        // STORE évite toute hypothèse sur le taux de compression et permet un budget exact.
        let overhead = Int64(files.reduce(256) { $0 + 256 + $1.path.value.utf8.count * 2 })
        guard total <= limits.archiveBytes - overhead else { throw reject("archive trop volumineuse") }
        try space(total + overhead + metadataReserve)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(data.count),
                             bufferSize: 64 * 1_024) { position, size in
            data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
        }
        for file in files {
            try Task.checkCancellation()
            let source = root.appendingPathComponent(file.path.value)
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            try archive.addEntry(with: "content/" + file.path.value, type: .file, uncompressedSize: file.byteCount,
                                 bufferSize: 64 * 1_024) { position, size in
                try handle.seek(toOffset: UInt64(position))
                let chunk = try handle.read(upToCount: size) ?? Data()
                guard chunk.count == size else { throw self.reject("fichier modifié pendant la copie") }
                return chunk
            }
            guard try hash(source, expected: file.byteCount) == file.sha256 else { throw reject("fichier modifié pendant la sauvegarde") }
        }
        _ = try ZIPPreflight.entryCount(at: url, limits: limits)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        return manifest
    }

    func export(repository: any LibraryRepository) throws -> URL {
        try MutationGate.withExclusive(root: root) {
            try initialize()
            guard !manager.fileExists(atPath: journalURL.path) else { throw reject("récupération requise au redémarrage") }
            let url = workspace.appendingPathComponent("Export-\(UUID().uuidString).zip")
            do {
                try writeArchive(snapshot: repository.exportSnapshot(), to: url)
                exports.insert(url)
                return url
            } catch {
                try cleanup(url, original: error)
                throw error
            }
        }
    }

    func discardExport(_ url: URL) throws {
        guard exports.contains(url) else { return }
        try cleanup(url)
        exports.remove(url)
    }

    private func extract(_ entry: Entry, archive: Archive, max: Int64,
                         consume: (Data) throws -> Void) throws {
        guard entry.type == .file, entry.uncompressedSize <= UInt64(max) else { throw reject("entrée ZIP invalide") }
        var bytes: Int64 = 0
        let crc = try archive.extract(entry, bufferSize: 64 * 1_024, skipCRC32: false) { chunk in
            try Task.checkCancellation()
            guard Int64(chunk.count) <= max - bytes else { throw self.reject("quota ZIP dépassé") }
            bytes += Int64(chunk.count)
            try consume(chunk)
        }
        guard bytes == Int64(entry.uncompressedSize), crc == entry.checksum else { throw reject("taille ou CRC ZIP incorrect") }
    }

    func prepare(source: URL) throws -> PreparedBackup {
        try MutationGate.withExclusive(root: root) {
            try initialize()
            guard !manager.fileExists(atPath: journalURL.path) else { throw reject("récupération requise") }
            let id = UUID()
            let target = directory(id)
            try manager.createDirectory(at: target, withIntermediateDirectories: false)
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                var coordinationError: NSError?
                var result: Result<BackupManifest, Error>?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
                    result = Result { try self.prepareCoordinated(source: url, target: target) }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw reject("fournisseur Fichiers indisponible") }
                let manifest = try result.get()
                prepared.insert(id)
                return PreparedBackup(id: id, manifest: manifest)
            } catch {
                try cleanup(target, original: error)
                throw error
            }
        }
    }

    private func prepareCoordinated(source: URL, target: URL) throws -> BackupManifest {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw reject("archive non régulière") }
        let count = try ZIPPreflight.entryCount(at: source, limits: limits)
        let archive = try Archive(url: source, accessMode: .read)
        var entries: [String: Entry] = [:]
        var names: Set<String> = []
        for entry in archive {
            _ = try RelativePath(entry.path)
            // Le préfixe fixe « content/ » s’ajoute aux 1 024 octets du chemin local.
            guard entry.path.utf8.count <= 1_032,
                  entry.type == .file,
                  names.insert(entry.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  entries.count < limits.entries else { throw reject("entrée dupliquée, répertoire ou lien ZIP") }
            entries[entry.path] = entry
        }
        guard entries.count == count, let header = entries["manifest.json"] else { throw reject("manifeste absent ou ZIP incomplet") }
        var data = Data()
        try extract(header, archive: archive, max: Int64(manifestBytes)) { data.append($0) }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
        try validate(manifest)
        let allowed = Set(["manifest.json"] + manifest.files.map { "content/" + $0.path.value })
        guard Set(entries.keys) == allowed else { throw reject("entrées manquantes ou non autorisées") }
        try space(manifest.files.reduce(0) { $0 + $1.byteCount } + Int64(manifestBytes))
        let content = target.appendingPathComponent("new", isDirectory: true)
        try manager.createDirectory(at: content, withIntermediateDirectories: false)
        for file in manifest.files {
            guard let entry = entries["content/" + file.path.value], entry.uncompressedSize == UInt64(file.byteCount) else {
                throw reject("taille déclarée incorrecte")
            }
            let destination = content.appendingPathComponent(file.path.value)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: destination.path, contents: nil) else { throw reject("création impossible") }
            let handle = try FileHandle(forWritingTo: destination)
            do {
                try extract(entry, archive: archive, max: file.byteCount) { try handle.write(contentsOf: $0) }
                try handle.synchronize()
                try handle.close()
            } catch { try? handle.close(); throw error }
            guard try hash(destination, expected: file.byteCount) == file.sha256 else { throw reject("empreinte SHA-256 incorrecte") }
        }
        try durableWrite(manifest, to: target.appendingPathComponent("manifest.json"))
        return manifest
    }

    func discard(_ value: PreparedBackup) throws {
        guard prepared.contains(value.id) else { return }
        let target = directory(value.id)
        if manager.fileExists(atPath: target.appendingPathComponent("Securite.zip").path) {
            try cleanup(target.appendingPathComponent("new"))
            try cleanup(target.appendingPathComponent("manifest.json"))
        } else {
            try cleanup(target)
        }
        prepared.remove(value.id)
    }

    /// Retourne un avertissement uniquement si le commit réussi nécessite encore un nettoyage.
    func restore(_ value: PreparedBackup, repository: any LibraryRepository) throws -> String? {
        try MutationGate.withExclusive(root: root) {
            try initialize()
            guard prepared.contains(value.id), !manager.fileExists(atPath: journalURL.path) else { throw reject("préparation expirée") }
            let target = directory(value.id)
            let manifest = try read(BackupManifest.self, at: target.appendingPathComponent("manifest.json"))
            guard manifest == value.manifest else { throw reject("préparation modifiée") }
            try validate(manifest)
            let newRoot = target.appendingPathComponent("new", isDirectory: true)
            try regularDirectory(newRoot)
            for file in manifest.files {
                guard try hash(newRoot.appendingPathComponent(file.path.value), expected: file.byteCount) == file.sha256 else {
                    throw reject("préparation corrompue")
                }
            }
            let old = try repository.exportSnapshot()
            // L’archive de sécurité et le préimage du dépôt sont durables AVANT tout déplacement.
            let safety = target.appendingPathComponent("Securite.zip")
            if manager.fileExists(atPath: safety.path) { try cleanup(safety) }
            let previousManifest: BackupManifest
            do { previousManifest = try writeArchive(snapshot: old, to: safety, metadataReserve: Int64(manifestBytes * 2 + 1_024)) }
            catch {
                try cleanup(safety, original: error)
                throw error
            }
            try durableWrite(previousManifest, to: target.appendingPathComponent("previousManifest.json"))
            try durableWrite(old, to: target.appendingPathComponent("previous.json"))
            var journal = Journal(id: value.id, rootExisted: manager.fileExists(atPath: root.path), phase: .pending)
            try durableWrite(journal, to: journalURL)
            prepared.remove(value.id)
            do {
                // À partir d’ici, l’annulation ne peut plus interrompre la réconciliation.
                if journal.rootExisted { try manager.moveItem(at: root, to: target.appendingPathComponent("old")) }
                try manager.moveItem(at: newRoot, to: root)
                try MutationGate.withReplacement { try repository.replaceSnapshot(manifest.snapshot) }
                journal.phase = .committed
                try durableWrite(journal, to: journalURL)
            } catch {
                if (try? read(Journal.self, at: journalURL))?.phase == .committed {
                    // Le marqueur atomique existe, mais sa synchronisation a échoué :
                    // garder aussi old et le journal, sans annoncer un faux rollback.
                    return "Données restaurées. Synchronisation finale à reprendre au redémarrage ; anciennes copies et sauvegarde de sécurité conservées : \(error.localizedDescription)"
                }
                do { _ = try recoverUnlocked(repository: repository) }
                catch let recovery {
                    MutationGate.requireRecovery()
                    throw ImportFailure.cleanup(error.localizedDescription, "récupération au redémarrage requise : \(recovery.localizedDescription)")
                }
                throw error
            }
            do {
                try finish(journal)
                return nil
            } catch {
                return "Restauration terminée. Sauvegarde de sécurité conservée ; nettoyage à reprendre au redémarrage : \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func recover(repository: any LibraryRepository) throws -> String? {
        try MutationGate.withExclusive(root: root) {
            try initialize()
            let warning = try recoverUnlocked(repository: repository)
            MutationGate.recoveryFinished()
            do { try cleanupAbandoned() }
            catch { return warning ?? "Données intactes ; fichiers de travail à nettoyer au prochain démarrage : \(error.localizedDescription)" }
            return warning
        }
    }

    private func recoverUnlocked(repository: any LibraryRepository) throws -> String? {
        guard manager.fileExists(atPath: journalURL.path) else { return nil }
        var journal = try read(Journal.self, at: journalURL)
        let target = directory(journal.id)
        try regularDirectory(target)
        if journal.phase == .committed {
            do { try durableWrite(journal, to: journalURL); try finish(journal); return nil }
            catch {
                return "Les données restaurées sont intactes. Nettoyage restant au redémarrage : \(error.localizedDescription)"
            }
        }
        let snapshot = try read(LibraryBackupSnapshot.self, at: target.appendingPathComponent("previous.json"))
        try snapshot.validate()
        let previous = try read(BackupManifest.self, at: target.appendingPathComponent("previousManifest.json"))
        try validate(previous)
        guard previous.snapshot == snapshot else { throw reject("préimage incohérent") }
        let oldRoot = target.appendingPathComponent("old", isDirectory: true)
        let previousRoot = manager.fileExists(atPath: oldRoot.path) ? oldRoot : root
        if journal.rootExisted {
            try regularDirectory(previousRoot)
            for file in previous.files {
                guard try hash(previousRoot.appendingPathComponent(file.path.value),
                               expected: file.byteCount, cancellable: false) == file.sha256 else {
                    throw reject("anciens fichiers endommagés ; archive de sécurité conservée")
                }
            }
        }
        journal.phase = .recovering
        try durableWrite(journal, to: journalURL)
        try MutationGate.withReplacement { try repository.replaceSnapshot(snapshot) }
        if manager.fileExists(atPath: oldRoot.path) {
            try regularDirectory(oldRoot)
            if manager.fileExists(atPath: root.path) { try cleanup(root) }
            try manager.moveItem(at: oldRoot, to: root)
        } else if !journal.rootExisted, manager.fileExists(atPath: root.path) {
            try cleanup(root)
        } else if journal.rootExisted {
            // Aucun déplacement initial, ou rollback des fichiers déjà terminé.
            try regularDirectory(root)
        }

        try cleanup(journalURL)
        // Le ZIP de sécurité reste partageable ; les préparations non installées sont supprimées.
        try cleanup(target.appendingPathComponent("new"))
        return nil
    }

    func isPrepared(_ value: PreparedBackup) -> Bool { prepared.contains(value.id) }

    private func cleanupAbandoned() throws {
        let activeJournal = manager.fileExists(atPath: journalURL.path)
            ? try read(Journal.self, at: journalURL).id : nil
        for url in try manager.contentsOfDirectory(at: workspace, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            if let id = UUID(uuidString: url.lastPathComponent), id != activeJournal, !prepared.contains(id) {
                try regularDirectory(url)
                if manager.fileExists(atPath: url.appendingPathComponent("Securite.zip").path) {
                    try cleanup(url.appendingPathComponent("new"))
                    for name in ["manifest.json", "previous.json", "previousManifest.json"] {
                        try cleanup(url.appendingPathComponent(name))
                    }
                } else { try cleanup(url) }
            } else if url.lastPathComponent.hasPrefix("Export-"), url.pathExtension == "zip",
                      UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(7))) != nil,
                      !exports.contains(url) {
                try cleanup(url)
            }
        }
    }

    private func finish(_ journal: Journal) throws {
        let target = directory(journal.id)
        try cleanup(target.appendingPathComponent("old"))
        try cleanup(target.appendingPathComponent("new"))
        try cleanup(journalURL)
    }

    func safetyArchives() throws -> [URL] {
        try initialize()
        return try manager.contentsOfDirectory(at: workspace, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { $0.appendingPathComponent("Securite.zip") }
            .filter { manager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    private func cleanup(_ url: URL, original: Error? = nil) throws {
        guard manager.fileExists(atPath: url.path) else { return }
        do { try manager.removeItem(at: url) }
        catch { throw ImportFailure.cleanup(original?.localizedDescription ?? "Nettoyage", error.localizedDescription) }
    }
}
