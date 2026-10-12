import SwiftData
import SwiftUI

@main
struct MangaiOSApp: App {
    private let storage: Result<ModelContainer, Error>

    init() {
        storage = Result { try StorageFactory.makeContainer() }
    }

    var body: some Scene {
        WindowGroup {
            switch storage {
            case .success(let container):
                LibraryPlaceholderView()
                    .modelContainer(container)
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
