import Foundation

/// Tous les écrivains applicatifs passent par ce verrou, dans un seul processus.
@MainActor
enum MutationGate {
    private static var imports: [UUID: URL] = [:]
    private(set) static var exclusive = false
    private(set) static var generation = UUID()
    private(set) static var recoveryRequired = false
    private static var replacementAllowed = false

    static func didReplace() { generation = UUID() }
    static func requireRecovery() { recoveryRequired = true }
    static func recoveryFinished() { recoveryRequired = false }

    static func requireReplacementAccess() throws {
        if exclusive {
            guard replacementAllowed else { throw DomainError.invalidValue("remplacement réservé à la restauration") }
        } else { try requireWritable() }
    }

    static func withReplacement<T>(_ operation: () throws -> T) throws -> T {
        guard exclusive, !replacementAllowed else { throw DomainError.invalidValue("transaction de restauration absente") }
        replacementAllowed = true
        defer { replacementAllowed = false }
        return try operation()
    }

    static func beginImport(_ id: UUID, root: URL) throws {
        try requireWritable()
        guard imports[id] == nil else { throw DomainError.duplicate("import actif") }
        imports[id] = root.resolvingSymlinksInPath().standardizedFileURL
    }

    static func endImport(_ id: UUID) { imports.removeValue(forKey: id) }

    static func requireWritable() throws {
        guard !recoveryRequired else { throw DomainError.invalidValue("récupération requise : relancez l’application") }
        guard !exclusive else { throw DomainError.invalidValue("sauvegarde ou restauration en cours") }
    }

    static func withExclusive<T>(root: URL, _ operation: () throws -> T) throws -> T {
        guard !exclusive, !imports.values.contains(root.resolvingSymlinksInPath().standardizedFileURL) else {
            throw DomainError.invalidValue("terminez ou annulez l’import avant la sauvegarde")
        }
        exclusive = true
        defer { exclusive = false }
        return try operation()
    }
}
