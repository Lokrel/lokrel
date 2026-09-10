import Foundation
import CoreServices
import Darwin

@MainActor
final class LibraryChangeMonitor {
    private var stream: FSEventStreamRef?
    private var timer: Timer?
    private var pending: Task<Void, Never>?
    private var paths: Set<String> = []
    private var needsFullCheck = false
    private var ticks = 0
    private let root: URL
    private let eventRootPath: String
    private let visibleFolder: () -> String?
    private let refresh: ([String]?) -> Void

    init(root: URL, visibleFolder: @escaping () -> String?, refresh: @escaping ([String]?) -> Void) {
        self.root = root
        if let resolved = realpath(root.path, nil) {
            eventRootPath = String(cString: resolved)
            free(resolved)
        } else { eventRootPath = root.path }
        self.visibleFolder = visibleFolder
        self.refresh = refresh
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<LibraryChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
            let values = Array(UnsafeBufferPointer(start: flags, count: count))
            Task { @MainActor in monitor.receive(paths, flags: values) }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.ticks += 1
                // A full metadata sweep catches missed notifications, including remote SMB changes.
                if self.ticks % 10 == 0 { self.refresh(nil) }
                else if let path = self.visibleFolder() { self.refresh([path]) }

            }
        }
    }

    deinit {
        pending?.cancel()
        timer?.invalidate()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        timer?.invalidate()
        timer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

#if DEBUG
    func disableNotificationsForValidation() {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }
#endif

    private func receive(_ eventPaths: [String], flags: [FSEventStreamEventFlags]) {
        for (eventPath, flag) in zip(eventPaths, flags) {
            let normalized = URL(fileURLWithPath: eventPath).standardizedFileURL.path
            let path = normalized == eventRootPath || normalized.hasPrefix(eventRootPath + "/")
                ? root.path + normalized.dropFirst(eventRootPath.count) : normalized
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 {
                needsFullCheck = true
            }
            let url = URL(fileURLWithPath: path)
            let relative = path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : ""
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let directory = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            if !directory && !LibraryInventory.extensions.contains(url.pathExtension.lowercased()) { continue }
            paths.insert(directory ? path : url.deletingLastPathComponent().path)
        }
        guard needsFullCheck || !paths.isEmpty else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let scopes = self.needsFullCheck ? nil : LibraryInventory.scopes(Array(self.paths), root: self.root.path)
            self.paths.removeAll()
            self.needsFullCheck = false
            self.refresh(scopes)
        }
    }
}

enum LibraryInventory {
    static let extensions: Set<String> = ["3mf", "stl", "step", "stp", "obj", "f3d", "iges", "igs", "jpg", "jpeg", "png", "webp", "pdf", "md", "txt"]

    struct Stamp: Equatable, Sendable {
        let size: Int
        let modified: Date?
        let attributesModified: Date?
        let created: Date?
        let directory: Bool
    }

    static func scopes(_ paths: [String], root: String) -> [String] {
        var result: [String] = []
        for path in Set(paths).sorted(by: { $0.count < $1.count }) {
            guard path == root || path.hasPrefix(root + "/") else { continue }
            if !result.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { result.append(path) }
        }
        return result
    }

    static func read(root: URL, scopes: [String]?) throws -> [String: Stamp] {
        let fm = FileManager.default
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              fm.isReadableFile(atPath: root.path) else { throw CocoaError(.fileReadNoPermission) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .attributeModificationDateKey, .creationDateKey]
        var result: [String: Stamp] = [:]
        var failure: Error?
        for path in scopes ?? [root.path] {
            guard fm.fileExists(atPath: path) else { continue }
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in failure = error; return false }) else { throw CocoaError(.fileReadNoPermission) }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isDirectory == true || (values.isRegularFile == true && extensions.contains(url.pathExtension.lowercased())) else { continue }
                result[url.standardizedFileURL.path] = Stamp(size: values.isDirectory == true ? 0 : values.fileSize ?? 0, modified: values.isDirectory == true ? nil : values.contentModificationDate, attributesModified: values.isDirectory == true ? nil : values.attributeModificationDate, created: values.creationDate, directory: values.isDirectory == true)
            }
        }
        if let failure { throw failure }
        return result
    }
}
