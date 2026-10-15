import Foundation

/// The engine's virtual file system (docs/re/01 §2, `sub_140273f50`).
///
/// Resolution order: mounted package, then the literal path, then each search directory in
/// insertion order. The engine inserts `<install>/assets/` first and the wallpaper directory second,
/// so for loose wallpapers engine assets win over the wallpaper's own files.
public final class AssetFileSystem {
    public private(set) var package: PackageFile?
    public private(set) var searchDirectories: [URL] = []

    /// The engine's working directory: the folder of wallpaper64.exe. Startup (0x14000a220) takes the module path,
    /// strips the file name and calls `SetCurrentDirectoryW` (0x14000a851), so step 2 of the lookup (a relative literal
    /// path) resolves against it. In a Steam install that is `<install>/distribution` when present, else `<install>`.
    public private(set) var workingDirectory: URL?

    public init(engineAssets: URL?) {
        if let engineAssets {
            searchDirectories.append(engineAssets)
            let install = engineAssets.deletingLastPathComponent()
            let dist = install.appendingPathComponent("distribution")
            workingDirectory = FileManager.default.fileExists(atPath: dist.appendingPathComponent("wallpaper64.exe").path) ? dist : install
        }
    }

    /// Mounts a wallpaper the way `sub_14010df40` does. Returns the scene file's VFS path.
    @discardableResult
    public func mountWallpaper(file: URL) throws -> String {
        if file.pathExtension.lowercased() == "pkg" {
            package = try PackageFile(url: file)
            searchDirectories.append(file.deletingLastPathComponent())
            return file.deletingPathExtension().lastPathComponent + ".json"
        }
        package = nil
        let dir = file.deletingLastPathComponent()
        if !dir.path.contains("/assets") { searchDirectories.append(dir) }
        return file.lastPathComponent
    }

    /// Appends a search directory (used to mount the built-in `scenes/videoplayer` scene for video wallpapers).
    public func addSearchDirectory(_ dir: URL) {
        if !searchDirectories.contains(dir) { searchDirectories.append(dir) }
    }

    public func read(_ path: String) -> Data? {
        if let data = package?.read(path) { return data }
        if path.hasPrefix("/") {
            if let data = FileManager.default.contents(atPath: path) { return data }
        } else if let cwd = workingDirectory, let data = FileManager.default.contents(atPath: cwd.appendingPathComponent(path).path) {
            return data
        }
        for dir in searchDirectories {
            if let data = FileManager.default.contents(atPath: dir.appendingPathComponent(path).path) { return data }
        }
        return nil
    }

    public func readJSON(_ path: String) -> Any? {
        read(path).flatMap { parseEngineJSON($0) }
    }

    /// Textures always resolve to `materials/<name>.tex` (`sub_1400eb130`); there is no extension fallback.
    public static func texturePath(_ name: String) -> String { "materials/" + name + ".tex" }
}
