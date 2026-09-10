import Foundation

struct ScanProgress: Sendable {
    enum Stage: Sendable { case discovering, reading, saving }
    var stage: Stage = .discovering
    var completed = 0
    var total: Int?
    var filename = ""
}

struct ScannedFile: Hashable, Sendable {
    let path: String
    let filename: String
    let fileExtension: String
    let size: Int64
    let createdAt: Date?
    let modifiedAt: Date?
    func matches(_ other: ScannedFile) -> Bool {
        func milliseconds(_ date: Date?) -> Int64? { date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } }
        return path == other.path && filename == other.filename && fileExtension == other.fileExtension && size == other.size
            && milliseconds(createdAt) == milliseconds(other.createdAt) && milliseconds(modifiedAt) == milliseconds(other.modifiedAt)
    }

}

struct ScannedProject: Hashable, Sendable {
    let groupKey: String
    let name: String
    let directoryPath: String
    let createdAt: Date?
    let modifiedAt: Date?
    let size: Int64
    let files: [ScannedFile]
    var embeddedSourceURL: String = ""
    var sourceSignature: String = ""
    var sourceIdentity: String = ""
}

struct ScanResult: Sendable {
    let projects: [ScannedProject]
    let visitedFileCount: Int
    let duration: TimeInterval
    var directoryPaths: [String] = []
    var scopePaths: [String]? = nil
    var parsedModelCount = 0
    var deferredGroups: Set<String> = []
    var deferredPaths: Set<String> = []
}
