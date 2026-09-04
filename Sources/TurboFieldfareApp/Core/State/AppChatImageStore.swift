import Darwin
import Foundation

/// Archive metadata never supplies a filesystem path. Images are addressed by
/// UUID under the archive's own sidecar directory, independently of staging.
public struct AppChatImageAttachment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let encodedBytes: Int
    public let sha256: String

    init(id: UUID = UUID(), attachment: AppImageAttachment) {
        self.id = id
        displayName = attachment.displayName
        encodedBytes = attachment.encodedBytes
        sha256 = attachment.sha256
    }
}

struct AppChatImageStore: Sendable {
    let directoryURL: URL

    init(modelDirectory: URL) {
        directoryURL = AppChatFileStore.fileURL(forModelDirectory: modelDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("mac-app-chat-images", isDirectory: true)
    }

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func attachment(for image: AppChatImageAttachment) -> AppImageAttachment {
        AppImageAttachment(
            id: image.id,
            fileURL: directoryURL.appendingPathComponent(image.id.uuidString + ".image"),
            displayName: image.displayName,
            encodedBytes: image.encodedBytes,
            sha256: image.sha256)
    }

    /// One independent link per archived image. Branches share its descriptor;
    /// unlinking the inference or composer copy cannot remove the history copy.
    func save(_ attachments: [AppImageAttachment]) throws -> [AppChatImageAttachment] {
        guard !attachments.isEmpty else { return [] }
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var directoryStatus = stat()
        guard lstat(directoryURL.path, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var saved: [AppChatImageAttachment] = []
        do {
            for source in attachments {
                var status = stat()
                guard lstat(source.fileURL.path, &status) == 0,
                      status.st_mode & S_IFMT == S_IFREG,
                      status.st_size == source.encodedBytes else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let image = AppChatImageAttachment(attachment: source)
                let destination = attachment(for: image).fileURL
                if link(source.fileURL.path, destination.path) != 0 {
                    guard errno == EXDEV else { throw CocoaError(.fileWriteUnknown) }
                    do {
                        try FileManager.default.copyItem(at: source.fileURL, to: destination)
                    } catch {
                        // A cross-volume copy can leave an incomplete file
                        // when space runs out. It has not entered `saved` yet.
                        try? FileManager.default.removeItem(at: destination)
                        throw error
                    }
                }
                saved.append(image)
            }
            return saved
        } catch {
            remove(ids: Set(saved.map(\.id)))
            throw error
        }
    }

    func remove(ids: Set<UUID>) {
        // Never follow a replaced sidecar directory to delete unrelated files.
        var status = stat()
        guard lstat(directoryURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else { return }
        for id in ids {
            try? FileManager.default.removeItem(
                at: directoryURL.appendingPathComponent(id.uuidString + ".image"))
        }
    }
}
