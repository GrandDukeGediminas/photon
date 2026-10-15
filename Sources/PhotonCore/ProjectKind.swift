import Foundation

/// What kind of wallpaper a project is. The engine does not trust project.json's `type`: `Project_Load` 0x14011d7d0
/// classifies the `file` value with `Project_ClassifyFile` 0x14011e520 and writes the result back into `type`
/// ("Scene", "Web", "Application", "Video", else "Unknown"; 0x14011e2aa–0x14011e317).
public enum ProjectKind: Int, Sendable {
    case unknown = 0, scene = 1, web = 2, application = 3, video = 4, image = 5

    /// `Project_ClassifyFile` 0x14011e520: the file extension (compared case-sensitively against the tables at
    /// 0x140483850, 0x1404837d0, 0x1404837c0, 0x140483810, 0x1404837e0), then an `http://` / `https://` prefix
    /// (0x140018980) for web pages.
    public static func classify(file: String) -> ProjectKind {
        let ext = file.range(of: ".", options: .backwards).map { String(file[$0.lowerBound...]) } ?? ""
        if [".json", ".pkg", ".gif"].contains(ext) { return .scene }
        if ext == ".html" { return .web }
        if ext == ".exe" { return .application }
        if [".mp4", ".wmv", ".avi", ".m4v", ".mov", ".webm", ".mkv"].contains(ext) { return .video }
        if file.hasPrefix("http://") || file.hasPrefix("https://") { return .web }
        if [".png", ".bmp", ".jpeg", ".jpg", ".jfif"].contains(ext) { return .image }
        return .unknown
    }

    /// The `type` string the engine stores back into the project (0x14011e2c5–0x14011e2e9).
    public var typeName: String {
        switch self {
        case .scene: return "Scene"
        case .web: return "Web"
        case .application: return "Application"
        case .video: return "Video"
        case .unknown, .image: return "Unknown"
        }
    }
}
