import SwiftUI

struct LegalNoticesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Attributions amont") {
                    Text("Copyright © 2015 Javier Tomás")
                    Text("Copyright © 2024 Mihon Open Source Project")
                    Text("Projet issu de Tachiyomi et Mihon, sous licence Apache 2.0.")
                }

                Section("Documents") {
                    ForEach(LegalDocument.allCases) { document in
                        NavigationLink(document.title) {
                            LegalDocumentView(document: document)
                        }
                    }
                }

                Section("NOTICE amont") {
                    Text(
                        "Aucun fichier NOTICE original n’a été trouvé dans le dépôt fourni. "
                        + "La notice iOS ne le remplace pas. L’original sera conservé sans "
                        + "modification et ajouté aux ressources dès qu’il sera disponible."
                    )
                }
            }
            .navigationTitle("Mentions légales")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

private struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        Group {
            if let text = try? document.text() {
                ScrollView {
                    Text(verbatim: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView(
                    "Document indisponible",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("Le document légal n’a pas pu être chargé.")
                )
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
