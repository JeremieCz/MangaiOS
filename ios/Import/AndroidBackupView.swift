import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AndroidBackupView: View {
    @ObservedObject var model: LibraryModel
    @State private var backup: AndroidBackup?
    @State private var showsPicker = false
    @State private var busy = false
    @State private var readerModes = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Android → iOS · EXPERIMENTAL") {
                Text("Format courant .tachibk (gzip) ou protobuf brut. Fusion de métadonnées uniquement, sans remplacement de votre bibliothèque. Aucun compte, secret, suivi, dépôt d’extensions ou préférence privée.")
                Button("Choisir une sauvegarde Android") { showsPicker = true }
                Text("Aucune image dans la sauvegarde Android : les chapitres restent indisponibles jusqu’au rattachement explicite de fichiers locaux via Import local. Aucun téléchargement réseau.")
            }
            if busy { ProgressView("Lecture et vérification bornées…") }
            if let backup {
                Section("Aperçu avant confirmation") {
                    Text("\(backup.localCount) séries locales · \(backup.series.count - backup.localCount) séries distantes inactives")
                    Text("\(backup.series.flatMap(\.chapters).count) chapitres · \(backup.categories.count) catégories")
                    Text("Un doublon d’identité annule toute la fusion avant installation. Les titres, notes et réglages existants restent prioritaires. Les catégories portant le même nom sont réutilisées.")
                    Toggle("Importer uniquement le mode lecteur connu de chaque série", isOn: $readerModes)
                    Text("Option désactivée par défaut ; les réglages globaux iOS ne changent jamais.")
                    ForEach(backup.diagnostics, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    Button("Confirmer la fusion des métadonnées") {
                        do {
                            try AndroidBackupCommitter.commit(backup, root: model.root, repository: model.repository,
                                                              includeReaderModes: readerModes)
                            self.backup = nil
                            message = "Fusion terminée. Rattachez ensuite les fichiers locaux aux chapitres choisis."
                            model.refresh()
                        } catch { message = error.localizedDescription }
                    }
                    Button("Annuler l’aperçu", role: .cancel) { self.backup = nil }
                }
            }
            if let message { Section("Résultat") { Text(message) } }
        }
        .disabled(busy)
        .navigationTitle("Import Android")
        .fileImporter(isPresented: $showsPicker, allowedContentTypes: [
            UTType(importedAs: "org.mangaios.tachibk", conformingTo: .data), .data
        ]) { result in
            switch result {
            case .failure(let error): message = error.localizedDescription
            case .success(let url):
                busy = true
                backup = nil
                message = nil
                readerModes = false
                Task {
                    do {
                        backup = try await Task.detached(priority: .userInitiated) {
                            try AndroidBackupDecoder.decode(AndroidBackupFile.read(url))
                        }.value
                    } catch { message = error.localizedDescription }
                    busy = false
                }
            }
        }
    }
}
