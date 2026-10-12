import SwiftData

enum StorageSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            StorageMetadata.self, StoredSeries.self, StoredChapter.self,
            StoredCategory.self, StoredFile.self, StoredPage.self, StoredHistory.self,
            StoredGlobalPreferences.self, StoredSeriesPreferences.self
        ]
    }
}
