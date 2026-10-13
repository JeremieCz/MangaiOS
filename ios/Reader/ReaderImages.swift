import Foundation
import ImageIO
import UIKit
import SwiftUI

final class DecodedPage: @unchecked Sendable {
    let image: UIImage
    let cost: Int
    init(_ image: CGImage) {
        self.image = UIImage(cgImage: image)
        cost = image.bytesPerRow * image.height
    }
}

actor ReaderImages {
    static let shared = ReaderImages()
    private var cache: [URL: DecodedPage] = [:]
    private var order: [URL] = []
    private var cost = 0
    var cachedByteCount: Int { cost }

    func clear() {
        cache.removeAll()
        order.removeAll()
        cost = 0
    }

    func load(root: URL, file: FileSnapshot, maximumDimension: Int = ReaderImageBudget.maximumDimension) throws -> DecodedPage {
        guard file.kind == .image else { throw DomainError.invalidValue("image") }
        let url = try ReaderFiles.resolve(root: root, path: file.path)
        // Les miniatures ne polluent pas le cache du lecteur.
        if maximumDimension == ReaderImageBudget.maximumDimension, let hit = cache[url] {
            order.removeAll { $0 == url }; order.append(url)
            return hit
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, min(maximumDimension, ReaderImageBudget.maximumDimension)),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw DomainError.invalidValue("image illisible") }
        let decoded = DecodedPage(image)
        if maximumDimension == ReaderImageBudget.maximumDimension, decoded.cost <= ReaderImageBudget.bytes {
            while cost + decoded.cost > ReaderImageBudget.bytes, let first = order.first {
                order.removeFirst()
                cost -= cache.removeValue(forKey: first)?.cost ?? 0
            }
            cache[url] = decoded; order.append(url); cost += decoded.cost
        }
        return decoded
    }
}

struct CoverThumbnail: View {
    let series: SeriesSnapshot
    let root: URL
    @State private var image: UIImage?

    private var file: FileSnapshot? {
        if let cover = series.cover, cover.kind == .image { return cover }
        guard let chapter = LibrarySelection.orderedChapters(series).first,
              let page = chapter.pages.first else { return nil }
        return try? ReaderFiles.image(chapter: chapter, page: page.index)
    }

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .frame(width: 56, height: 80)
        .accessibilityHidden(true)
        .task(id: file?.id) {
            image = nil
            guard let file else { return }
            if let value = try? await ReaderImages.shared.load(root: root, file: file, maximumDimension: 256),
               !Task.isCancelled { image = value.image }
        }
    }
}
