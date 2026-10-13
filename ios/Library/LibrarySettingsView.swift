import SwiftUI

@MainActor
struct LibrarySettingsView: View {
    @ObservedObject var model: LibraryModel
    var body: some View {
        Form {
            Section("Lecture par défaut") {
                Picker("Mode", selection: Binding(get: { model.preferences.mode }, set: { mode in
                    var value = model.preferences; value.mode = mode
                    model.perform { try model.repository.setGlobalPreferences(value) }
                })) {
                    ForEach(ReadingMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Doubles pages", selection: Binding(get: { model.preferences.doublePages }, set: { policy in
                    var value = model.preferences; value.doublePages = policy
                    model.perform { try model.repository.setGlobalPreferences(value) }
                })) {
                    ForEach(DoublePagePolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Isoler la couverture", isOn: Binding(get: { model.preferences.isolateCover }, set: { isolate in
                    var value = model.preferences; value.isolateCover = isolate
                    model.perform { try model.repository.setGlobalPreferences(value) }
                }))
            }
            NavigationLink("Gérer les catégories") { CategoryManagerView(model: model) }
            NavigationLink("Sauvegarde et restauration") { LibraryBackupView(model: model) }
            NavigationLink("Mentions légales") { LegalNoticesView() }
        }.navigationTitle("Réglages")
    }
}

@MainActor
struct SeriesPreferencesView: View {
    @ObservedObject var model: LibraryModel
    let series: SeriesSnapshot
    private func save(_ mutate: (inout SeriesReadingPreferences) -> Void) {
        var value = series.preferences; mutate(&value)
        model.perform { try model.repository.setSeriesPreferences(seriesID: series.id, value: value) }
    }
    var body: some View {
        Picker("Mode", selection: Binding(get: { series.preferences.mode }, set: { mode in save { $0.mode = mode } })) {
            Text("Hériter").tag(Optional<ReadingMode>.none)
            ForEach(ReadingMode.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        Picker("Doubles pages", selection: Binding(get: { series.preferences.doublePages }, set: { policy in save { $0.doublePages = policy } })) {
            Text("Hériter").tag(Optional<DoublePagePolicy>.none)
            ForEach(DoublePagePolicy.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        Picker("Couverture isolée", selection: Binding(get: { series.preferences.isolateCover }, set: { isolate in save { $0.isolateCover = isolate } })) {
            Text("Hériter").tag(Optional<Bool>.none)
            Text("Oui").tag(Optional(true)); Text("Non").tag(Optional(false))
        }
    }
}

@MainActor
struct CategoryManagerView: View {
    @ObservedObject var model: LibraryModel
    @State private var name = ""
    @State private var renamed: CategorySnapshot?
    @State private var newName = ""
    private var users: [CategorySnapshot] { model.categories.filter { !$0.isSystem } }
    var body: some View {
        List {
            Section("Créer") {
                TextField("Nom", text: $name)
                Button("Ajouter") {
                    model.perform { _ = try model.repository.createCategory(id: UUID(), name: name) }
                    if model.error == nil { name = "" }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Catégorie système protégée") {
                ForEach(model.categories.filter(\.isSystem), id: \.id) { Text($0.name) }
            }
            Section("Catégories personnelles") {
                ForEach(users, id: \.id) { category in
                    Button(category.name) { renamed = category; newName = category.name }
                }
                .onDelete { offsets in
                    let ids = offsets.map { users[$0].id }
                    model.perform { for id in ids { try model.repository.deleteCategory(id: id) } }
                }
                .onMove { source, destination in
                    var ids = users.map(\.id); ids.move(fromOffsets: source, toOffset: destination)
                    model.perform { try model.repository.reorderCategories(ids: ids) }
                }
            }
        }
        .navigationTitle("Catégories").toolbar { EditButton() }
        .alert("Renommer", isPresented: Binding(get: { renamed != nil }, set: { if !$0 { renamed = nil } })) {
            TextField("Nom", text: $newName)
            Button("Annuler", role: .cancel) { renamed = nil }
            Button("Enregistrer") {
                if let renamed { model.perform { try model.repository.renameCategory(id: renamed.id, name: newName) } }
                renamed = nil
            }
        }
    }
}
