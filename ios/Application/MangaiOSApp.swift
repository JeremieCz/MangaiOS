import SwiftData
import SwiftUI

@main
@MainActor
struct MangaiOSApp: App {
    private struct Dependencies {
        let container: ModelContainer
        let repository: SwiftDataLibraryRepository
        let importer: LocalImportService
    }
    private let storage: Result<Dependencies, Error>

    init() {
        storage = Result {
            let container = try StorageFactory.makeContainer()
            return Dependencies(container: container, repository: try SwiftDataLibraryRepository(container: container),
                                importer: LocalImportService(root: try LocalImportService.defaultRoot()))
        }
    }

    var body: some Scene {
        WindowGroup {
            switch storage {
            case .success(let dependencies):
                LibraryPlaceholderView(repository: dependencies.repository, importer: dependencies.importer)
                    .modelContainer(dependencies.container)
            case .failure:
                ContentUnavailableView(
                    "Stockage indisponible",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(
                        "Impossible d’ouvrir les données locales. Aucune donnée n’a été effacée. "
                        + "Relancez l’application après avoir vérifié l’espace disponible."
                    )
                )
            }
        }
    }
}
