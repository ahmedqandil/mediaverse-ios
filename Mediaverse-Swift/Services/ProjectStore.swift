import Foundation

struct AssetStore {
    let projectID: UUID
    let baseURL: URL

    var projectURL: URL { baseURL.appendingPathComponent(projectID.uuidString, isDirectory: true) }
    var mediaURL: URL { projectURL.appendingPathComponent("media", isDirectory: true) }
    var thumbsURL: URL { projectURL.appendingPathComponent("thumbs", isDirectory: true) }
    var projectJSONURL: URL { projectURL.appendingPathComponent("project.json") }

    func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbsURL, withIntermediateDirectories: true)
    }

    func importData(_ data: Data, extension fileExtension: String) throws -> String {
        try ensureDirectories()
        let fileName = "\(UUID().uuidString).\(fileExtension)"
        let destination = mediaURL.appendingPathComponent(fileName)
        try data.write(to: destination, options: [.atomic])
        return "media/\(fileName)"
    }

    func importFile(_ sourceURL: URL, extension fallbackExtension: String) throws -> String {
        try ensureDirectories()
        let ext = sourceURL.pathExtension.isEmpty ? fallbackExtension : sourceURL.pathExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        let destination = mediaURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return "media/\(fileName)"
    }

    func absoluteURL(for relativePath: String) -> URL {
        projectURL.appendingPathComponent(relativePath)
    }
}

actor ProjectStore {
    static let shared = ProjectStore()

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rootURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()

        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.rootURL = applicationSupport
            .appendingPathComponent("Projects", isDirectory: true)
    }

    func list() throws -> [Project] {
        try ensureRoot()
        let projectFolders = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return projectFolders.compactMap { folder in
            let jsonURL = folder.appendingPathComponent("project.json")
            guard fileManager.fileExists(atPath: jsonURL.path),
                  let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            return try? open(id: id)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func create(_ project: Project) throws -> Project {
        try save(project)
        return project
    }

    func open(id: UUID) throws -> Project {
        let store = assetStore(for: id)
        let data = try Data(contentsOf: store.projectJSONURL)
        return try decoder.decode(Project.self, from: data)
    }

    func save(_ project: Project) throws {
        try ensureRoot()
        let store = assetStore(for: project.id)
        try store.ensureDirectories()
        var saved = project
        saved.updatedAt = Date()
        let data = try encoder.encode(saved)
        let tempURL = store.projectURL.appendingPathComponent("project.tmp.json")
        try data.write(to: tempURL, options: [.atomic])

        if fileManager.fileExists(atPath: store.projectJSONURL.path) {
            _ = try fileManager.replaceItemAt(store.projectJSONURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: store.projectJSONURL)
        }
    }

    func delete(id: UUID) throws {
        let url = assetStore(for: id).projectURL
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func duplicate(id: UUID) throws -> Project {
        let original = try open(id: id)
        let now = Date()
        let copy = Project(
            id: UUID(),
            title: original.title + " Copy",
            createdAt: now,
            updatedAt: now,
            canvas: original.canvas,
            tracks: original.tracks,
            coverTimeSeconds: original.coverTimeSeconds,
            schemaVersion: original.schemaVersion,
            storyDestination: original.storyDestination
        )

        let originalStore = assetStore(for: original.id)
        let copyStore = assetStore(for: copy.id)
        try fileManager.createDirectory(at: copyStore.projectURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: originalStore.mediaURL.path) {
            try fileManager.copyItem(at: originalStore.mediaURL, to: copyStore.mediaURL)
        }
        if fileManager.fileExists(atPath: originalStore.thumbsURL.path) {
            try fileManager.copyItem(at: originalStore.thumbsURL, to: copyStore.thumbsURL)
        }
        try save(copy)
        return copy
    }

    func assetStore(for id: UUID) -> AssetStore {
        AssetStore(projectID: id, baseURL: rootURL)
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
}
