import Foundation

struct FileEntry: Identifiable {
    let id = UUID()
    let relativePath: String   // relative to container root
    let absolutePath: String
    let size: Int64
    var selected: Bool = false
}

struct AppContainer: Identifiable {
    let id = UUID()
    let bundleId: String
    let containerPath: String
    var files: [FileEntry] = []
}

struct DumpEntry: Codable {
    let bundleId: String
    let file: String       // relative path
    let sizeBytes: Int64
    let content: String    // base64
}
