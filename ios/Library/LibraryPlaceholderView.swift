import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    let repository: any LibraryRepository
    let importer: LocalImportService
    let root: URL
    @Published var series: [SeriesSnapshot] = []
    @Published var categories: [CategorySnapshot] = []
    @Published var history: [HistorySnapshot] = []
    @Published var preferences = ReadingPreferences()
    @Published var error: String?
    @Published private(set) var contentGeneration = MutationGate.generation

    init(repository: any LibraryRepository, importer: LocalImportService, root: URL, initialError: String? = nil) {
        self.repository = repository; self.importer = importer; self.root = root
        error = initialError
    }

    func refresh() {
        do {
            series = try repository.allSeries(inLibraryOnly: false)
            categories = try repository.categories()
            history = try repository.history()
            preferences = try repository.globalPreferences()
            contentGeneration = MutationGate.generation
        } catch { self.error = error.localizedDescription }
    }

    func perform(_ action: () throws -> Void) {
        do { try action(); refresh() } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct LibraryPlaceholderView: View {
    @StateObject private var model: LibraryModel
    @State private var query = ""
    @State private var sort = LibrarySort.title
    @State private var category: UUID?
    @State private var inLibraryOnly = true
    @State private var showsImport = false

    init(repository: any LibraryRepository, importer: LocalImportService, root: URL, initialError: String? = nil) {
        _model = StateObject(wrappedValue: LibraryModel(repository: repository, importer: importer, root: root,
                                                      initialError: initialError))
    }

    var body: some View {
        TabView {
            AdaptiveLibraryNavigation {
                List {
                    Section {
                        Toggle("Dans la bibliothèque uniquement", isOn: $inLibraryOnly)
                        Picker("Trier", selection: $sort) {
                            ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }

                        Picker("Catégorie", selection: $category) {
                            Text("Toutes").tag(Optional<UUID>.none)
                            ForEach(model.categories, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    ForEach(LibrarySelection.filtered(model.series, query: query, category: category,
                                                       inLibraryOnly: inLibraryOnly, sort: sort), id: \.id) { series in
                        NavigationLink {
                            SeriesDetailView(model: model, seriesID: series.id)
                        } label: {
                            HStack {
                                CoverThumbnail(series: series, root: model.root, generation: model.contentGeneration)
                                VStack(alignment: .leading) {
                                    Text(series.metadata.title).font(.headline)
                                    let counts = LibrarySelection.counters(series)
                                    Text("\(counts.unread) non lus · \(counts.read) lus · \(counts.bookmarked) signets")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if model.series.isEmpty {
                        Text("Importez un chapitre local pour commencer.").foregroundStyle(.secondary)
                    }
                }
                .searchable(text: $query, prompt: "Rechercher un titre")
                .navigationTitle("Bibliothèque")
                .toolbar { Button("Importer", systemImage: "square.and.arrow.down") { showsImport = true } }
            }.tabItem { Label("Bibliothèque", systemImage: "books.vertical") }
            NavigationStack {
                List(model.history, id: \.id) { entry in
                    if let series = model.series.first(where: { $0.chapters.contains { $0.id == entry.chapterID } }),
                       let chapter = series.chapters.first(where: { $0.id == entry.chapterID }) {
                        NavigationLink {
                            ReaderView(model: model, chapterID: chapter.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(series.metadata.title).font(.headline)
                                Text("\(chapter.title) · Page \(entry.lastPageIndex + 1)")
                                Text(entry.lastReadAt, style: .date).font(.caption)
                            }
                        }
                    }
                }.navigationTitle("Historique")
            }.tabItem { Label("Historique", systemImage: "clock") }
            NavigationStack {
                LibrarySettingsView(model: model)
            }.tabItem { Label("Réglages", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showsImport, onDismiss: model.refresh) {
            LocalImportView(repository: model.repository, service: model.importer)
        }
        .onAppear { model.refresh() }
        .alert("Impossible de terminer", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

@MainActor
private struct AdaptiveLibraryNavigation<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                content.navigationSplitViewColumnWidth(min: 300, ideal: 380)
            } detail: {
                ContentUnavailableView("Choisissez une série", systemImage: "books.vertical")
            }
        } else { NavigationStack { content } }
    }
}

@MainActor
struct SeriesDetailView: View {
    @ObservedObject var model: LibraryModel
    let seriesID: UUID
    @State private var editing = false

    private var series: SeriesSnapshot? { model.series.first { $0.id == seriesID } }

    var body: some View {
        Group {
            if let series {
                List {
                    Section {
                        HStack { CoverThumbnail(series: series, root: model.root, generation: model.contentGeneration); Text(series.metadata.title).font(.title2) }
                        Text(series.metadata.summary)
                        if !series.metadata.notes.isEmpty { Text(series.metadata.notes) }
                        Button(series.isInLibrary ? "Retirer de la bibliothèque" : "Ajouter à la bibliothèque") {
                            model.perform { try model.repository.setFavorite(id: seriesID, at: series.isInLibrary ? nil : Date()) }
                        }
                        Button("Modifier les métadonnées") { editing = true }
                        if let chapter = LibrarySelection.resume(series) {
                            NavigationLink("Reprendre") { ReaderView(model: model, chapterID: chapter.id) }
                        }
                    }
                    Section("Catégories") {
                        ForEach(model.categories.filter { !$0.isSystem }, id: \.id) { category in
                            Toggle(category.name, isOn: Binding(
                                get: { series.categoryIDs.contains(category.id) },
                                set: { selected in
                                    var ids = series.categoryIDs.filter { $0 != category.id }
                                    if selected { ids.append(category.id) }
                                    model.perform { try model.repository.setCategories(seriesID: seriesID, categoryIDs: ids) }
                                }
                            ))
                        }
                    }
                    Section("Lecture de cette série") { SeriesPreferencesView(model: model, series: series) }
                    Section("Chapitres") {
                        ForEach(LibrarySelection.orderedChapters(series), id: \.id) { chapter in
                            VStack(alignment: .leading) {
                                NavigationLink(chapter.title) { ReaderView(model: model, chapterID: chapter.id) }
                                HStack {
                                    Button(chapter.isRead ? "Marquer non lu" : "Marquer lu") {
                                        model.perform { try model.repository.setRead(chapterID: chapter.id, isRead: !chapter.isRead) }
                                    }
                                    Button(chapter.isBookmarked ? "Retirer le signet" : "Ajouter un signet") {
                                        model.perform { try model.repository.setBookmark(chapterID: chapter.id, isBookmarked: !chapter.isBookmarked) }
                                    }
                                }.font(.caption).buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .navigationTitle(series.metadata.title)
                .sheet(isPresented: $editing) { MetadataEditor(model: model, series: series) }
            } else { ContentUnavailableView("Série indisponible", systemImage: "book.closed") }
        }.onAppear { model.refresh() }
    }
}

@MainActor
private struct MetadataEditor: View {
    @ObservedObject var model: LibraryModel
    let series: SeriesSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: SeriesMetadata
    @State private var authors: String
    @State private var artists: String
    @State private var genres: String
    @State private var error: String?

    init(model: LibraryModel, series: SeriesSnapshot) {
        self.model = model; self.series = series
        _metadata = State(initialValue: series.metadata)
        _authors = State(initialValue: series.metadata.authors.joined(separator: ", "))
        _artists = State(initialValue: series.metadata.artists.joined(separator: ", "))
        _genres = State(initialValue: series.metadata.genres.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Titre", text: $metadata.title)
                TextField("Auteurs (virgules)", text: $authors)
                TextField("Artistes (virgules)", text: $artists)
                TextField("Genres (virgules)", text: $genres)
                Picker("Statut", selection: $metadata.status) {
                    ForEach(SeriesStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Section("Résumé") { TextEditor(text: $metadata.summary).frame(minHeight: 100) }
                Section("Notes personnelles") { TextEditor(text: $metadata.notes).frame(minHeight: 100) }
                Toggle("Noter la série", isOn: Binding(get: { metadata.rating != nil },
                    set: { metadata.rating = $0 ? 5 : nil }))
                if metadata.rating != nil {
                    Slider(value: Binding(get: { metadata.rating ?? 5 }, set: { metadata.rating = $0 }), in: 0...10, step: 0.5)
                        .accessibilityLabel("Note sur dix")
                    Text("Note : \(metadata.rating ?? 0, specifier: "%.1f") / 10")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Métadonnées")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        func values(_ text: String) -> [String] {
                            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        }
                        metadata.authors = values(authors); metadata.artists = values(artists); metadata.genres = values(genres)
                        do {
                            try model.repository.updateSeries(id: series.id, metadata: metadata)
                            model.refresh(); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
