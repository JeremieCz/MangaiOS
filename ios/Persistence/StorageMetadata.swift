import Foundation
import SwiftData

// Modèle technique du socle ; les modèles métier seront ajoutés à l’étape suivante.
@Model
final class StorageMetadata {
    @Attribute(.unique) var key: String
    var createdAt: Date

    init(key: String = "application", createdAt: Date = .now) {
        self.key = key
        self.createdAt = createdAt
    }
}

enum StorageSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [StorageMetadata.self]
    }
}

enum StorageMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [StorageSchemaV1.self, StorageSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: StorageSchemaV1.self, toVersion: StorageSchemaV2.self)]
    }
}
