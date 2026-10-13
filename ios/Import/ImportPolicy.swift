import Foundation

extension DomainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPath: return "Chemin local invalide."
        case .invalidValue(let value): return "Valeur invalide : \(value)."
        case .duplicate(let value): return "Doublon refusé : \(value). Aucun contenu n’a été remplacé."
        case .notFound: return "La destination ou le contenu demandé n’existe plus."
        case .protectedCategory: return "La catégorie système est protégée."
        }
    }
}

struct ImportLimits: Sendable {
    var entries = 10_000
    var pages = 2_000
    var fileBytes: Int64 = 100 * 1_024 * 1_024
    var totalBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    var archiveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    var xmlBytes = 1_024 * 1_024
    var pixels: Int64 = 80_000_000
    var reserveBytes: Int64 = 64 * 1_024 * 1_024
}

enum ImportFailure: Error, LocalizedError {
    case rejected(String)
    case cleanup(String, String)

    var errorDescription: String? {
        switch self {
        case .rejected(let reason): return "Import refusé : \(reason)"
        case .cleanup(let original, let cleanup):
            return "\(original). Nettoyage incomplet : \(cleanup). Les fichiers privés sont conservés, sans toucher à l’original."
        }
    }
}

enum ImportPolicy {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    static func normalized(_ path: String) throws -> String {
        _ = try RelativePath(path)
        guard path.utf8.count <= 1_024 else { throw ImportFailure.rejected("chemin trop long") }
        return path.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func ignored(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__MACOSX" }
    }

    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.compare(rhs, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return comparison == .orderedSame ? lhs.utf8.lexicographicallyPrecedes(rhs.utf8) : comparison == .orderedAscending
    }

    static func requireSpace(available: Int64, needed: Int64, reserve: Int64) throws {
        guard needed >= 0, reserve >= 0, available >= reserve, needed <= available - reserve else {
            throw ImportFailure.rejected("espace disque insuffisant")
        }
    }
}

/// ZIP classique seulement : la vérification compte aussi les entrées que ZIPFoundation
/// arrêterait silencieusement d’énumérer (notamment une entrée chiffrée).
enum ZIPPreflight {
    static func entryCount(at url: URL, limits: ImportLimits) throws -> Int {
        guard limits.archiveBytes > 0, limits.entries > 0 else {
            throw ImportFailure.rejected("limites ZIP invalides")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22, size <= UInt64(limits.archiveBytes) else {
            throw ImportFailure.rejected("taille ZIP invalide")
        }
        try handle.seek(toOffset: size - min(size, 65_557))
        let tail = try handle.readToEnd() ?? Data()
        func u16(_ data: Data, _ offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
        }
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            u32(tail, $0) == 0x06054b50 && $0 + 22 + Int(u16(tail, $0 + 20)) == tail.count
        }) else { throw ImportFailure.rejected("ZIP incomplet") }
        let count = Int(u16(tail, end + 10))
        let centralSize = UInt64(u32(tail, end + 12))
        let centralOffset = UInt64(u32(tail, end + 16))
        let endOffset = size - UInt64(tail.count) + UInt64(end)
        guard u16(tail, end + 4) == 0, u16(tail, end + 6) == 0,
              u16(tail, end + 8) == UInt16(count),
              count > 0, count < 65_535, count <= limits.entries,
              centralOffset + centralSize == endOffset else {
            throw ImportFailure.rejected("ZIP vide, multi-volume, ZIP64 ou limite d’entrées")
        }
        var offset = centralOffset
        for _ in 0..<count {
            try Task.checkCancellation()
            try handle.seek(toOffset: offset)
            let header = try handle.read(upToCount: 46) ?? Data()
            guard header.count == 46, u32(header, 0) == 0x02014b50,
                  u16(header, 8) & 0x0041 == 0,
                  [UInt16(0), UInt16(8)].contains(u16(header, 10)),
                  u16(header, 34) == 0,
                  u32(header, 20) != UInt32.max, u32(header, 24) != UInt32.max,
                  u32(header, 42) != UInt32.max else {
                throw ImportFailure.rejected("ZIP chiffré, corrompu ou compression non prise en charge")
            }
            let localOffset = UInt64(u32(header, 42))
            let nameLength = Int(u16(header, 28))
            let name = try handle.read(upToCount: nameLength) ?? Data()
            guard name.count == nameLength, localOffset + 30 <= centralOffset else {
                throw ImportFailure.rejected("en-tête ZIP invalide")
            }
            try handle.seek(toOffset: localOffset)
            let local = try handle.read(upToCount: 30) ?? Data()
            guard local.count == 30, u32(local, 0) == 0x04034b50,
                  u16(local, 6) == u16(header, 8), u16(local, 8) == u16(header, 10),
                  Int(u16(local, 26)) == nameLength,
                  localOffset + 30 + UInt64(nameLength) + UInt64(u16(local, 28))
                    + UInt64(u32(header, 20)) <= centralOffset,
                  try handle.read(upToCount: nameLength) == name else {
                throw ImportFailure.rejected("en-têtes ZIP incohérents")
            }
            if u16(header, 8) & 8 == 0 {
                guard u32(local, 14) == u32(header, 16),
                      u32(local, 18) == u32(header, 20), u32(local, 22) == u32(header, 24) else {
                    throw ImportFailure.rejected("tailles ou CRC ZIP incohérents")
                }
            } else {
                let descriptorOffset = localOffset + 30 + UInt64(nameLength)
                    + UInt64(u16(local, 28)) + UInt64(u32(header, 20))
                try handle.seek(toOffset: descriptorOffset)
                let descriptor = try handle.read(upToCount: 16) ?? Data()
                guard descriptor.count >= 12 else { throw ImportFailure.rejected("descripteur ZIP incomplet") }
                let start = u32(descriptor, 0) == 0x08074b50 ? 4 : 0
                guard descriptor.count >= start + 12, descriptorOffset + UInt64(start + 12) <= centralOffset,
                      u32(descriptor, start) == u32(header, 16),
                      u32(descriptor, start + 4) == u32(header, 20),
                      u32(descriptor, start + 8) == u32(header, 24) else {
                    throw ImportFailure.rejected("descripteur ZIP incohérent")
                }
            }
            offset += 46 + UInt64(nameLength) + UInt64(u16(header, 30)) + UInt64(u16(header, 32))
            guard offset <= endOffset else { throw ImportFailure.rejected("répertoire ZIP invalide") }
        }
        guard offset == endOffset else { throw ImportFailure.rejected("répertoire ZIP incomplet") }
        return count
    }
}
