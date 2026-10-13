import SwiftUI
import UniformTypeIdentifiers

/// Le wrapper reste adossé au fichier ; l’archive n’est pas chargée en Data dans l’interface.
struct BackupArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    let url: URL

    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: [])
    }
}

@MainActor
final class LibraryBackupViewModel: ObservableObject {
    let service: LibraryBackupService
    @Published var prepared: PreparedBackup?
    @Published var document: BackupArchiveDocument?
    @Published var safety: [URL] = []
    @Published var message: String?
    @Published var busy = false
    private var exported: URL?

    init(root: URL) { service = LibraryBackupService(root: root) }
    init(service: LibraryBackupService) { self.service = service }

    func refresh() {
        do { safety = try service.safetyArchives() }
        catch { message = error.localizedDescription }
    }

    func export(repository: any LibraryRepository) {
        run {
            try clearExport()
            let url = try service.export(repository: repository)
            exported = url
            document = BackupArchiveDocument(url: url)
        }
    }

    func select(_ url: URL) {
        run {
            if let prepared { try service.discard(prepared); self.prepared = nil }
            prepared = try service.prepare(source: url)
            message = "Archive vérifiée. Aucune donnée n’a encore été remplacée."
        }
    }

    func restore(repository: any LibraryRepository) {
        guard let prepared else { return }
        run {
            message = try service.restore(prepared, repository: repository)
                ?? "Restauration terminée. La sauvegarde de sécurité est conservée ci-dessous."
            self.prepared = nil
        }
        if !service.isPrepared(prepared) { self.prepared = nil }
        refresh()
    }

    func cancel() {
        run {
            if let prepared { try service.discard(prepared); self.prepared = nil }
        }
    }

    func exportFinished(_ result: Result<URL, Error>) {
        switch result {
        case .success: message = "Sauvegarde exportée."
        case .failure(let error): message = "Export annulé ou impossible : \(error.localizedDescription)"
        }
        do { try clearExport() } catch { message = error.localizedDescription }
    }

    func close() {
        cancel()
        do { try clearExport() } catch { message = error.localizedDescription }
    }

    private func clearExport() throws {
        if let exported { try service.discardExport(exported) }
        exported = nil
        document = nil
    }

    private func run(_ operation: () throws -> Void) {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try operation() } catch { message = error.localizedDescription }
    }
}

@MainActor
struct LibraryBackupView: View {
    @ObservedObject var model: LibraryModel
    @StateObject private var backup: LibraryBackupViewModel
    @State private var showsImporter = false
    @State private var showsExporter = false
    @State private var confirmsReplace = false

    init(model: LibraryModel) {
        self.model = model
        _backup = StateObject(wrappedValue: LibraryBackupViewModel(root: model.root))
    }

    var body: some View {
        Form {
            Section("Archive complète") {
                Text("Toutes les séries, même hors bibliothèque, catégories, progression, signets, historique, réglages et fichiers privés sont inclus. L’archive n’est pas chiffrée : conservez-la dans un emplacement sûr.")
                Button("Exporter une sauvegarde ZIP") {
                    backup.export(repository: model.repository)
                    showsExporter = backup.document != nil
                }
                Button("Choisir une sauvegarde à restaurer") { showsImporter = true }
                Text("Terminez ou annulez tout import avant cette opération. La copie peut prendre du temps ; gardez l’application au premier plan.")
            }
            if let value = backup.prepared {
                Section("Aperçu vérifié") {
                    Text("\(value.manifest.snapshot.series.count) séries · \(value.manifest.snapshot.series.flatMap(\.chapters).count) chapitres")
                    Text("\(value.manifest.snapshot.categories.count) catégories · \(value.manifest.files.count) fichiers")
                    Text(value.manifest.createdAt, style: .date)
                    Text("Remplacement intégral, sans fusion. Une sauvegarde de sécurité de l’état actuel sera créée avant toute modification. Les originaux dans Fichiers restent intacts.")
                    Button("Remplacer toutes les données", role: .destructive) { confirmsReplace = true }
                    Button("Annuler la préparation", role: .cancel) { backup.cancel() }
                }
            }
            Section("Sauvegardes de sécurité conservées") {
                if backup.safety.isEmpty { Text("Aucune restauration effectuée.") }
                ForEach(backup.safety, id: \.self) { url in
                    ShareLink(item: url) {
                        Label("Partager la sécurité \(url.deletingLastPathComponent().lastPathComponent.prefix(8))",
                              systemImage: "square.and.arrow.up")
                    }
                }
                Text("Pour revenir en arrière, partagez le ZIP dans Fichiers puis choisissez-le à restaurer. Ces archives ne sont pas supprimées automatiquement.")
            }
            if let message = backup.message { Section("Résultat") { Text(message) } }
        }
        .disabled(backup.busy)
        .navigationTitle("Sauvegarde")
        .onAppear { backup.refresh() }
        .onDisappear { if !showsExporter { backup.close() } }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): backup.select(url)
            case .failure(let error): backup.message = "Sélection impossible : \(error.localizedDescription)"
            }
        }

        /// Même si la reprise bloque le dépôt, les sécurités restent exportables sans écrivain.
        @MainActor
        struct BackupRecoveryFilesView: View {
            @State private var archives: [URL] = []
            @State private var message: String?

            var body: some View {
                VStack {
                    ForEach(archives, id: \.self) { url in
                        ShareLink(item: url) {
                            Label("Exporter la sauvegarde de sécurité \(url.deletingLastPathComponent().lastPathComponent.prefix(8))",
                                  systemImage: "square.and.arrow.up")
                        }
                    }
                    if let message { Text(message).font(.caption) }
                }
                .task {
                    do { archives = try LibraryBackupService(root: LocalImportService.defaultRoot()).safetyArchives() }
                    catch { message = "Accès aux sauvegardes impossible : \(error.localizedDescription)" }
                }
            }
        }
        .fileExporter(isPresented: $showsExporter, document: backup.document,
                      contentType: .zip, defaultFilename: "MangaiOS-sauvegarde") { backup.exportFinished($0) }
        .alert("Confirmer le remplacement ?", isPresented: $confirmsReplace) {
            Button("Annuler", role: .cancel) {}
            Button("Confirmer : remplacer", role: .destructive) {
                backup.restore(repository: model.repository)
                model.refresh()
            }
        } message: {
            Text("Toutes les données et copies privées actuelles seront remplacées. Une archive de sécurité complète sera conservée. Cette opération n’est pas une fusion.")
        }
    }
}
