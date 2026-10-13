import SwiftUI
import UIKit

@MainActor
struct ReaderView: View {
    @ObservedObject var model: LibraryModel
    @State private var chapterID: UUID
    @State private var chapter: ChapterSnapshot?
    @State private var preferences = ReadingPreferences()
    @State private var page = 0
    @State private var controls = true
    @State private var splitPanoramas = false
    @State private var gate = ReaderProgressGate()
    @State private var complete = false
    @State private var debounce: Task<Void, Never>?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(model: LibraryModel, chapterID: UUID) {
        self.model = model
        _chapterID = State(initialValue: chapterID)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let chapter, !chapter.pages.isEmpty {
                ReaderCanvas(chapter: chapter, preferences: preferences, splitPanoramas: splitPanoramas,
                             root: model.root, page: page, onVisible: { index, completed in
                    guard scenePhase == .active else { return }
                    page = index; complete = completed
                    gate.visible(index, at: Date())
                    debounce?.cancel()
                    debounce = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                        flush(pausing: false)
                    }
                }, onTap: { controls.toggle() })
                .ignoresSafeArea(edges: controls ? [] : .all)
                if controls {
                    VStack {
                        HStack {
                            Button("Fermer", systemImage: "xmark") { flush(pausing: true); dismiss() }
                            Spacer()
                            Text(chapter.title).lineLimit(2)
                        }
                        Spacer()
                        VStack {
                            Text("Page \(page + 1) / \(chapter.pageCount)").monospacedDigit()
                            Slider(value: Binding(get: { Double(page) }, set: { page = Int($0) }),
                                   in: 0...Double(max(1, chapter.pageCount - 1)), step: 1)
                                .disabled(chapter.pageCount < 2).accessibilityLabel("Aller à la page")
                            Toggle("Séparer les panoramas (session)", isOn: $splitPanoramas)
                            HStack {
                                Button("Chapitre précédent") { navigate(-1) }.disabled(adjacent(-1) == nil)
                                Spacer()
                                Button("Chapitre suivant") { navigate(1) }.disabled(adjacent(1) == nil)
                            }
                        }
                    }
                    .padding().foregroundStyle(.white)
                    .background {
                        VStack { Color.black.opacity(0.8).frame(height: 70); Spacer(); Color.black.opacity(0.8).frame(height: 180) }
                    }
                }
            } else if let error {
                VStack { Text(error); Button("Réessayer") { load() } }.foregroundStyle(.white)
            } else if chapter != nil {
                Text("Ce chapitre ne contient aucune page.").foregroundStyle(.white)
            } else { ProgressView().tint(.white) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .preferredColorScheme(.dark)
        .onAppear { load() }
        .onDisappear { flush(pausing: true); model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flush(pausing: true) }
            else if chapter != nil, let visiblePage = gate.page { gate.visible(visiblePage, at: Date()) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await ReaderImages.shared.clear() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            flush(pausing: true)
        }
        .alert("Lecture", isPresented: Binding(get: { error != nil && chapter != nil }, set: { if !$0 { error = nil } })) {
            Button("Réessayer la sauvegarde") { flush(pausing: true) }
            Button("Fermer", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        do {
            let value = try model.repository.chapter(id: chapterID)
            preferences = try model.repository.resolvedPreferences(seriesID: value.seriesID)
            chapter = value
            page = min(max(0, value.lastPageIndex ?? 0), max(0, value.pageCount - 1))
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func flush(pausing: Bool) {
        debounce?.cancel(); debounce = nil
        let backup = gate
        let now = Date()
        let value = pausing ? gate.pause(at: now) : gate.checkpoint(at: now)
        guard let value else { return }
        do {
            try model.repository.recordReaderProgress(chapterID: chapterID, pageIndex: value.page,
                                                       duration: value.duration, at: now, completed: complete)
        } catch { gate = backup; self.error = error.localizedDescription }
    }

    private func adjacent(_ offset: Int) -> ChapterSnapshot? {
        guard let chapter, let series = model.series.first(where: { $0.id == chapter.seriesID }) else { return nil }
        let chapters = LibrarySelection.orderedChapters(series).filter { !$0.pages.isEmpty }
        guard let index = chapters.firstIndex(where: { $0.id == chapterID }),
              chapters.indices.contains(index + offset) else { return nil }
        return chapters[index + offset]
    }

    private func navigate(_ offset: Int) {
        guard let next = adjacent(offset) else { return }
        flush(pausing: true)
        guard error == nil else { return }
        gate = ReaderProgressGate(); complete = false
        chapterID = next.id; load()
    }
}
