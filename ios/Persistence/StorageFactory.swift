import Foundation
import SwiftData

enum StorageFactory {
    static func makeContainer(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: StorageSchemaV2.self)
        let configuration: ModelConfiguration
        if let storeURL {
            guard !inMemory else { throw DomainError.invalidValue("configuration") }
            configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(
            for: schema,
            migrationPlan: StorageMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
