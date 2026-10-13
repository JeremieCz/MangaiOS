import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

struct ImportProgress: Sendable {
    var files: Int
    var bytes: Int64
}

struct ImportedPage: Codable, Sendable {
    let index: Int
    let originalPath: String
    let filename: String
    let byteCount: Int64
    let width: Int
    let height: Int
    let sha256: String
}

struct ImportManifest: Codable, Sendable {
    let version: Int
    let fingerprint: String
    let metadata: ComicMetadata
    let pages: [ImportedPage]
    let comicInfoFilename: String?
}

struct PreparedImport: Sendable {
    let id: UUID
    let manifest: ImportManifest
}

actor LocalImportService {
    let root: URL
    let limits: ImportLimits
    private let availableSpace: (@Sendable (URL) throws -> Int64)?
    private let manager = FileManager()
    private var preparedIDs: Set<UUID> = []
    private var installedIDs: Set<UUID> = []

    init(root: URL, limits: ImportLimits = ImportLimits(),
         availableSpace: (@Sendable (URL) throws -> Int64)? = nil) {
        self.root = root
        self.limits = limits
        self.availableSpace = availableSpace
    }

    static func defaultRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("MangaiOS/LocalContent", isDirectory: true)
    }

    private func staging(_ id: UUID) -> URL {
        root.appendingPathComponent("staging/\(id.uuidString)", isDirectory: true)
    }

    private func destination(_ id: UUID) -> URL {
        root.appendingPathComponent("imports/\(id.uuidString)", isDirectory: true)
    }

    private func space(_ bytes: Int64) throws {
        let available: Int64
        if let availableSpace { available = try availableSpace(root) }
        else {
            let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
                throw ImportFailure.rejected("capacité disque indisponible")
            }
            available = capacity
        }
        try ImportPolicy.requireSpace(available: available, needed: bytes, reserve: limits.reserveBytes)
    }

    func prepare(source: URL, progress: @Sendable (ImportProgress) -> Void = { _ in }) async throws -> PreparedImport {
        let lease = UUID()
        try await MutationGate.beginImport(lease, root: root)
        do {
            let value = try prepareReserved(source: source, id: lease, progress: progress)
            return value
        } catch {
            await MutationGate.endImport(lease)
            throw error
        }
    }

    private func prepareReserved(source: URL, id: UUID,
                                 progress: @Sendable (ImportProgress) -> Void) throws -> PreparedImport {
        try Task.checkCancellation()
        guard limits.entries > 0, limits.pages > 0, limits.fileBytes > 0,
              limits.totalBytes > 0, limits.archiveBytes > 0, limits.xmlBytes > 0,
              limits.pixels > 0, limits.reserveBytes >= 0 else {
            throw ImportFailure.rejected("limites de configuration invalides")
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try space(0)
        let directory = staging(id)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            // Les fournisseurs Fichiers peuvent matérialiser leurs données dans ce bloc.
            var coordinationError: NSError?
            var result: Result<PreparedImport, Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                result = Result { try prepareCoordinated(source: coordinated, id: id, progress: progress) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw ImportFailure.rejected("fournisseur Fichiers indisponible") }
            let prepared = try result.get()
            try Task.checkCancellation()
            preparedIDs.insert(id)
            return prepared
        } catch {
            try remove(directory, original: error)
            throw error
        }
    }

    private func remove(_ url: URL, original: Error? = nil) throws {
        do { try manager.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
        catch { throw ImportFailure.cleanup(original?.localizedDescription ?? "Import annulé", error.localizedDescription) }
    }

    func discard(_ prepared: PreparedImport) async throws {
        guard preparedIDs.contains(prepared.id) else { return }
        try remove(staging(prepared.id))
        preparedIDs.remove(prepared.id)
        await MutationGate.endImport(prepared.id)
    }

    func install(_ prepared: PreparedImport) throws {
        guard preparedIDs.contains(prepared.id) else { throw ImportFailure.rejected("préparation expirée") }
        try Task.checkCancellation()
        try space(0)
        try manager.createDirectory(at: root.appendingPathComponent("imports"), withIntermediateDirectories: true)
        // Même volume privé : renommage atomique, aucune réécriture de l’original.
        try manager.moveItem(at: staging(prepared.id), to: destination(prepared.id))
        preparedIDs.remove(prepared.id)
        installedIDs.insert(prepared.id)
    }

    func rollbackInstall(_ prepared: PreparedImport, original: Error) async throws {
        guard installedIDs.contains(prepared.id) else { return }
        try remove(destination(prepared.id), original: original)
        installedIDs.remove(prepared.id)
        await MutationGate.endImport(prepared.id)
    }

    func acknowledge(_ prepared: PreparedImport) async {
        installedIDs.remove(prepared.id)
        await MutationGate.endImport(prepared.id)
    }

    func isPrepared(_ prepared: PreparedImport) -> Bool {
        preparedIDs.contains(prepared.id)
    }

    private struct Candidate {
        let path: String
        let size: Int64
        let url: URL?
        let entry: Entry?
    }

    private func prepareCoordinated(source: URL, id: UUID,
                                    progress: @Sendable (ImportProgress) -> Void) throws -> PreparedImport {
        let rootValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard rootValues.isSymbolicLink != true else { throw ImportFailure.rejected("lien symbolique") }
        var candidates: [Candidate] = []
        var paths: Set<String> = []
        var entries = 0
        var declaredBytes: Int64 = 0
        func register(path: String, size: Int64, directory: Bool) throws {
            try Task.checkCancellation()
            entries += 1
            guard entries <= limits.entries else { throw ImportFailure.rejected("trop d’entrées") }
            let normalized = try ImportPolicy.normalized(path)
            guard paths.insert(normalized).inserted else { throw ImportFailure.rejected("chemin dupliqué : \(path)") }
            if !directory {
                guard size >= 0, size <= limits.fileBytes, size <= limits.totalBytes - declaredBytes else {
                    throw ImportFailure.rejected("limite de taille : \(path)")
                }
                declaredBytes += size
            }
        }
        var archive: Archive?
        if rootValues.isDirectory == true {
            // Pas d’import partiel après une erreur de parcours.
            var traversalError: Error?
            guard let checked = manager.enumerator(at: source, includingPropertiesForKeys:
                [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                options: [], errorHandler: { _, error in traversalError = error; return false }) else {
                throw ImportFailure.rejected("dossier illisible")
            }
            for case let url as URL in checked {
                let values = try url.resourceValues(forKeys:
                    [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw ImportFailure.rejected("lien symbolique : \(url.lastPathComponent)") }
                guard values.isDirectory == true || values.isRegularFile == true else {
                    throw ImportFailure.rejected("entrée non régulière")
                }
                let prefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
                guard url.path.hasPrefix(prefix) else { throw ImportFailure.rejected("chemin hors dossier") }
                let path = String(url.path.dropFirst(prefix.count))
                let size = Int64(values.fileSize ?? 0)
                try register(path: path, size: size, directory: values.isDirectory == true)
                if values.isDirectory != true && !ImportPolicy.ignored(path) {
                    candidates.append(Candidate(path: path, size: size, url: url, entry: nil))
                }
            }
            if let traversalError { throw traversalError }
        } else {
            guard rootValues.isRegularFile == true, ["zip", "cbz"].contains(source.pathExtension.lowercased()) else {
                throw ImportFailure.rejected("choisissez un ZIP, CBZ ou dossier d’images")
            }
            let expectedCount = try ZIPPreflight.entryCount(at: source, limits: limits)
            let opened = try Archive(url: source, accessMode: .read)
            archive = opened
            for entry in opened {
                guard entry.type != .symlink else { throw ImportFailure.rejected("lien symbolique dans le ZIP") }
                let path = entry.type == .directory && entry.path.hasSuffix("/")
                    ? String(entry.path.dropLast()) : entry.path
                guard entry.uncompressedSize <= UInt64(Int64.max) else { throw ImportFailure.rejected("taille ZIP excessive") }
                try register(path: path, size: Int64(entry.uncompressedSize), directory: entry.type == .directory)
                if entry.type == .file {
                    if ImportPolicy.ignored(path) {
                        // Même les métadonnées ignorées ne doivent pas masquer un ZIP corrompu.
                        var discarded: Int64 = 0
                        let size = Int64(entry.uncompressedSize)
                        let crc = try opened.extract(entry, bufferSize: 64 * 1_024, skipCRC32: false) { chunk in
                            try Task.checkCancellation()
                            guard Int64(chunk.count) <= size - discarded else {
                                throw ImportFailure.rejected("taille ZIP incohérente : \(path)")
                            }
                            discarded += Int64(chunk.count)
                        }
                        guard discarded == size, crc == entry.checksum else {
                            throw ImportFailure.rejected("CRC ZIP invalide : \(path)")
                        }
                    } else {
                        candidates.append(Candidate(path: path, size: Int64(entry.uncompressedSize), url: nil, entry: entry))
                    }
                }
            }
            guard entries == expectedCount else { throw ImportFailure.rejected("ZIP incomplet ou chiffré") }
        }
        try space(declaredBytes)
        candidates.sort { ImportPolicy.precedes($0.path, $1.path) }
        var pages: [ImportedPage] = []
        var xml: Data?
        var total: Int64 = 0
        var fingerprint = SHA256()
        let directory = staging(id)
        for candidate in candidates {
            try Task.checkCancellation()
            let isXML = (candidate.path as NSString).lastPathComponent.lowercased() == "comicinfo.xml"
            let ext = (candidate.path as NSString).pathExtension.lowercased()
            guard isXML || ImportPolicy.imageExtensions.contains(ext) else {
                throw ImportFailure.rejected("format non pris en charge : \(candidate.path)")
            }
            guard !isXML || (xml == nil && candidate.size <= Int64(limits.xmlBytes)) else {
                throw ImportFailure.rejected("ComicInfo multiple ou trop volumineux")
            }
            guard isXML || pages.count < limits.pages else { throw ImportFailure.rejected("trop de pages") }
            let filename = isXML ? "ComicInfo.xml" : String(format: "%06d.%@", pages.count, ext)
            let output = directory.appendingPathComponent(filename)
            guard manager.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: output)
            var bytes: Int64 = 0
            var hash = SHA256()
            do {
                func consume(_ data: Data) throws {
                    try Task.checkCancellation()
                    let count = Int64(data.count)
                    guard count <= limits.fileBytes - bytes, count <= limits.totalBytes - total,
                          !isXML || count <= Int64(limits.xmlBytes) - bytes else {
                        throw ImportFailure.rejected("limite décompressée dépassée : \(candidate.path)")
                    }
                    try space(count)
                    try handle.write(contentsOf: data)
                    bytes += count
                    total += count
                    hash.update(data: data)
                    progress(ImportProgress(files: pages.count, bytes: total))
                }
                if let entry = candidate.entry, let archive {
                    let crc = try archive.extract(entry, bufferSize: 64 * 1_024, skipCRC32: false, consumer: consume)
                    guard crc == entry.checksum else { throw ImportFailure.rejected("CRC ZIP invalide : \(candidate.path)") }
                } else if let url = candidate.url {
                    let input = try FileHandle(forReadingFrom: url)
                    defer { try? input.close() }
                    while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty { try consume(chunk) }
                }
                guard bytes == candidate.size else { throw ImportFailure.rejected("fichier modifié ou ZIP incohérent") }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            fingerprint.update(data: Data(LibraryIdentity.key(try ImportPolicy.normalized(candidate.path), digest).utf8))
            if isXML { xml = try Data(contentsOf: output, options: .mappedIfSafe) }
            else {
                let dimensions = try validateImage(output, path: candidate.path)
                pages.append(ImportedPage(index: pages.count, originalPath: candidate.path, filename: filename,
                                          byteCount: bytes, width: dimensions.0, height: dimensions.1, sha256: digest))
            }
        }
        guard !pages.isEmpty else { throw ImportFailure.rejected("aucune image") }
        let fallback = rootValues.isDirectory == true
            ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        let metadata = try xml.map { try ComicInfo.parse($0, fallback: fallback, limit: limits.xmlBytes) }
            ?? ComicMetadata(series: SeriesMetadata(title: fallback), chapterTitle: fallback)
        let manifest = ImportManifest(version: 1,
            fingerprint: fingerprint.finalize().map { String(format: "%02x", $0) }.joined(),
            metadata: metadata, pages: pages, comicInfoFilename: xml == nil ? nil : "ComicInfo.xml")
        let data = try JSONEncoder().encode(manifest)
        try space(Int64(data.count))
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        progress(ImportProgress(files: pages.count, bytes: total))
        return PreparedImport(id: id, manifest: manifest)
    }

    private func validateImage(_ url: URL, path: String) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              let format = UTType(type as String), format.conforms(to: .image),
              ["public.jpeg", "public.png", "com.compuserve.gif", "org.webmproject.webp",
               "public.heic", "public.heif", "public.tiff", "com.microsoft.bmp"].contains(format.identifier),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Int64(width) <= limits.pixels / Int64(height),
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ImportFailure.rejected("image invalide, multi-image ou dimensions excessives : \(path)")
        }
        return (width, height)
    }
}
