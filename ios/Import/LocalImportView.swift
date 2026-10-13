import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LocalImportViewModel: ObservableObject {
    @Published private(set) var prepared: PreparedImport?
    @Published private(set) var existing: [SeriesSnapshot] = []
    @Published private(set) var busy = false
    @Published private(set) var progress = ImportProgress(files: 0, bytes: 0)
    @Published private(set) var message: String?
    @Published var title = ""
    @Published var targetID: UUID?
    @Published var separateCopy = false
    private let repository: any LibraryRepository
    private let service: LocalImportService
    private var task: Task<Void, Never>?

    init(repository: any LibraryRepository, service: LocalImportService) {
        self.repository = repository
        self.service = service
    }

    func prepare(_ url: URL) {
        guard !busy, prepared == nil else { return }
        busy = true
        message = nil
        progress = ImportProgress(files: 0, bytes: 0)
        task = Task {
            do {
                existing = try repository.allSeries(inLibraryOnly: false)
                let value = try await service.prepare(source: url) { [weak self] value in
                    Task { @MainActor [weak self] in self?.progress = value }
                }
                prepared = value
                title = value.manifest.metadata.series.title
                targetID = nil
                separateCopy = false
            } catch {
                message = error is CancellationError ? "Import annulé." : error.localizedDescription
            }
            busy = false
            task = nil
        }
    }

    func confirm() {
        guard let prepared, !busy else { return }
        busy = true
        message = nil
        task = Task {
            do {
                var metadata = prepared.manifest.metadata.series
                metadata.title = title
                let target = targetID.map(ImportTarget.existingSeries) ?? .newSeries(metadata)
                let saved = try await ImportCommitter.commit(prepared, target: target, allowDuplicate: separateCopy,
                                                            repository: repository, service: service)
                self.prepared = nil
                message = "Import terminé : « \(saved.title) », \(saved.pageCount) pages."
            } catch {
                message = error is CancellationError ? "Import annulé." : error.localizedDescription
                if !(await service.isPrepared(prepared)) { self.prepared = nil }
                // install peut avoir réussi puis été annulé : ne pas conserver une préparation expirée.
                if error is CancellationError {
                    do { try await service.discard(prepared); self.prepared = nil }
                    catch { message = error.localizedDescription }
                }
            }
            busy = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    func selectionFailed(_ error: Error) {
        message = "Sélection Fichiers impossible : \(error.localizedDescription)"
    }

    func discard() async -> Bool {
        guard !busy else { cancel(); return false }
        if let prepared {
            do { try await service.discard(prepared); self.prepared = nil }
            catch { message = error.localizedDescription; return false }
        }
        return true
    }
}

@MainActor
struct LocalImportView: View {
    @StateObject private var model: LocalImportViewModel
    @State private var showsPicker = false
    @Environment(\.dismiss) private var dismiss

    init(repository: any LibraryRepository, service: LocalImportService) {
        _model = StateObject(wrappedValue: LocalImportViewModel(repository: repository, service: service))
    }

    private var contentTypes: [UTType] {
        [.zip, .folder, UTType(importedAs: "org.mangaios.cbz", conformingTo: .zip)]
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.prepared == nil {
                    Button("Choisir un ZIP, CBZ ou dossier d’images") { showsPicker = true }
                        .disabled(model.busy)
                    Text("L’original reste intact. Une copie privée sera créée après confirmation.")
                }
                if model.busy {
                    ProgressView()
                    Text("\(model.progress.files) images validées · \(model.progress.bytes / 1_024) Kio copiés")
                    Button("Annuler l’opération", role: .cancel) { model.cancel() }
                }
                if let prepared = model.prepared {
                    Section("Confirmation") {
                        Text("\(prepared.manifest.pages.count) pages · \(prepared.manifest.metadata.chapterTitle)")
                        Picker("Destination", selection: $model.targetID) {
                            Text("Nouvelle série").tag(nil as UUID?)
                            ForEach(model.existing, id: \.id) { series in
                                Text(series.metadata.title).tag(Optional(series.id))
                            }
                        }
                        if model.targetID == nil { TextField("Titre de la nouvelle série", text: $model.title) }
                        Text("Auteur(s) : " + prepared.manifest.metadata.series.authors.joined(separator: ", "))
                        Text("Artiste(s) : " + prepared.manifest.metadata.series.artists.joined(separator: ", "))
                        Text("Genres : " + prepared.manifest.metadata.series.genres.joined(separator: ", "))
                        Text("Statut proposé : " + prepared.manifest.metadata.series.status.rawValue)
                        if let number = prepared.manifest.metadata.number { Text("Numéro : \(String(number))") }
                        if !prepared.manifest.metadata.series.summary.isEmpty {
                            Text(prepared.manifest.metadata.series.summary)
                        }
                        if let date = prepared.manifest.metadata.publicationDate { Text("Date : \(date)") }
                        Text("Traducteurs : " + prepared.manifest.metadata.translators.joined(separator: ", "))
                        Text("Catégories proposées (non appliquées) : " + prepared.manifest.metadata.categories.joined(separator: ", "))
                        if let source = prepared.manifest.metadata.source { Text("Source déclarée (inactive) : \(source)") }
                        ForEach(prepared.manifest.metadata.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                        Text("Une série existante garde ses métadonnées, catégories et progression. Dates et traducteurs sont conservés dans le manifeste, pas dans les champs du chapitre.")
                        Toggle("Autoriser explicitement une copie séparée en cas de doublon", isOn: $model.separateCopy)
                        Text("Par défaut les doublons sont refusés. Aucun chapitre n’est remplacé.")
                        Button("Confirmer l’import") { model.confirm() }
                            .disabled(model.targetID == nil && model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .disabled(model.busy)
                }
                if let message = model.message { Section("Résultat") { Text(message) } }
            }
            .navigationTitle("Import local")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        Task { if await model.discard() { dismiss() } }
                    }
                }
            }
            .fileImporter(isPresented: $showsPicker, allowedContentTypes: contentTypes) { result in
                switch result {
                case .success(let url): model.prepare(url)
                case .failure(let error): model.selectionFailed(error)
                }
            }
            .interactiveDismissDisabled(model.busy || model.prepared != nil)
            .onDisappear { model.cancel() }
        }
    }
}
