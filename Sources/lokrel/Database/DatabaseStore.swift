import Foundation
import GRDB

final class DatabaseStore: @unchecked Sendable {
    private let databaseQueue: DatabaseQueue

    init(path: String? = nil) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        if let path {
            databaseQueue = try DatabaseQueue(path: path, configuration: configuration)
        } else {
            let folder = try Self.applicationSupportFolder()
            databaseQueue = try DatabaseQueue(
                path: folder.appendingPathComponent("lokrel.sqlite").path,
                configuration: configuration
            )
        }
        try migrate()
    }

    func mostRecentLibrary() throws -> LibraryLocation? {
        try databaseQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, rootPath, name, lastScanAt
                FROM library
                WHERE removed = 0
                ORDER BY COALESCE(lastOpenedAt, lastScanAt, createdAt) DESC
                LIMIT 1
                """) else { return nil }
            return library(from: row)
        }
    }

    func libraries() throws -> [LibraryLocation] {
        try databaseQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, rootPath, name, lastScanAt FROM library WHERE removed = 0 ORDER BY COALESCE(lastOpenedAt, lastScanAt, createdAt) DESC")
                .map { library(from: $0) }
        }
    }

    func restoreLibrary(rootURL: URL) throws -> LibraryLocation? {
        let path = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        return try databaseQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id, rootPath, name, lastScanAt FROM library WHERE rootPath = ?", arguments: [path]) else { return nil }
            try db.execute(sql: "UPDATE library SET removed = 0, lastOpenedAt = ? WHERE rootPath = ?", arguments: [Date(), path])
            return library(from: row)
        }
    }

    func removeLibrary(id: Int64) throws {
        try databaseQueue.write { db in
            try db.execute(sql: "UPDATE library SET removed = 1 WHERE id = ?", arguments: [id])
        }
    }

    @discardableResult
    func applyScan(_ result: ScanResult, rootURL: URL, progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> LibraryLocation {
        let rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        return try databaseQueue.write { db in
            let now = Date()
            try db.execute(sql: """
                INSERT INTO library (rootPath, name, createdAt)
                VALUES (?, ?, ?)
                ON CONFLICT(rootPath) DO UPDATE SET name = excluded.name, removed = 0
                """, arguments: [rootURL.path, rootURL.lastPathComponent, now])

            guard let libraryID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM library WHERE rootPath = ?",
                arguments: [rootURL.path]
            ) else {
                throw DatabaseError(message: L10n.text("Could not create library"))
            }

            let existingRows = try Row.fetchAll(db, sql: "SELECT * FROM modelProject WHERE libraryID = ?", arguments: [libraryID])
            let existingByGroup = Dictionary(uniqueKeysWithValues: existingRows.map { (($0["groupKey"] as String), $0) })
            let fileRows = try Row.fetchAll(db, sql: "SELECT f.* FROM modelFile f JOIN modelProject p ON p.id = f.projectID WHERE p.libraryID = ?", arguments: [libraryID])
            let filesByProject = Dictionary(grouping: fileRows) { $0["projectID"] as String }
            var seenIDs: Set<String> = []

            var lastProgress = Date.distantPast
            for (index, scannedProject) in result.projects.enumerated() {
                if Date().timeIntervalSince(lastProgress) >= 0.1 || index == result.projects.count - 1 {
                    progress(ScanProgress(stage: .saving, completed: index, total: result.projects.count, filename: scannedProject.name))
                    lastProgress = Date()
                }
                let previous = existingByGroup[scannedProject.groupKey]
                let projectID = (previous?["id"] as String?) ?? UUID().uuidString
                seenIDs.insert(projectID)
                let oldFiles = filesByProject[projectID] ?? []
                let currentByPath = Dictionary(uniqueKeysWithValues: scannedProject.files.map { ($0.path, $0) })
                let unchangedFiles = oldFiles.count == scannedProject.files.count && oldFiles.allSatisfy { row in
                    let file = ScannedFile(path: row["path"], filename: row["filename"], fileExtension: row["extension"], size: row["size"], createdAt: row["createdAt"], modifiedAt: row["modifiedAt"])
                    return currentByPath[file.path].map { file.matches($0) } == true
                }
                if let previous, (previous["missing"] as Bool) == false, unchangedFiles,
                   (previous["name"] as String) == scannedProject.name,
                   (previous["directoryPath"] as String) == scannedProject.directoryPath,
                   (previous["embeddedSourceURL"] as String?) == scannedProject.embeddedSourceURL,
                   (previous["sourceSignature"] as String) == scannedProject.sourceSignature,
                   (previous["sourceIdentity"] as String) == scannedProject.sourceIdentity { continue }
                let currentPaths = Set(scannedProject.files.map(\.path))
                for old in oldFiles where !currentPaths.contains(old["path"] as String) {
                    try db.execute(sql: "DELETE FROM modelFile WHERE id = ?", arguments: [old["id"] as Int64])
                }

                try db.execute(sql: """
                    INSERT INTO modelProject (
                        id, libraryID, groupKey, name, directoryPath,
                        createdAt, modifiedAt, importedAt, size, missing, embeddedSourceURL, sourceSignature, sourceIdentity
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        groupKey = excluded.groupKey,
                        name = excluded.name,
                        directoryPath = excluded.directoryPath,
                        createdAt = excluded.createdAt,
                        modifiedAt = excluded.modifiedAt,
                        size = excluded.size,
                        embeddedSourceURL = excluded.embeddedSourceURL,
                        sourceSignature = excluded.sourceSignature,
                        sourceIdentity = excluded.sourceIdentity,
                        thumbnailPath = CASE
                            WHEN modelProject.modifiedAt IS excluded.modifiedAt AND modelProject.size = excluded.size
                            THEN modelProject.thumbnailPath
                            ELSE NULL
                        END,
                        missing = 0
                    """, arguments: [
                        projectID,
                        libraryID,
                        scannedProject.groupKey,
                        scannedProject.name,
                        scannedProject.directoryPath,
                        scannedProject.createdAt,
                        scannedProject.modifiedAt,
                        now,
                        scannedProject.size,
                        scannedProject.embeddedSourceURL,
                        scannedProject.sourceSignature,
                        scannedProject.sourceIdentity
                    ])

                for file in scannedProject.files {
                    try db.execute(sql: """
                        INSERT INTO modelFile (
                            projectID, path, filename, extension, size, createdAt, modifiedAt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(projectID, path) DO UPDATE SET filename = excluded.filename,
                            extension = excluded.extension, size = excluded.size,
                            createdAt = excluded.createdAt, modifiedAt = excluded.modifiedAt
                        """, arguments: [
                            projectID,
                            file.path,
                            file.filename,
                            file.fileExtension,
                            file.size,
                            file.createdAt,
                            file.modifiedAt
                        ])
                }
            }

            for row in existingRows where !seenIDs.contains(row["id"] as String) && !(row["missing"] as Bool) && !result.deferredGroups.contains(row["groupKey"] as String) {
                let path: String = row["directoryPath"]
                guard result.scopePaths == nil || result.scopePaths!.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                try db.execute(sql: "UPDATE modelProject SET missing = 1 WHERE id = ?", arguments: [row["id"] as String])
            }

            try db.execute(
                sql: "UPDATE library SET lastScanAt = ?, lastOpenedAt = ? WHERE id = ?",
                arguments: [now, now, libraryID]
            )
            return LibraryLocation(
                id: libraryID,
                rootPath: rootURL.path,
                name: rootURL.lastPathComponent,
                lastScanAt: now
            )
        }
    }

    func projects(rootURL: URL) throws -> [ModelProject] {
        let path = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let libraryID = try databaseQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM library WHERE rootPath = ?", arguments: [path])
        }
        guard let libraryID else { return [] }
        return try projects(libraryID: libraryID, includeMissing: true)
    }

    func projects(libraryID: Int64, includeMissing: Bool = false) throws -> [ModelProject] {
        try databaseQueue.read { db in
            let projectRows = try Row.fetchAll(db, sql: """
                SELECT id, name, directoryPath, createdAt, modifiedAt, importedAt, size,
                       favorite, note, customName, author, sourceURL, license,
                       modelDescription, coverOverridePath, thumbnailPath, embeddedSourceURL, sourceSignature, sourceIdentity
                FROM modelProject
                WHERE libraryID = ? AND (missing = 0 OR ?)
                ORDER BY COALESCE(NULLIF(customName, ''), name) COLLATE NOCASE
                """, arguments: [libraryID, includeMissing])

            let fileRows = try Row.fetchAll(db, sql: """
                SELECT f.id, f.projectID, f.path, f.filename, f.extension,
                       f.size, f.createdAt, f.modifiedAt
                FROM modelFile f
                JOIN modelProject p ON p.id = f.projectID
                WHERE p.libraryID = ? AND (p.missing = 0 OR ?)
                ORDER BY f.projectID, f.filename COLLATE NOCASE
                """, arguments: [libraryID, includeMissing])

            let tagRows = try Row.fetchAll(db, sql: """
                SELECT mt.projectID, t.name
                FROM modelTag mt
                JOIN tag t ON t.id = mt.tagID
                JOIN modelProject p ON p.id = mt.projectID
                WHERE p.libraryID = ? AND p.missing = 0
                ORDER BY t.sortOrder, t.id
                """, arguments: [libraryID])

            var filesByProject: [String: [ModelFile]] = [:]
            for row in fileRows {
                let projectID: String = row["projectID"]
                filesByProject[projectID, default: []].append(ModelFile(
                    id: row["id"],
                    path: row["path"],
                    filename: row["filename"],
                    fileExtension: row["extension"],
                    size: row["size"],
                    createdAt: row["createdAt"],
                    modifiedAt: row["modifiedAt"]
                ))
            }

            var tagsByProject: [String: [String]] = [:]
            for row in tagRows {
                let projectID: String = row["projectID"]
                let tagName: String = row["name"]
                tagsByProject[projectID, default: []].append(tagName)
            }

            return projectRows.map { row in
                let id: String = row["id"]
                return ModelProject(
                    id: id,
                    name: row["name"],
                    directoryPath: row["directoryPath"],
                    createdAt: row["createdAt"],
                    modifiedAt: row["modifiedAt"],
                    importedAt: row["importedAt"],
                    size: row["size"],
                    favorite: row["favorite"],
                    note: row["note"],
                    customName: row["customName"],
                    author: row["author"],
                    sourceURL: row["sourceURL"],
                    license: row["license"],
                    modelDescription: row["modelDescription"],
                    coverOverridePath: row["coverOverridePath"],
                    thumbnailPath: row["thumbnailPath"],
                    files: filesByProject[id] ?? [],
                    tags: tagsByProject[id] ?? [],
                    embeddedSourceURL: row["embeddedSourceURL"],
                    sourceSignature: row["sourceSignature"],
                    sourceIdentity: row["sourceIdentity"]
                )
            }
        }
    }

    func allTags(libraryID _: Int64) throws -> [String] {
        try databaseQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name
                FROM tag
                ORDER BY sortOrder, id
                """)
        }
    }

    func setFavorite(_ favorite: Bool, projectID: String) throws {
        try updateProject(
            sql: "UPDATE modelProject SET favorite = ? WHERE id = ?",
            arguments: [favorite, projectID]
        )
    }

    func setNote(_ note: String, projectID: String) throws {
        try updateProject(
            sql: "UPDATE modelProject SET note = ? WHERE id = ?",
            arguments: [note, projectID]
        )
    }

    func setEditableDetails(_ details: EditableModelDetails, projectID: String) throws {
        let customName = details.customName.trimmingCharacters(in: .whitespacesAndNewlines)
        try updateProject(sql: """
            UPDATE modelProject
            SET customName = ?, author = ?, sourceURL = ?, license = ?, modelDescription = ?
            WHERE id = ?
            """, arguments: [
                customName.isEmpty ? nil : customName,
                details.author.trimmingCharacters(in: .whitespacesAndNewlines),
                details.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines),
                details.license.trimmingCharacters(in: .whitespacesAndNewlines),
                details.modelDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                projectID
            ])
    }

    func setCoverOverride(path: String?, projectID: String) throws {
        try updateProject(
            sql: "UPDATE modelProject SET coverOverridePath = ? WHERE id = ?",
            arguments: [path, projectID]
        )
    }

    func setThumbnail(path: String, projectID: String) throws {
        try updateProject(
            sql: "UPDATE modelProject SET thumbnailPath = ? WHERE id = ?",
            arguments: [path, projectID]
        )
    }

    func createTag(_ name: String) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try databaseQueue.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM tag WHERE name = ? COLLATE NOCASE)",
                arguments: [normalized]
            ) ?? false
            guard !exists else { throw DatabaseError(message: L10n.text("A tag with this name already exists.")) }
            try db.execute(sql: """
                INSERT INTO tag (name, sortOrder)
                VALUES (?, (SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM tag))
                """, arguments: [normalized])
        }
    }

    func renameTag(_ oldName: String, to newName: String) throws {
        let normalized = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try databaseQueue.write { db in
            let conflict = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM tag
                    WHERE name = ? COLLATE NOCASE AND name != ? COLLATE NOCASE
                )
                """, arguments: [normalized, oldName]) ?? false
            guard !conflict else { throw DatabaseError(message: L10n.text("A tag with this name already exists.")) }
            try db.execute(
                sql: "UPDATE tag SET name = ? WHERE name = ? COLLATE NOCASE",
                arguments: [normalized, oldName]
            )
        }
    }

    func setTag(_ name: String, assigned: Bool, projectIDs: [String]) throws {
        guard !projectIDs.isEmpty else { return }
        try databaseQueue.write { db in
            guard let tagID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tag WHERE name = ? COLLATE NOCASE",
                arguments: [name]
            ) else { throw DatabaseError(message: L10n.format("Tag not found: %@", name)) }

            for projectID in projectIDs {
                if assigned {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO modelTag (projectID, tagID) VALUES (?, ?)",
                        arguments: [projectID, tagID]
                    )
                } else {
                    try db.execute(
                        sql: "DELETE FROM modelTag WHERE projectID = ? AND tagID = ?",
                        arguments: [projectID, tagID]
                    )
                }
            }
        }
    }

    func tagSnapshot(_ name: String) throws -> TagSnapshot? {
        try databaseQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, name, sortOrder FROM tag WHERE name = ? COLLATE NOCASE
                """, arguments: [name]) else { return nil }
            let tagID: Int64 = row["id"]
            return TagSnapshot(
                name: row["name"],
                sortOrder: row["sortOrder"],
                projectIDs: try String.fetchAll(
                    db,
                    sql: "SELECT projectID FROM modelTag WHERE tagID = ?",
                    arguments: [tagID]
                )
            )
        }
    }

    func deleteTag(_ name: String) throws {
        try databaseQueue.write { db in
            try db.execute(
                sql: "DELETE FROM tag WHERE name = ? COLLATE NOCASE",
                arguments: [name]
            )
        }
    }

    func restoreTag(_ snapshot: TagSnapshot) throws {
        try databaseQueue.write { db in
            try db.execute(
                sql: "INSERT INTO tag (name, sortOrder) VALUES (?, ?)",
                arguments: [snapshot.name, snapshot.sortOrder]
            )
            guard let tagID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tag WHERE name = ? COLLATE NOCASE",
                arguments: [snapshot.name]
            ) else { return }
            for projectID in snapshot.projectIDs {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO modelTag (projectID, tagID) VALUES (?, ?)",
                    arguments: [projectID, tagID]
                )
            }
        }
    }

    func setTagOrder(_ names: [String]) throws {
        try databaseQueue.write { db in
            for (index, name) in names.enumerated() {
                try db.execute(
                    sql: "UPDATE tag SET sortOrder = ? WHERE name = ? COLLATE NOCASE",
                    arguments: [index, name]
                )
            }
        }
    }

    func setProjectsMissing(_ missing: Bool, projectIDs: [String]) throws {
        guard !projectIDs.isEmpty else { return }
        try databaseQueue.write { db in
            for projectID in projectIDs {
                try db.execute(
                    sql: "UPDATE modelProject SET missing = ? WHERE id = ?",
                    arguments: [missing, projectID]
                )
            }
        }
    }

    func recordTransfer(_ plan: ProjectTransfer, copy: Bool, root: URL) throws {
        try databaseQueue.write { db in
            guard let original = try Row.fetchOne(db, sql: "SELECT * FROM modelProject WHERE id = ?", arguments: [plan.project.id]) else {
                throw DatabaseError(message: L10n.text("The source project is no longer in the library."))
            }
            let directory = plan.directory.path
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            let relative = directory == rootPath ? "." : directory.hasPrefix(rootPath + "/")
                ? String(directory.dropFirst(rootPath.count + 1)) : directory
            guard let model = plan.files.first(where: { ["3mf", "stl", "step", "stp", "obj", "f3d", "iges", "igs"].contains($0.destination.pathExtension.lowercased()) }) else { return }
            let name = model.destination.deletingPathExtension().lastPathComponent
            let key = relative.lowercased() + "::" + name.precomposedStringWithCanonicalMapping.lowercased()
            let libraryID: Int64 = original["libraryID"]
            let id = copy ? UUID().uuidString : plan.project.id
            if let other = try Row.fetchOne(db, sql: "SELECT id, missing FROM modelProject WHERE libraryID = ? AND groupKey = ? AND id != ?",
                                           arguments: [libraryID, key, id]) {
                let missing: Bool = other["missing"]
                guard missing else { throw DatabaseError(message: L10n.text("Another project already occupies the target location.")) }
                let otherID: String = other["id"]
                try db.execute(sql: "UPDATE modelProject SET groupKey = ? WHERE id = ?", arguments: ["missing::" + otherID, otherID])
                try db.execute(sql: "DELETE FROM modelFile WHERE projectID = ?", arguments: [otherID])
            }
            if copy {
                try db.execute(sql: """
                    INSERT INTO modelProject (id, libraryID, groupKey, name, directoryPath, createdAt, modifiedAt, importedAt,
                        size, favorite, note, customName, author, sourceURL, license, modelDescription, coverOverridePath, thumbnailPath, embeddedSourceURL, sourceIdentity, missing)
                    SELECT ?, libraryID, ?, ?, ?, createdAt, modifiedAt, ?, size, favorite, note, customName, author,
                        sourceURL, license, modelDescription, coverOverridePath, thumbnailPath, embeddedSourceURL, sourceIdentity, 0
                    FROM modelProject WHERE id = ?
                    """, arguments: [id, key, name, directory, Date(), plan.project.id])
                try db.execute(sql: "INSERT INTO modelTag (projectID, tagID) SELECT ?, tagID FROM modelTag WHERE projectID = ?",
                               arguments: [id, plan.project.id])
            } else {
                try db.execute(sql: "UPDATE modelProject SET groupKey = ?, name = ?, directoryPath = ? WHERE id = ?",
                               arguments: [key, name, directory, id])
                try db.execute(sql: "DELETE FROM modelFile WHERE projectID = ?", arguments: [id])
            }
            for file in plan.files {
                guard let source = plan.project.files.first(where: { $0.path == file.source.path }) else { continue }
                try db.execute(sql: """
                    INSERT INTO modelFile (projectID, path, filename, extension, size, createdAt, modifiedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id, file.destination.path, file.destination.lastPathComponent, source.fileExtension, source.size, source.createdAt, source.modifiedAt])
                if plan.project.coverOverridePath == file.source.path {
                    try db.execute(sql: "UPDATE modelProject SET coverOverridePath = ? WHERE id = ?", arguments: [file.destination.path, id])
                }
            }
        }
    }

    private func updateProject(sql: String, arguments: StatementArguments) throws {
        try databaseQueue.write { db in
            try db.execute(sql: sql, arguments: arguments)
        }
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "library") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("rootPath", .text).notNull().unique()
                table.column("name", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("lastScanAt", .datetime)
            }

            try db.create(table: "modelProject") { table in
                table.primaryKey("id", .text)
                table.column("libraryID", .integer).notNull()
                    .references("library", onDelete: .cascade)
                table.column("groupKey", .text).notNull()
                table.column("name", .text).notNull()
                table.column("directoryPath", .text).notNull()
                table.column("createdAt", .datetime)
                table.column("modifiedAt", .datetime)
                table.column("size", .integer).notNull().defaults(to: 0)
                table.column("favorite", .boolean).notNull().defaults(to: false)
                table.column("note", .text).notNull().defaults(to: "")
                table.column("coverOverridePath", .text)
                table.column("thumbnailPath", .text)
                table.column("missing", .boolean).notNull().defaults(to: false)
                table.uniqueKey(["libraryID", "groupKey"])
            }

            try db.create(table: "modelFile") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("projectID", .text).notNull()
                    .references("modelProject", onDelete: .cascade)
                table.column("path", .text).notNull().unique()
                table.column("filename", .text).notNull()
                table.column("extension", .text).notNull()
                table.column("size", .integer).notNull().defaults(to: 0)
                table.column("createdAt", .datetime)
                table.column("modifiedAt", .datetime)
            }

            try db.create(table: "tag") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("name", .text).notNull().unique(onConflict: .ignore)
                    .collate(.nocase)
            }

            try db.create(table: "modelTag") { table in
                table.column("projectID", .text).notNull()
                    .references("modelProject", onDelete: .cascade)
                table.column("tagID", .integer).notNull()
                    .references("tag", onDelete: .cascade)
                table.primaryKey(["projectID", "tagID"])
            }

            try db.create(index: "modelProject_library_missing", on: "modelProject",
                          columns: ["libraryID", "missing"])
            try db.create(index: "modelFile_project", on: "modelFile", columns: ["projectID"])
        }
        migrator.registerMigration("v2-editable-model-details") { db in
            try db.alter(table: "modelProject") { table in
                table.add(column: "customName", .text)
                table.add(column: "author", .text).notNull().defaults(to: "")
                table.add(column: "sourceURL", .text).notNull().defaults(to: "")
                table.add(column: "license", .text).notNull().defaults(to: "")
                table.add(column: "modelDescription", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v3-model-categories-and-import-date") { db in
            try db.alter(table: "modelProject") { table in
                table.add(column: "importedAt", .datetime)
            }
            try db.execute(sql: """
                UPDATE modelProject
                SET importedAt = COALESCE(
                    (SELECT createdAt FROM library WHERE library.id = modelProject.libraryID),
                    createdAt
                )
                """)

            try db.alter(table: "tag") { table in
                table.add(column: "sortOrder", .integer).notNull().defaults(to: 1000)
            }
            try db.execute(sql: "UPDATE tag SET sortOrder = 1000 + id")
            for (index, name) in ["Tools", "Decor", "Toys", "Education", "Fashion"].enumerated() {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO tag (name, sortOrder) VALUES (?, ?)",
                    arguments: [name, index]
                )
                try db.execute(
                    sql: "UPDATE tag SET sortOrder = ? WHERE name = ? COLLATE NOCASE",
                    arguments: [index, name]
                )
            }
        }
        migrator.registerMigration("v4-english-tag-names") { db in
            try db.execute(sql: "UPDATE tag SET sortOrder = 1000 + id")
            let mappings = [
                ("工具", "Tools"),
                ("摆件", "Decor"),
                ("玩具", "Toys"),
                ("教育", "Education"),
                ("时尚", "Fashion")
            ]
            for (index, mapping) in mappings.enumerated() {
                let oldID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM tag WHERE name = ? COLLATE NOCASE",
                    arguments: [mapping.0]
                )
                var newID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM tag WHERE name = ? COLLATE NOCASE",
                    arguments: [mapping.1]
                )

                if let oldID, let existingNewID = newID, oldID != existingNewID {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO modelTag (projectID, tagID)
                        SELECT projectID, ? FROM modelTag WHERE tagID = ?
                        """, arguments: [existingNewID, oldID])
                    try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [oldID])
                } else if let oldID, newID == nil {
                    try db.execute(
                        sql: "UPDATE tag SET name = ? WHERE id = ?",
                        arguments: [mapping.1, oldID]
                    )
                    newID = oldID
                } else if newID == nil {
                    try db.execute(
                        sql: "INSERT INTO tag (name, sortOrder) VALUES (?, ?)",
                        arguments: [mapping.1, index]
                    )
                    newID = db.lastInsertedRowID
                }

                if let newID {
                    try db.execute(
                        sql: "UPDATE tag SET sortOrder = ? WHERE id = ?",
                        arguments: [index, newID]
                    )
                }
            }
        }
        migrator.registerMigration("v5-source-groups") { db in
            try db.alter(table: "modelProject") { table in
                table.add(column: "embeddedSourceURL", .text)
            }
        }
        migrator.registerMigration("v6-library-management") { db in
            try db.alter(table: "library") { table in
                table.add(column: "removed", .boolean).notNull().defaults(to: false)
                table.add(column: "lastOpenedAt", .datetime)
            }
            // The same file may belong to overlapping libraries; each project owns its index.
            try db.execute(sql: """
                CREATE TABLE modelFileNew (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    projectID TEXT NOT NULL REFERENCES modelProject(id) ON DELETE CASCADE,
                    path TEXT NOT NULL, filename TEXT NOT NULL, extension TEXT NOT NULL,
                    size INTEGER NOT NULL DEFAULT 0, createdAt DATETIME, modifiedAt DATETIME,
                    UNIQUE(projectID, path)
                );
                INSERT INTO modelFileNew SELECT * FROM modelFile;
                DROP TABLE modelFile;
                ALTER TABLE modelFileNew RENAME TO modelFile;
                CREATE INDEX modelFile_project ON modelFile(projectID);
                """)
        }
        migrator.registerMigration("v11_sourceResolution") { db in
            try db.alter(table: "modelProject") { $0.add(column: "sourceSignature", .text).notNull().defaults(to: "") }
            // Invalidate derived sources once; manually saved URLs remain untouched.
            try db.execute(sql: "UPDATE modelProject SET embeddedSourceURL = NULL")
        }
        migrator.registerMigration("v12_internalSourceIdentity") { db in
            try db.alter(table: "modelProject") { $0.add(column: "sourceIdentity", .text).notNull().defaults(to: "") }
            try db.execute(sql: "UPDATE modelProject SET embeddedSourceURL = NULL, sourceSignature = ''")
        }
        try migrator.migrate(databaseQueue)
    }

    private static func applicationSupportFolder() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base.appendingPathComponent("lokrel", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func library(from row: Row) -> LibraryLocation {
        LibraryLocation(
            id: row["id"],
            rootPath: row["rootPath"],
            name: row["name"],
            lastScanAt: row["lastScanAt"]
        )
    }
}
