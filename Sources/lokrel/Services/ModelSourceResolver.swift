import Foundation
import Darwin

struct ModelSourceInfo: Sendable {
    var modelURL: String?
    var identity: String?
    var platform: String?
    var downloadURL: URL?
}

enum ModelSourceResolver {
    // Public pages and internal provenance IDs are distinct; download URLs stay transient.
    static func modelPage(_ value: String) -> String? {
        guard let parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased() else { return nil }
        let path = parts.path
        func capture(_ pattern: String) -> String? {
            guard let range = path.range(of: pattern, options: .regularExpression) else { return nil }
            return String(path[range])
        }
        if ["makerworld.com", "www.makerworld.com", "makerworld.com.cn", "www.makerworld.com.cn", "makerworld.cn", "www.makerworld.cn"].contains(host),
           let id = capture(#"(?<=/models/)[0-9]+(?=-|/|$)"#) {
            let china = host.hasSuffix(".cn")
            return "https://\(china ? "makerworld.com.cn/zh" : "makerworld.com/en")/models/\(id)"
        }
        if ["thingiverse.com", "www.thingiverse.com"].contains(host), let id = capture(#"(?<=/thing:)[0-9]+"#) {
            return "https://www.thingiverse.com/thing:\(id)"
        }
        if ["printables.com", "www.printables.com"].contains(host), let id = capture(#"(?<=/model/)[0-9]+"#) {
            return "https://www.printables.com/model/\(id)"
        }
        if host == "cults3d.com", let page = capture(#"/[a-z]{2}/3d-model/[^/]+/[^/]+"#) {
            return "https://cults3d.com\(page)"
        }
        if ["crealitycloud.com", "www.crealitycloud.com", "crealitycloud.cn", "www.crealitycloud.cn"].contains(host),
           let page = capture(#"/(?:[a-z]{2}/)?(?:model-detail|3d-model)/[^/]+"#) {
            return "https://\(host)\(page)"
        }
        return nil
    }

    static func embedded(_ metadata: ExtractedModelMetadata) -> String? {
        let explicit = metadata.entries.filter { entry in
            ["url", "source", "origin", "download"].contains { entry.name.localizedCaseInsensitiveContains($0) }
        }
        for entry in explicit {
            if let url = metadataURLs(in: entry.value).compactMap(modelPage).first { return url }
        }
        for name in ["DesignModelId", "MakerWorldModelId"] {
            if let id = metadata.value(named: name), let url = makerWorldModelURL(from: id) {
                return metadata.value(named: "DesignRegion") == "CN" ? url.replacingOccurrences(of: "makerworld.com/en", with: "makerworld.com.cn/zh") : url
            }
        }
        // Descriptions often link to other designs; only a single unambiguous model page is usable.
        let pages = Set(metadataURLs(in: metadata.description ?? "").compactMap(modelPage))
        return pages.count == 1 ? pages.first : nil
    }

    static func resolve(fileURL: URL, metadata: ExtractedModelMetadata? = nil, readmeURLs: [URL] = []) -> ModelSourceInfo {
        let origins = whereFroms(fileURL)
        var info = ModelSourceInfo(modelURL: metadata.flatMap(embedded))
        if let id = metadata?.value(named: "DesignModelId", "MakerWorldModelId") { info.identity = internalIdentity(id) }
        if info.modelURL == nil {
            info.modelURL = origins.compactMap(modelPage).first
        }
        if info.identity == nil {
            for value in origins {
                guard let url = URL(string: value), let host = url.host?.lowercased(),
                      host == "makerworld.bblmw.cn" || host.hasSuffix(".bambulab.com") || host.hasSuffix(".bambulab.cn") || host.hasSuffix(".makerworld.com.cn") else { continue }
                if let range = url.path.range(of: #"CN[0-9a-fA-F]+(?=/|_|-|\.|$)"#, options: .regularExpression) {
                    info.identity = internalIdentity(String(url.path[range]))
                    break
                }
            }
        }
        if info.modelURL == nil {
            for url in readmeURLs {
                guard let data = try? Data(contentsOf: url), data.count <= 1_000_000,
                      let text = String(data: data, encoding: .utf8) else { continue }
                // Thingiverse exports put the project's own link before the description and citations.
                let header = text.components(separatedBy: "Summary").first ?? text
                let pages = Set(metadataURLs(in: header).compactMap(modelPage))
                if pages.count == 1 { info.modelURL = pages.first; break }
            }
        }
        if info.identity != nil { info.platform = "MakerWorld" }
        for value in [info.modelURL].compactMap({ $0 }) + origins {
            guard let host = URL(string: value)?.host?.lowercased() else { continue }
            if host.contains("makerworld") || host.hasSuffix(".bambulab.com") || host.hasSuffix(".bambulab.cn") { info.platform = "MakerWorld" }
            else if host == "cults3d.com" || host.hasSuffix(".cults3d.com") { info.platform = "Cults3D" }
            else if host.contains("creality") { info.platform = "Creality Cloud" }
            else if host.contains("thingiverse") { info.platform = "Thingiverse" }
            else if host.contains("printables") { info.platform = "Printables" }
            if info.platform != nil { break }
        }
        if let first = origins.first, modelPage(first) == nil, let url = URL(string: first),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.path != "/", !url.path.isEmpty {
            info.downloadURL = url
        }
        return info
    }

    static func internalIdentity(_ value: String) -> String? {
        guard value.range(of: #"^CN[0-9a-fA-F]+$"#, options: .regularExpression) != nil else { return nil }
        return "makerworld-cn-model:" + value.lowercased()
    }

    static func whereFroms(_ url: URL) -> [String] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let count = getxattr(url.path, name, nil, 0, 0, 0)
        guard count > 0, count < 1_000_000 else { return [] }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, count, 0, 0) }
        guard read == count,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return values
    }
}
