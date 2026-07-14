#if DEBUG
import Foundation
import ZIPFoundation

enum DevelopmentValidation {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokrelValidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelFolder = root.appendingPathComponent("SKADIS Antenna Holder", isDirectory: true)
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        let threeMFURL = modelFolder.appendingPathComponent("SKADIS Antenna Holder.3mf")
        try makeThreeMF(at: threeMFURL)

        for filename in [
            "SKADIS Antenna Holder.step",
            "SKADIS Antenna Holder.stl",
            "SKADIS Antenna Holder.jpg",
            "SKADIS Antenna Holder.pdf",
            "README.md"
        ] {
            try Data(filename.utf8).write(to: modelFolder.appendingPathComponent(filename))
        }
        try Data("gear".utf8).write(to: root.appendingPathComponent("Planetary Gear.step"))
        let previewSTL = root.appendingPathComponent("Planetary Gear.stl")
        try sampleASCIISTL().write(to: previewSTL, atomically: true, encoding: .utf8)
        let previewOBJ = root.appendingPathComponent("Planetary Gear.obj")
        try sampleOBJ().write(to: previewOBJ, atomically: true, encoding: .utf8)

        var scan = try LibraryScanner.scanSynchronously(rootURL: root)
        try require(scan.projects.count == 2, "Expected two model projects")
        let groupedProject = scan.projects.first { $0.name == "SKADIS Antenna Holder" }
        try require(groupedProject?.files.count == 6, "Expected all six related files")

        let database = try DatabaseStore(path: root.appendingPathComponent("validation.sqlite").path)
        var library = try database.applyScan(scan, rootURL: root)
        let defaultTags = try database.allTags(libraryID: library.id)
        try require(
            Array(defaultTags.prefix(5)) == ["Tools", "Decor", "Toys", "Education", "Fashion"],
            "Default category order was not created"
        )
        guard var project = try database.projects(libraryID: library.id).first(where: {
            $0.name == "SKADIS Antenna Holder"
        }) else {
            throw ValidationError.failed("Expected a stored project")
        }
        try require(project.importedAt != nil, "Import date was not stored")
        try database.setFavorite(true, projectID: project.id)
        try database.setNote("Upload to MakerWorld", projectID: project.id)
        try database.createTag("608")
        try database.setTag("608", assigned: true, projectIDs: [project.id])
        try database.setEditableDetails(EditableModelDetails(
            customName: "Antenna Holder",
            author: "lokrel Test",
            sourceURL: "https://example.com/model",
            license: "CC BY 4.0",
            modelDescription: "Grouped model project"
        ), projectID: project.id)

        scan = try LibraryScanner.scanSynchronously(rootURL: root)
        library = try database.applyScan(scan, rootURL: root)
        guard let rescannedProject = try database.projects(libraryID: library.id).first(where: {
            $0.name == "SKADIS Antenna Holder"
        }) else {
            throw ValidationError.failed("Expected a project after rescan")
        }
        project = rescannedProject
        try require(project.favorite, "Favorite was not preserved")
        try require(project.note == "Upload to MakerWorld", "Note was not preserved")
        try require(project.tags == ["608"], "Tag was not preserved")
        try require(project.displayName == "Antenna Holder", "Custom name was not preserved")
        try require(project.author == "lokrel Test", "Author was not preserved")
        try require(project.sourceURL == "https://example.com/model", "Source URL was not preserved")
        guard let tagSnapshot = try database.tagSnapshot("608") else {
            throw ValidationError.failed("Expected a tag snapshot")
        }
        try database.deleteTag("608")
        let tagsAfterDefinitionDelete = try database.allTags(libraryID: library.id)
        try require(
            !tagsAfterDefinitionDelete.contains("608"),
            "Tag definition was not deleted"
        )
        try database.restoreTag(tagSnapshot)
        let restoredTagProject = try database.projects(libraryID: library.id)
            .first(where: { $0.id == project.id })
        try require(
            restoredTagProject?.tags.contains("608") == true,
            "Deleted tag assignments were not restored"
        )
        try database.renameTag("608", to: "Prototype")
        try database.setTag("Prototype", assigned: false, projectIDs: [project.id])
        let tagsAfterRemoval = try database.allTags(libraryID: library.id)
        try require(
            tagsAfterRemoval.contains("Prototype"),
            "Unassigned tag definition was not preserved"
        )
        try database.setProjectsMissing(true, projectIDs: [project.id])
        let visibleAfterHiding = try database.projects(libraryID: library.id)
        try require(
            !visibleAfterHiding.contains(where: { $0.id == project.id }),
            "Missing project was still visible"
        )
        try database.setProjectsMissing(false, projectIDs: [project.id])
        let restoredProject = try database.projects(libraryID: library.id)
            .first(where: { $0.id == project.id })
        try require(restoredProject?.files.count == 6, "Hidden project files were not preserved")

        let metadata = try ThreeMFMetadataService.extract(fileURL: threeMFURL)
        try require(metadata.designer == "Sample Designer", "3MF designer metadata was not extracted")
        try require(metadata.title == "Sample Holder", "3MF title metadata was not extracted")
        try require(
            metadata.description == "Pipeline - Heavy Planetary Gear\nBlade: https://makerworld.com/en/models/760893",
            "HTML metadata description was not cleaned"
        )
        try require(
            metadata.sourceURL == "https://makerworld.com/en/models/614749",
            "MakerWorld source URL was not inferred"
        )
        let linkedDescription = ExtractedModelMetadata(entries: [
            MetadataEntry(
                name: "Description",
                value: sanitizedMetadataText("&lt;a href=&amp;#34;https://makerworld.com/en/models/760893&amp;#34;&gt;Blade&lt;/a&gt;")
            )
        ])
        try require(
            linkedDescription.sourceURL == "https://makerworld.com/en/models/760893",
            "Description link URL was not inferred"
        )

        let thumbnailPath = try ThumbnailService.extractEmbeddedThumbnail(
            sourceURL: threeMFURL,
            projectID: project.id
        )
        try require(thumbnailPath != nil, "Expected an embedded 3MF thumbnail")
        if let thumbnailPath { try? FileManager.default.removeItem(atPath: thumbnailPath) }

        let stlThumbnailPath = try ModelPreviewService.cachedThumbnail(
            fileURL: previewSTL,
            projectID: UUID().uuidString
        )
        try require(
            FileManager.default.fileExists(atPath: stlThumbnailPath),
            "Expected a rendered STL thumbnail"
        )
        try? FileManager.default.removeItem(atPath: stlThumbnailPath)

        let objThumbnailPath = try ModelPreviewService.cachedThumbnail(
            fileURL: previewOBJ,
            projectID: UUID().uuidString
        )
        try require(
            FileManager.default.fileExists(atPath: objThumbnailPath),
            "Expected a rendered OBJ thumbnail"
        )
        try? FileManager.default.removeItem(atPath: objThumbnailPath)
    }

    static func benchmark(projectCount: Int) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokrelBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<projectCount {
            let url = root.appendingPathComponent("Model \(index).3mf")
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }

        let scanStartedAt = Date()
        let result = try LibraryScanner.scanSynchronously(rootURL: root)
        let scanDuration = Date().timeIntervalSince(scanStartedAt)
        try require(result.projects.count == projectCount, "Benchmark scan count mismatch")

        let database = try DatabaseStore(path: root.appendingPathComponent("benchmark.sqlite").path)
        let databaseStartedAt = Date()
        _ = try database.applyScan(result, rootURL: root)
        let databaseDuration = Date().timeIntervalSince(databaseStartedAt)

        print("Benchmark: \(projectCount) projects")
        print("Directory scan: \(String(format: "%.2f", scanDuration))s")
        print("SQLite update: \(String(format: "%.2f", databaseDuration))s")
        print("Total: \(String(format: "%.2f", scanDuration + databaseDuration))s")
    }

    private static func makeThreeMF(at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try add(data: imageData, path: "Metadata/thumbnail.png", to: archive)
        let modelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <metadata name="Title">Sample Holder</metadata>
          <metadata name="Designer">Sample Designer</metadata>
          <metadata name="LicenseTerms">CC BY 4.0</metadata>
          <metadata name="DesignModelId">614749</metadata>
          <metadata name="Description">&amp;lt;h3&amp;gt;Pipeline - Heavy Planetary Gear&amp;lt;/h3&amp;gt;&amp;lt;p&amp;gt;Blade: &amp;lt;a target=&amp;amp;#34;_blank&amp;amp;#34; href=&amp;amp;#34;https://makerworld.com/en/models/760893&amp;amp;#34; rel=&amp;amp;#34;nofollow noopener&amp;amp;#34;&amp;gt;https://makerworld.com/en/models/760893&amp;lt;/a&amp;gt;&amp;lt;/p&amp;gt;</metadata>
          <resources/>
          <build/>
        </model>
        """
        try add(data: Data(modelXML.utf8), path: "3D/3dmodel.model", to: archive)
    }

    private static func add(data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
            position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
    }

    private static func sampleASCIISTL() -> String {
        """
        solid pyramid
          facet normal 0 0 -1
            outer loop
              vertex -1 -1 0
              vertex 1 -1 0
              vertex 0 1 0
            endloop
          endfacet
          facet normal 0 1 1
            outer loop
              vertex -1 -1 0
              vertex 1 -1 0
              vertex 0 0 2
            endloop
          endfacet
          facet normal -1 0 1
            outer loop
              vertex 1 -1 0
              vertex 0 1 0
              vertex 0 0 2
            endloop
          endfacet
          facet normal 1 0 1
            outer loop
              vertex 0 1 0
              vertex -1 -1 0
              vertex 0 0 2
            endloop
          endfacet
        endsolid pyramid
        """
    }

    private static func sampleOBJ() -> String {
        """
        o Pyramid
        v -1 -1 0
        v 1 -1 0
        v 0 1 0
        v 0 0 2
        f 1 2 3
        f 1 2 4
        f 2 3 4
        f 3 1 4
        """
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ValidationError.failed(message) }
    }
}

private enum ValidationError: Error {
    case failed(String)
}
#endif
