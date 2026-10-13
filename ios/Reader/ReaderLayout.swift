import Foundation

struct ReaderPart: Equatable {
    let page: Int
    /// nil : image entière ; 0/1 : moitié gauche/droite.
    let half: Int?
}

struct ReaderUnit: Equatable {
    let parts: [ReaderPart]
    var logicalPages: [Int] { Array(Set(parts.map(\.page))).sorted() }
}

enum ReaderLayout {
    static func units(pages: [PageSnapshot], preferences: ReadingPreferences,
                      landscape: Bool, splitPanoramas: Bool) -> [ReaderUnit] {
        let continuous = preferences.mode == .webtoon || preferences.mode == .continuousVertical
        let paired = !continuous && preferences.doublePages != .disabled
            && (preferences.doublePages == .enabled || landscape)
        var result: [ReaderUnit] = []
        var pending: [ReaderPart] = []
        func flush() {
            if !pending.isEmpty { result.append(ReaderUnit(parts: pending)); pending = [] }
        }
        for page in pages.sorted(by: { $0.index < $1.index }) {
            let wide = (page.width ?? 0) > (page.height ?? Int.max)
            if splitPanoramas && wide && !continuous {
                flush()
                let halves = preferences.mode == .rightToLeft ? [1, 0] : [0, 1]
                for half in halves { result.append(ReaderUnit(parts: [ReaderPart(page: page.index, half: half)])) }
            } else if !paired || wide || (preferences.isolateCover && page.index == 0) {
                flush()
                result.append(ReaderUnit(parts: [ReaderPart(page: page.index, half: nil)]))
            } else {
                pending.append(ReaderPart(page: page.index, half: nil))
                if pending.count == 2 {
                    if preferences.mode == .rightToLeft { pending.reverse() }
                    flush()
                }
            }
        }
        flush()
        return result
    }

    static func unitIndex(for page: Int, units: [ReaderUnit]) -> Int {
        units.firstIndex { $0.logicalPages.contains(page) } ?? 0
    }

    static func activeUnit(frames: [CGRect], viewport: CGRect) -> Int? {
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        if let contained = frames.indices.first(where: { frames[$0].contains(center) }) { return contained }
        return frames.indices.filter { frames[$0].intersects(viewport) }.min {
            abs(frames[$0].midY - viewport.midY) + abs(frames[$0].midX - viewport.midX)
                < abs(frames[$1].midY - viewport.midY) + abs(frames[$1].midX - viewport.midX)
        }
    }

    static func completesLogicalPage(unit: Int, units: [ReaderUnit]) -> Bool {
        guard units.indices.contains(unit), let page = units[unit].logicalPages.max() else { return false }
        return units.lastIndex { $0.logicalPages.contains(page) } == unit
    }
}

struct ReaderProgressGate {
    private(set) var page: Int?
    private var started: Date?
    private var changed = false

    mutating func visible(_ page: Int, at date: Date) {
        self.page = page
        if started == nil { started = date }
        changed = true
    }

    mutating func pause(at date: Date) -> (page: Int, duration: TimeInterval)? {
        guard let page, let started else { return nil }
        self.started = nil
        changed = false
        return (page, max(0, date.timeIntervalSince(started)))
    }

    mutating func checkpoint(at date: Date) -> (page: Int, duration: TimeInterval)? {
        guard changed, let value = pause(at: date) else { return nil }
        started = date
        return value
    }
}

enum ReaderFiles {
    static func resolve(root: URL, path: RelativePath) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = root
        for component in path.value.split(separator: "/") {
            candidate.appendPathComponent(String(component))
            let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw DomainError.invalidPath }
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else { throw DomainError.invalidPath }
        return resolved
    }

    static func image(chapter: ChapterSnapshot, page: Int) throws -> FileSnapshot {
        guard let entry = chapter.pages.first(where: { $0.index == page }), entry.entryIndex == nil,
              let file = chapter.files.first(where: { $0.id == entry.fileID }), file.kind == .image else {
            throw DomainError.invalidValue("page locale non extraite")
        }
        return file
    }
}

enum ReaderImageBudget {
    static let bytes = 64 * 1024 * 1024
    static let maximumDimension = 4096
    static func cost(width: Int, height: Int) -> Int {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return overflow || byteOverflow || width < 0 || height < 0 ? Int.max : bytes
    }
}
