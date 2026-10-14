import SwiftUI
import UIKit

@MainActor
struct ReaderCanvas: UIViewRepresentable {
    let chapter: ChapterSnapshot
    let preferences: ReadingPreferences
    let splitPanoramas: Bool
    let root: URL
    let generation: UUID
    let page: Int
    let onVisible: (Int, Bool) -> Void
    let onTap: () -> Void

    func makeUIView(context: Context) -> ReaderCanvasView { ReaderCanvasView() }
    func updateUIView(_ view: ReaderCanvasView, context: Context) {
        view.onVisible = onVisible; view.onTap = onTap
        view.configure(chapter: chapter, preferences: preferences, split: splitPanoramas,
                       root: root, generation: generation, page: page)
    }
    static func dismantleUIView(_ view: ReaderCanvasView, coordinator: ()) { view.dispose() }
}

@MainActor
final class ReaderCanvasView: UIView, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let canvasContent = UIView()
    private let continuousZoomTap = UITapGestureRecognizer()
    private var chapter: ChapterSnapshot?
    private var preferences = ReadingPreferences()
    private var root: URL?
    private var generation = UUID()
    private var split = false
    private var units: [ReaderUnit] = []
    private var cells: [Int: ReaderZoomView] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var frames: [CGRect] = []
    private var lastSize = CGSize.zero
    private var page = 0
    private var lastReported: Int?
    private var memoryObserver: NSObjectProtocol?
    var onVisible: ((Int, Bool) -> Void)?
    var onTap: (() -> Void)?

    private var continuous: Bool { preferences.mode == .webtoon || preferences.mode == .continuousVertical }
    private var horizontal: Bool { preferences.mode == .leftToRight || preferences.mode == .rightToLeft }
    private var reversed: Bool { preferences.mode == .rightToLeft }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scroll.backgroundColor = .black
        scroll.delegate = self
        scroll.isDirectionalLockEnabled = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        addSubview(scroll)
        scroll.addSubview(canvasContent)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.numberOfTapsRequired = 1
        // Les gestes de zoom des cellules font échouer le simple tap.
        scroll.addGestureRecognizer(tap)
        continuousZoomTap.numberOfTapsRequired = 2
        continuousZoomTap.addTarget(self, action: #selector(zoomContinuous))
        scroll.addGestureRecognizer(continuousZoomTap)
        tap.require(toFail: continuousZoomTap)
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.memoryWarning() }
        }
    }
    required init?(coder: NSCoder) { return nil }
    deinit { if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) } }
    @objc private func tapped() { onTap?() }
    @objc private func zoomContinuous(_ gesture: UITapGestureRecognizer) {
        guard continuous else { return }
        if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true) }
        else {
            let point = gesture.location(in: canvasContent)
            scroll.zoom(to: CGRect(x: point.x - bounds.width / 4, y: point.y - bounds.height / 4,
                                  width: bounds.width / 2, height: bounds.height / 2), animated: true)
        }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { continuous ? canvasContent : nil }

    func configure(chapter: ChapterSnapshot, preferences: ReadingPreferences, split: Bool,
                   root: URL, generation: UUID, page: Int) {
        let rebuild = self.chapter?.id != chapter.id || self.preferences != preferences
            || self.split != split || self.generation != generation
        self.chapter = chapter; self.preferences = preferences; self.split = split; self.root = root
        self.generation = generation
        if rebuild {
            self.page = page
            lastSize = .zero
            setNeedsLayout()
        } else if self.page != page {
            self.page = page
            let index = ReaderLayout.unitIndex(for: page, units: units)
            if index != visibleIndex() { seek(index) }
        }
    }

    func dispose() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        for cell in cells.values { cell.removeFromSuperview() }
        cells.removeAll()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let chapter else { return }
        scroll.frame = bounds
        guard lastSize != bounds.size else { return }
        lastSize = bounds.size
        scroll.setZoomScale(1, animated: false)
        dispose()
        lastReported = nil
        units = ReaderLayout.units(pages: chapter.pages, preferences: preferences,
                                   landscape: bounds.width > bounds.height, splitPanoramas: split)
        frames = Array(repeating: .zero, count: units.count)
        var offset: CGFloat = 0
        for index in units.indices {
            let physical = reversed ? units.count - 1 - index : index
            if horizontal {
                frames[index] = CGRect(x: CGFloat(physical) * bounds.width, y: 0, width: bounds.width, height: bounds.height)
            } else {
                var height = bounds.height
                if continuous, let part = units[index].parts.first,
                   let snapshot = chapter.pages.first(where: { $0.index == part.page }) {
                    height = bounds.width * CGFloat(snapshot.height ?? 1) / CGFloat(max(1, snapshot.width ?? 1))
                    height = min(max(height, 1), 100_000)
                }
                frames[index] = CGRect(x: 0, y: offset, width: bounds.width, height: height)
                offset += height + (continuous && preferences.mode == .continuousVertical ? 12 : 0)
            }
        }
        scroll.isPagingEnabled = !continuous
        continuousZoomTap.isEnabled = continuous
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = continuous ? 4 : 1
        scroll.contentSize = horizontal
            ? CGSize(width: bounds.width * CGFloat(units.count), height: bounds.height)
            : CGSize(width: bounds.width, height: offset)
        canvasContent.frame = CGRect(origin: .zero, size: scroll.contentSize)
        seek(ReaderLayout.unitIndex(for: page, units: units))
        updateVisible()
    }

    private func seek(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        let frame = frames[index]
        let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: frame.minX * scroll.zoomScale,
                                       y: min(frame.minY * scroll.zoomScale, maximum)), animated: false)
        updateVisible()
    }

    private func visibleIndex() -> Int? {
        let viewport = visibleRect
        // Le centre du viewport définit la page active, y compris les images plus hautes que l’écran.
        return ReaderLayout.activeUnit(frames: frames, viewport: viewport)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisible() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { updateVisible() }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportVisible() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportVisible() }
    }

    private func updateVisible() {
        guard let selected = visibleIndex(), let chapter, let root else { return }
        let viewport = visibleRect
        let needed = Set(frames.indices.filter {
            frames[$0].intersects(viewport) || abs($0 - selected) <= 1
        })
        for index in Array(cells.keys) where !needed.contains(index) {
            tasks.removeValue(forKey: index)?.cancel()
            cells.removeValue(forKey: index)?.removeFromSuperview()
        }
        for index in needed where cells[index] == nil {
            let cell = ReaderZoomView(frame: frames[index], continuous: continuous)
            cells[index] = cell
            canvasContent.addSubview(cell)
            if let single = scroll.gestureRecognizers?.compactMap({ $0 as? UITapGestureRecognizer }).first {
                single.require(toFail: cell.doubleTap)
            }

            cell.retry = { [weak self] in self?.load(index, chapter: chapter, root: root) }
            load(index, chapter: chapter, root: root)
        }
        reportVisible()
    }

    private var visibleRect: CGRect {
        let scale = max(1, scroll.zoomScale)
        return CGRect(x: scroll.contentOffset.x / scale, y: scroll.contentOffset.y / scale,
                      width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
    }

    private func load(_ index: Int, chapter: ChapterSnapshot, root: URL) {
        tasks[index]?.cancel()
        cells[index]?.showLoading()
        let unit = units[index]
        let generation = self.generation
        tasks[index] = Task { [weak self] in
            do {
                var images: [UIImage] = []
                for part in unit.parts {
                    let file = try ReaderFiles.image(chapter: chapter, page: part.page)
                    let decoded = try await ReaderImages.shared.load(root: root, file: file, generation: generation)
                    try Task.checkCancellation()
                    var image = decoded.image
                    if let half = part.half, let cg = image.cgImage {
                        let leftWidth = cg.width / 2
                        let width = half == 0 ? leftWidth : cg.width - leftWidth
                        guard let crop = cg.cropping(to: CGRect(x: half == 0 ? 0 : leftWidth, y: 0,
                                                               width: width, height: cg.height)) else {
                            throw DomainError.invalidValue("panorama")
                        }
                        image = UIImage(cgImage: crop)
                    }
                    images.append(image)
                }
                guard let self, !Task.isCancelled else { return }
                self.cells[index]?.display(images)
                self.reportVisible()
            } catch {
                guard !Task.isCancelled else { return }
                self?.cells[index]?.showError("Page illisible : \(error.localizedDescription)")
            }
        }
    }

    private func reportVisible() {
        guard let index = visibleIndex(), cells[index]?.decoded == true,
              frames.indices.contains(index), !scroll.isDragging, !scroll.isDecelerating else { return }
        // Une paire n’est validée qu’après le décodage de ses deux images.
        guard lastReported != index else { return }
        lastReported = index
        let logical = units[index].logicalPages.max() ?? 0
        page = logical
        let lastOccurrence = ReaderLayout.completesLogicalPage(unit: index, units: units)
        onVisible?(logical, lastOccurrence)
    }

    func memoryWarning() {
        let active = visibleIndex()
        for index in Array(cells.keys) where index != active {
            tasks.removeValue(forKey: index)?.cancel()
            cells.removeValue(forKey: index)?.removeFromSuperview()
        }
    }
}

@MainActor
private final class ReaderZoomView: UIScrollView, UIScrollViewDelegate {
    private let content = UIView()
    private var images: [UIImageView] = []
    private let message = UILabel()
    private let retryButton = UIButton(type: .system)
    private let continuous: Bool
    private(set) var decoded = false
    var retry: (() -> Void)?
    let doubleTap = UITapGestureRecognizer()

    init(frame: CGRect, continuous: Bool) {
        self.continuous = continuous
        super.init(frame: frame)
        backgroundColor = .black
        content.backgroundColor = .black
        addSubview(content)
        delegate = self
        minimumZoomScale = 1; maximumZoomScale = 4
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        isScrollEnabled = !continuous
        doubleTap.numberOfTapsRequired = 2
        doubleTap.isEnabled = !continuous
        doubleTap.addTarget(self, action: #selector(handleDoubleTapZoom(_:)))
        addGestureRecognizer(doubleTap)
        message.textColor = .white; message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        retryButton.setTitle("Réessayer", for: .normal)
        retryButton.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)
        addSubview(message); addSubview(retryButton)
    }
    required init?(coder: NSCoder) { return nil }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { continuous ? nil : content }
    @objc private func retryLoad() { retry?() }
    @objc private func handleDoubleTapZoom(_ gesture: UITapGestureRecognizer) {
        guard !continuous, decoded else { return }
        if zoomScale > 1 { setZoomScale(1, animated: true) }
        else {
            let point = gesture.location(in: content)
            zoom(to: CGRect(x: point.x - bounds.width / 4, y: point.y - bounds.height / 4,
                            width: bounds.width / 2, height: bounds.height / 2), animated: true)
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 {
            content.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
            for (index, image) in images.enumerated() {
                let width = bounds.width / CGFloat(max(1, images.count))
                image.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
            }
        }
        message.frame = CGRect(x: 16, y: 16, width: max(0, bounds.width - 32), height: min(160, bounds.height / 2))
        retryButton.frame = CGRect(x: 16, y: message.frame.maxY, width: max(0, bounds.width - 32), height: 50)
    }
    func showLoading() { decoded = false; message.text = "Chargement…"; message.isHidden = false; retryButton.isHidden = true }
    func showError(_ text: String) { decoded = false; message.text = text; message.isHidden = false; retryButton.isHidden = false }
    func display(_ values: [UIImage]) {
        images.forEach { $0.removeFromSuperview() }
        images = values.map {
            let view = UIImageView(image: $0)
            view.contentMode = .scaleAspectFit
            content.addSubview(view)
            return view
        }
        decoded = true; message.isHidden = true; retryButton.isHidden = true
        setNeedsLayout()
        layoutIfNeeded()
        accessibilityLabel = "Page du chapitre"
    }
}
