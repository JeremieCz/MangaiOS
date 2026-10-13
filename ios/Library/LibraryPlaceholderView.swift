import SwiftUI

struct LibraryPlaceholderView: View {
    let repository: any LibraryRepository
    let importer: LocalImportService
    @State private var showsLegalNotices = false
    @State private var showsImport = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Votre bibliothèque",
                systemImage: "books.vertical",
                description: Text(
                    "Importez des fichiers locaux. L’affichage de la bibliothèque "
                    + "et la lecture seront ajoutés dans les prochaines étapes."
                )
            )
            .navigationTitle("MangaiOS")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Importer", systemImage: "square.and.arrow.down") { showsImport = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mentions légales", systemImage: "info.circle") {
                        showsLegalNotices = true
                    }
                }
            }
            .sheet(isPresented: $showsLegalNotices) {
                LegalNoticesView()
            }
            .sheet(isPresented: $showsImport) {
                LocalImportView(repository: repository, service: importer)
            }
        }
    }
}
