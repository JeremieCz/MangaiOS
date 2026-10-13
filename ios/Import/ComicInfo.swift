import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct ComicMetadata: Codable, Equatable, Sendable {
    var series: SeriesMetadata
    var chapterTitle: String
    var number: Double?
    var publicationDate: String?
    var translators: [String] = []
    var categories: [String] = []
    var source: String?
    var warnings: [String] = []
}

enum ComicInfo {
    static func parse(_ data: Data, fallback: String, limit: Int = 1_024 * 1_024) throws -> ComicMetadata {
        guard data.count <= limit else { throw ImportFailure.rejected("ComicInfo trop volumineux") }
        // Accepter uniquement UTF-8 simplifie la détection des déclarations, sans ambiguïté UTF-16.
        guard let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
            throw ImportFailure.rejected("ComicInfo doit être UTF-8, sans DTD ni entité déclarée")
        }
        let delegate = ComicInfoDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.validRoot, delegate.depth == 0 else {
            throw ImportFailure.rejected("ComicInfo XML invalide")
        }
        let fields = delegate.fields
        func list(_ key: String) -> [String] {
            (fields[key] ?? "").split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        // Les noms locaux amont priment sur les anciens Status/Source, sauf s'ils sont vides.
        let upstreamStatus = fields["PublishingStatusTachiyomi"].flatMap { $0.isEmpty ? nil : $0 }
        let rawStatus = upstreamStatus ?? fields["Status"].flatMap { $0.isEmpty ? nil : $0 }
        let status: SeriesStatus
        if let upstreamStatus {
            switch upstreamStatus {
            case "Ongoing": status = .ongoing
            case "Completed", "Publishing finished": status = .completed
            case "Cancelled": status = .cancelled
            case "On hiatus": status = .hiatus
            // Le domaine iOS n'a pas de statut de licence.
            default: status = .unknown
            }
        } else {
            status = rawStatus.flatMap { SeriesStatus(rawValue: $0.lowercased()) } ?? .unknown
        }
        var result = ComicMetadata(
            series: SeriesMetadata(
                title: fields["Series"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback,
                authors: list("Writer"),
                artists: unique(list("Penciller") + list("Inker") + list("Colorist")
                    + list("Letterer") + list("CoverArtist")),
                summary: fields["Summary"] ?? "", genres: unique(list("Genre") + list("Tags")),
                status: status
            ),
            chapterTitle: fields["Title"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        )
        if let rawStatus, status == .unknown, rawStatus.lowercased() != "unknown" {
            result.warnings.append("Statut ComicInfo non représentable ou inconnu : conservé dans le XML uniquement.")
        }
        if let raw = fields["Number"], !raw.isEmpty {
            if let number = Double(raw), number.isFinite, number >= 0 { result.number = number }
            else { result.warnings.append("Numéro ComicInfo invalide : conservé dans le XML uniquement.") }
        }
        result.translators = list("Translator") + list("Scanlator")
        result.categories = list("Categories")
        result.source = fields["SourceMihon"].flatMap { $0.isEmpty ? nil : $0 } ?? fields["Source"]
        if fields["Year"] != nil || fields["Month"] != nil || fields["Day"] != nil {
            if let year = fields["Year"].flatMap(Int.init), (1...9999).contains(year),
               let month = Int(fields["Month"] ?? "1"), let day = Int(fields["Day"] ?? "1"),
               (1...12).contains(month), (1...31).contains(day) {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let components = DateComponents(year: year, month: month, day: day)
                if let date = calendar.date(from: components),
                   calendar.dateComponents([.year, .month, .day], from: date) == components {
                    result.publicationDate = String(format: "%04d-%02d-%02d", year, month, day)
                }
            }
            if result.publicationDate == nil {
                result.warnings.append("Date ComicInfo invalide : conservée dans le XML uniquement.")
            }
        }
        return result
    }
}

private final class ComicInfoDelegate: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]
    var depth = 0
    var validRoot = false
    private var field = ""
    private var text = ""
    private var elements = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1
        elements += 1
        if depth == 1 { validRoot = elementName == "ComicInfo" }
        if depth > 16 || elements > 2_048 { parser.abortParsing() }
        if depth == 2 { field = elementName; text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depth >= 2 { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8), depth >= 2 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if depth == 2 { fields[field] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        depth -= 1
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        parser.abortParsing()
        return nil
    }
}
