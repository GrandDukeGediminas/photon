import AppKit
import Foundation
import XCTest
@testable import PhotonApp
@testable import photon

/// A throwaway defaults suite. Never the app's own `photon2` domain: the user's settings must stay untouched.
final class TestDefaults {
    let suite: String
    let defaults: UserDefaults

    init(_ name: String = "photon2-tests-\(UUID().uuidString)") {
        precondition(name != AppState.defaultsSuite, "tests must not use the app's defaults suite")
        suite = name
        defaults = UserDefaults(suiteName: name)!
    }

    func remove() { defaults.removePersistentDomain(forName: suite) }
}

/// A library folder with fake projects (project.json only): `scene` items `s0…`, `video` items `v0…`, `web` items `w0…`.
final class FakeLibrary {
    let root: URL

    init(scenes: Int = 5, videos: Int = 1, webs: Int = 1) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photon-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<scenes { add("s\(i)", file: "scene.json") }
        for i in 0..<videos { add("v\(i)", file: "clip.mp4") }
        for i in 0..<webs { add("w\(i)", file: "index.html") }
    }

    func add(_ id: String, file: String) {
        let dir = root.appendingPathComponent(id)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project: [String: Any] = ["file": file, "title": id]
        try! JSONSerialization.data(withJSONObject: project).write(to: dir.appendingPathComponent("project.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// AppState over a fake library and a temporary defaults suite.
func makeState(_ d: TestDefaults, library: FakeLibrary, assets: URL? = nil) -> AppState {
    AppState(engineAssets: assets ?? library.root.appendingPathComponent("no-assets/assets"),
             libraryDirectories: [library.root], defaults: d.defaults, hiddenFile: nil)
}

/// Runs the main run loop for a while (scene loads finish on the main queue).
func spin(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func playlistJSON(_ settings: [String: Any]?, _ items: [Any], name: String = "t") -> [String: Any] {
    var o: [String: Any] = ["name": name, "items": items]
    if let settings { o["settings"] = settings }
    return o
}

func localDate(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = .current
    return f.date(from: s)!
}
