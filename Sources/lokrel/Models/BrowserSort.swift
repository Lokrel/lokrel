import Foundation

enum BrowserSort: String, CaseIterable, Identifiable {
    case filename, created, modified, size, tags
    var id: String { rawValue }
    var title: String {
        switch self {
        case .filename: return L10n.text("File Name")
        case .created: return L10n.text("Date Created")
        case .modified: return L10n.text("Date Modified")
        case .size: return L10n.text("Size")
        case .tags: return L10n.text("Tags")
        }
    }

    func sorted(_ projects: [ModelProject], ascending: Bool, tagOrder: [String]) -> [ModelProject] {
        let ranks = Dictionary(uniqueKeysWithValues: tagOrder.enumerated().map { ($0.element, $0.offset) })
        func rank(_ project: ModelProject) -> Int? { project.tags.compactMap { ranks[$0] }.min() }
        func date(_ project: ModelProject) -> Date? { self == .created ? project.primaryFile?.createdAt : project.modifiedAt }
        return projects.sorted { left, right in
            var order: ComparisonResult = .orderedSame
            switch self {
            case .filename: break
            case .created, .modified:
                let a = date(left), b = date(right)
                if (a == nil) != (b == nil) { return a != nil }
                if let a, let b { order = a.compare(b) }
            case .size:
                if left.size != right.size { order = left.size < right.size ? .orderedAscending : .orderedDescending }
            case .tags:
                let a = rank(left), b = rank(right)
                if (a == nil) != (b == nil) { return a != nil }
                if let a, let b, a != b { order = a < b ? .orderedAscending : .orderedDescending }
            }
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            let nameOrder = (left.primaryFile?.filename ?? left.name).localizedStandardCompare(right.primaryFile?.filename ?? right.name)
            if nameOrder != .orderedSame {
                return self == .filename && !ascending ? nameOrder == .orderedDescending : nameOrder == .orderedAscending
            }
            if left.directoryPath != right.directoryPath { return left.directoryPath < right.directoryPath }
            return left.id < right.id
        }
    }
}
