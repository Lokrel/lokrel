import Foundation

struct ScannedFile: Hashable, Sendable {
    let path: String
    let filename: String
    let fileExtension: String
    let size: Int64
    let createdAt: Date?
    let modifiedAt: Date?
}

struct ScannedProject: Hashable, Sendable {
    let groupKey: String
    let name: String
    let directoryPath: String
    let createdAt: Date?
    let modifiedAt: Date?
    let size: Int64
    let files: [ScannedFile]
}

struct ScanResult: Sendable {
    let projects: [ScannedProject]
    let visitedFileCount: Int
    let duration: TimeInterval
}
