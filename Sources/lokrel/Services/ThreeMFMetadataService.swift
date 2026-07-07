import Foundation
import ZIPFoundation

actor ThreeMFMetadataService {
    static let shared = ThreeMFMetadataService()

    private var cache: [String: ExtractedModelMetadata] = [:]

    func metadata(for project: ModelProject) async -> ExtractedModelMetadata? {
        guard let file = project.files.first(where: {
            $0.fileExtension.lowercased() == "3mf"
        }) else { return nil }

        let stamp = Int(file.modifiedAt?.timeIntervalSince1970 ?? 0)
        let cacheKey = "\(file.path)::\(stamp)::\(file.size)"
        if let cached = cache[cacheKey] { return cached }

        do {
            let metadata = try await Task.detached(priority: .utility) {
                try Self.extract(fileURL: file.url)
            }.value
            cache[cacheKey] = metadata
            return metadata
        } catch {
            return nil
        }
    }

    nonisolated static func extract(fileURL: URL) throws -> ExtractedModelMetadata {
        try extractMetadata(fileURL: fileURL)
    }
}

private func extractMetadata(fileURL: URL) throws -> ExtractedModelMetadata {
    let archive = try Archive(url: fileURL, accessMode: .read)
    let interestingEntries = archive.filter { entry in
        let path = entry.path.lowercased()
        return path == "3d/3dmodel.model"
            || path == "metadata/model_settings.config"
            || path.hasSuffix("/core.xml")
            || path == "docprops/core.xml"
    }

    var entries: [MetadataEntry] = []
    for entry in interestingEntries {
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let parserDelegate = MetadataXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        if parser.parse() {
            if entry.path.lowercased() == "metadata/model_settings.config" {
                entries.append(contentsOf: parserDelegate.entries.filter {
                    $0.name.caseInsensitiveCompare("source_file") == .orderedSame
                })
            } else {
                entries.append(contentsOf: parserDelegate.entries)
            }
        }
    }

    var seen: Set<MetadataEntry> = []
    let uniqueEntries = entries.filter { entry in
        guard !entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return seen.insert(entry).inserted
    }.sorted(by: metadataSort)
    return ExtractedModelMetadata(entries: uniqueEntries)
}

private final class MetadataXMLParserDelegate: NSObject, XMLParserDelegate {
    private static let corePropertyNames: Set<String> = [
        "dc:title", "dc:creator", "dc:description", "dc:subject",
        "cp:keywords", "cp:lastmodifiedby", "dcterms:created", "dcterms:modified"
    ]

    private(set) var entries: [MetadataEntry] = []
    private var activeName: String?
    private var activeValue = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let normalizedElement = (qName ?? elementName).lowercased()
        if normalizedElement.hasSuffix("metadata"),
           let name = attributeDict["name"] ?? attributeDict["key"] {
            if let value = attributeDict["value"] {
                append(name: name, value: value)
            } else {
                activeName = name
                activeValue = ""
            }
        } else if Self.corePropertyNames.contains(normalizedElement) {
            activeName = qName ?? elementName
            activeValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard activeName != nil else { return }
        activeValue += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let activeName else { return }
        let normalizedElement = (qName ?? elementName).lowercased()
        if normalizedElement.hasSuffix("metadata")
            || Self.corePropertyNames.contains(normalizedElement) {
            append(name: activeName, value: activeValue)
            self.activeName = nil
            activeValue = ""
        }
    }

    private func append(name: String, value: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = sanitizedMetadataText(value)
        guard !trimmedName.isEmpty, !trimmedValue.isEmpty else { return }
        entries.append(MetadataEntry(name: trimmedName, value: trimmedValue))
    }
}

private func metadataSort(_ lhs: MetadataEntry, _ rhs: MetadataEntry) -> Bool {
    let preferred = [
        "Title", "Designer", "dc:creator", "Description", "Copyright", "LicenseTerms",
        "License", "Application", "CreationDate", "ModificationDate", "Origin",
        "DesignerUserId", "DesignModelId", "MakerLabFileId", "source_file"
    ]
    let leftIndex = preferred.firstIndex(where: {
        $0.caseInsensitiveCompare(lhs.name) == .orderedSame
    }) ?? preferred.count
    let rightIndex = preferred.firstIndex(where: {
        $0.caseInsensitiveCompare(rhs.name) == .orderedSame
    }) ?? preferred.count
    if leftIndex != rightIndex { return leftIndex < rightIndex }
    if lhs.name.caseInsensitiveCompare(rhs.name) != .orderedSame {
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
}
