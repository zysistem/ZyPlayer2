import Foundation

/// Reads video files out of Google Drive.
struct GoogleDriveClient {
    var accessToken: String

    struct DriveFile: Decodable, Identifiable {
        var id: String
        var name: String
        var mimeType: String
        var size: String?
        var modifiedTime: Date?
        var parents: [String]?

        var byteSize: Int64 { Int64(size ?? "0") ?? 0 }

        /// The endpoint mpv streams from; needs the bearer header.
        var downloadURL: URL {
            URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!
        }
    }

    private struct FileList: Decodable {
        var files: [DriveFile]
        var nextPageToken: String?
    }

    /// Folders directly inside `parentID` ("root" for My Drive).
    func listFolders(in parentID: String) async throws -> [DriveFile] {
        try await query(
            "mimeType = 'application/vnd.google-apps.folder' and trashed = false "
            + "and '\(parentID)' in parents"
        )
    }

    /// Every non-trashed video in the account.
    func listVideos(progress: ((Int) -> Void)? = nil) async throws -> [DriveFile] {
        try await query("mimeType contains 'video/' and trashed = false", progress: progress)
    }

    /// Videos inside `folderID` and all of its sub-folders.
    ///
    /// Drive's query language has no recursive descent, so we pull the (small)
    /// folder tree once, work out which folders are descendants, then filter the
    /// video list by parent.
    func listVideos(inFolder folderID: String,
                    progress: ((Int) -> Void)? = nil) async throws -> [DriveFile] {
        let allFolders = try await query(
            "mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        )

        var childrenByParent: [String: [String]] = [:]
        for folder in allFolders {
            for parent in folder.parents ?? [] {
                childrenByParent[parent, default: []].append(folder.id)
            }
        }

        var allowed: Set<String> = [folderID]
        var queue = [folderID]
        while let current = queue.popLast() {
            for child in childrenByParent[current] ?? [] where !allowed.contains(child) {
                allowed.insert(child)
                queue.append(child)
            }
        }

        let videos = try await query("mimeType contains 'video/' and trashed = false",
                                     progress: progress)
        return videos.filter { file in
            (file.parents ?? []).contains { allowed.contains($0) }
        }
    }

    /// Runs a Drive query, following pagination.
    private func query(_ q: String, progress: ((Int) -> Void)? = nil) async throws -> [DriveFile] {
        var collected: [DriveFile] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var items: [URLQueryItem] = [
                .init(name: "q", value: q),
                .init(name: "fields", value: "nextPageToken, files(id, name, mimeType, size, modifiedTime, parents)"),
                .init(name: "pageSize", value: "1000"),
                .init(name: "orderBy", value: "name"),
                .init(name: "supportsAllDrives", value: "true"),
                .init(name: "includeItemsFromAllDrives", value: "true")
            ]
            if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
            components.queryItems = items

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw NSError(
                    domain: "GoogleDrive", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: "Drive listelenemedi: \(body.prefix(160))"]
                )
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let page = try decoder.decode(FileList.self, from: data)
            collected.append(contentsOf: page.files)
            progress?(collected.count)
            pageToken = page.nextPageToken
        } while pageToken != nil

        return collected
    }
}
