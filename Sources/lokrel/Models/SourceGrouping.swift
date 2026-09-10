import Foundation
import CryptoKit

struct SourceGroup: Identifiable {
    let id: String
    let projects: [ModelProject]
    var name: String { projects[0].displayName }
    var isScattered: Bool { Set(projects.map(\.directoryPath)).count > 1 }
    var fingerprint: String {
        let value = id + projects.flatMap { $0.files.map(\.path) }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum SourceGrouping {
    static func key(_ value: String) -> String? {
        if value.range(of: #"^makerworld-cn-model:cn[0-9a-f]+$"#, options: .regularExpression) != nil { return value }
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        if let page = ModelSourceResolver.modelPage(value) { return page }
        if host.contains("makerworld") || host.contains("bambulab") { return nil }
        if parts.queryItems?.contains(where: { ["signature", "expires", "token", "x-amz-signature", "ossaccesskeyid"].contains($0.name.lowercased()) }) == true { return nil }
        guard !parts.path.isEmpty, parts.path != "/" else { return nil }
        parts.host = host
        parts.scheme = parts.scheme?.lowercased()
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.filter {
            !$0.name.lowercased().hasPrefix("utm_") && !["fbclid", "gclid"].contains($0.name.lowercased())
        }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.string
    }

    static func groups(_ projects: [ModelProject]) -> [SourceGroup] {
        var members: [String: [ModelProject]] = [:]
        var order: [String] = []
        for project in projects {
            guard let key = key(project.groupingSource) else { continue }
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(project)
        }
        return order.compactMap { key in
            guard let projects = members[key], projects.count > 1 else { return nil }
            return SourceGroup(id: key, projects: projects)
        }
    }
}

struct BrowserItem: Identifiable {
    let project: ModelProject
    var group: SourceGroup?
    var isGroupMember = false
    var id: String { project.id }
}

enum BrowserNavigation {
    static func destination(current: Int?, count: Int, columns: Int, key: UInt16) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        let offset: Int
        switch key {
        case 123: offset = -1
        case 124: offset = 1
        case 125:
            guard current / max(1, columns) < (count - 1) / max(1, columns) else { return current }
            offset = max(1, columns)
        case 126:
            guard current >= max(1, columns) else { return current }
            offset = -max(1, columns)
        default: return nil
        }
        return min(count - 1, max(0, current + offset))
    }
}
