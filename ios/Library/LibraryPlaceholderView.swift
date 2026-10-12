import SwiftUI

struct LibraryPlaceholderView: View {
    @State private var showsLegalNotices = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Votre bibliothèque",
                systemImage: "books.vertical",
                description: Text(
                    "Le socle iOS est prêt. L’import et la lecture seront ajoutés "
                    + "dans les prochaines étapes."
                )
            )
            .navigationTitle("MangaiOS")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mentions légales", systemImage: "info.circle") {
                        showsLegalNotices = true
                    }
                }
            }
            .sheet(isPresented: $showsLegalNotices) {
                LegalNoticesView()
            }
        }
    }
}
