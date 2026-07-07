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
                ORDER BY COALESCE(lastScanAt, createdAt) DESC
                LIMIT 1
                """) else { return nil }
            return library(from: row)
        }
    }

    @discardableResult
    func applyScan(_ result: ScanResult, rootURL: URL) throws -> LibraryLocation {
        try databaseQueue.write { db in
            let now = Date()
            try db.execute(sql: """
                INSERT INTO library (rootPath, name, createdAt)
                VALUES (?, ?, ?)
                ON CONFLICT(rootPath) DO UPDATE SET name = excluded.name
                """, arguments: [rootURL.path, rootURL.lastPathComponent, now])

            guard let libraryID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM library WHERE rootPath = ?",
                arguments: [rootURL.path]
            ) else {
                throw DatabaseError(message: "Could not create library")
            }

            try db.execute(
                sql: "UPDATE modelProject SET missing = 1 WHERE libraryID = ?",
                arguments: [libraryID]
            )
            try db.execute(sql: """
                DELETE FROM modelFile
                WHERE projectID IN (
                    SELECT id FROM modelProject WHERE libraryID = ?
                )
                """, arguments: [libraryID])

            for scannedProject in result.projects {
                let projectID = try String.fetchOne(db, sql: """
                    SELECT id FROM modelProject
                    WHERE libraryID = ? AND groupKey = ?
                    """, arguments: [libraryID, scannedProject.groupKey]) ?? UUID().uuidString

                try db.execute(sql: """
                    INSERT INTO modelProject (
                        id, libraryID, groupKey, name, directoryPath,
                        createdAt, modifiedAt, size, missing
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                    ON CONFLICT(id) DO UPDATE SET
                        groupKey = excluded.groupKey,
                        name = excluded.name,
                        directoryPath = excluded.directoryPath,
                        createdAt = excluded.createdAt,
                        modifiedAt = excluded.modifiedAt,
                        size = excluded.size,
                        thumbnailPath = CASE
                            WHEN modelProject.modifiedAt = excluded.modifiedAt
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
                        scannedProject.size
                    ])

                for file in scannedProject.files {
                    try db.execute(sql: """
                        INSERT INTO modelFile (
                            projectID, path, filename, extension, size, createdAt, modifiedAt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
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

            try db.execute(
                sql: "UPDATE library SET lastScanAt = ? WHERE id = ?",
                arguments: [now, libraryID]
            )
            return LibraryLocation(
                id: libraryID,
                rootPath: rootURL.path,
                name: rootURL.lastPathComponent,
                lastScanAt: now
            )
        }
    }

    func projects(libraryID: Int64) throws -> [ModelProject] {
        try databaseQueue.read { db in
            let projectRows = try Row.fetchAll(db, sql: """
                SELECT id, name, directoryPath, createdAt, modifiedAt, size,
                       favorite, note, customName, author, sourceURL, license,
                       modelDescription, coverOverridePath, thumbnailPath
                FROM modelProject
                WHERE libraryID = ? AND missing = 0
                ORDER BY COALESCE(NULLIF(customName, ''), name) COLLATE NOCASE
                """, arguments: [libraryID])

            let fileRows = try Row.fetchAll(db, sql: """
                SELECT f.id, f.projectID, f.path, f.filename, f.extension,
                       f.size, f.createdAt, f.modifiedAt
                FROM modelFile f
                JOIN modelProject p ON p.id = f.projectID
                WHERE p.libraryID = ? AND p.missing = 0
                ORDER BY f.projectID, f.filename COLLATE NOCASE
                """, arguments: [libraryID])

            let tagRows = try Row.fetchAll(db, sql: """
                SELECT mt.projectID, t.name
                FROM modelTag mt
                JOIN tag t ON t.id = mt.tagID
                JOIN modelProject p ON p.id = mt.projectID
                WHERE p.libraryID = ? AND p.missing = 0
                ORDER BY t.name COLLATE NOCASE
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
                    tags: tagsByProject[id] ?? []
                )
            }
        }
    }

    func allTags(libraryID: Int64) throws -> [String] {
        try databaseQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT t.name
                FROM tag t
                JOIN modelTag mt ON mt.tagID = t.id
                JOIN modelProject p ON p.id = mt.projectID
                WHERE p.libraryID = ? AND p.missing = 0
                ORDER BY t.name COLLATE NOCASE
                """, arguments: [libraryID])
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

    func addTag(_ name: String, projectID: String) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try databaseQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO tag (name) VALUES (?)",
                arguments: [normalized]
            )
            guard let tagID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tag WHERE name = ? COLLATE NOCASE",
                arguments: [normalized]
            ) else { return }
            try db.execute(
                sql: "INSERT OR IGNORE INTO modelTag (projectID, tagID) VALUES (?, ?)",
                arguments: [projectID, tagID]
            )
        }
    }

    func removeTag(_ name: String, projectID: String) throws {
        try databaseQueue.write { db in
            try db.execute(sql: """
                DELETE FROM modelTag
                WHERE projectID = ? AND tagID IN (
                    SELECT id FROM tag WHERE name = ? COLLATE NOCASE
                )
                """, arguments: [projectID, name])
            try db.execute(sql: """
                DELETE FROM tag
                WHERE NOT EXISTS (SELECT 1 FROM modelTag WHERE modelTag.tagID = tag.id)
                """)
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
