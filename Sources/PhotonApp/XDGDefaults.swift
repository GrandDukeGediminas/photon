#if os(Linux)
import Foundation

/// The `photon2` defaults domain on Linux: the same keys and value types the macOS app keeps in
/// `~/Library/Preferences/photon2.plist`, in an XML property list at `$XDG_CONFIG_HOME/photon2/photon2.plist`
/// (`~/.config/photon2/photon2.plist`). swift-corelibs-foundation's own `UserDefaults(suiteName:)` writes elsewhere
/// (`~/.local/share`-style CFPreferences paths depending on the release) and only on `synchronize`, so the app uses this
/// subclass, which writes the file on every change (the settings are small and change on user actions only).
package final class XDGDefaults: UserDefaults {
    package let fileURL: URL
    private var store: [String: Any]

    /// `$XDG_CONFIG_HOME/photon2`, else `~/.config/photon2`.
    package static var configDirectory: URL {
        if let x = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], x.hasPrefix("/") {
            return URL(fileURLWithPath: x).appendingPathComponent("photon2")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/photon2")
    }

    package init?(directory: URL = XDGDefaults.configDirectory, name: String = "photon2") {
        fileURL = directory.appendingPathComponent(name + ".plist")
        store = [:]
        if let data = try? Data(contentsOf: fileURL),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            store = plist
        }
        super.init(suiteName: nil)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: Self.plistValue(store) ?? [String: Any](), format: .xml, options: 0)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("photon: cannot write \(fileURL.path): \(error)\n".utf8))
        }
    }

    /// Swift values as property-list objects (Bool and integers as NSNumber, nested collections converted).
    static func plistValue(_ v: Any) -> Any? {
        switch v {
        case let b as Bool where type(of: v) == Bool.self: return NSNumber(value: b)
        case let i as Int where type(of: v) == Int.self: return NSNumber(value: i)
        case let d as Double where type(of: v) == Double.self: return NSNumber(value: d)
        case let f as Float where type(of: v) == Float.self: return NSNumber(value: f)
        case let s as String: return s
        case let d as Data: return d
        case let n as NSNumber: return n
        case let date as Date: return date
        case let a as [Any]: return a.compactMap(plistValue)
        case let o as [String: Any]:
            var out: [String: Any] = [:]
            for (k, x) in o { if let p = plistValue(x) { out[k] = p } }
            return out
        default: return nil
        }
    }

    package override func object(forKey defaultName: String) -> Any? { store[defaultName] }

    package override func set(_ value: Any?, forKey defaultName: String) {
        if let value, let p = Self.plistValue(value) { store[defaultName] = p } else { store[defaultName] = nil }
        save()
    }

    package override func removeObject(forKey defaultName: String) {
        store[defaultName] = nil
        save()
    }

    package override func set(_ value: Bool, forKey defaultName: String) { set(NSNumber(value: value) as Any?, forKey: defaultName) }
    package override func set(_ value: Int, forKey defaultName: String) { set(NSNumber(value: value) as Any?, forKey: defaultName) }
    package override func set(_ value: Float, forKey defaultName: String) { set(NSNumber(value: value) as Any?, forKey: defaultName) }
    package override func set(_ value: Double, forKey defaultName: String) { set(NSNumber(value: value) as Any?, forKey: defaultName) }
    package override func set(_ url: URL?, forKey defaultName: String) { set(url?.absoluteString as Any?, forKey: defaultName) }

    package override func string(forKey defaultName: String) -> String? { store[defaultName] as? String }
    package override func array(forKey defaultName: String) -> [Any]? { store[defaultName] as? [Any] }
    package override func dictionary(forKey defaultName: String) -> [String: Any]? { store[defaultName] as? [String: Any] }
    package override func data(forKey defaultName: String) -> Data? { store[defaultName] as? Data }
    package override func stringArray(forKey defaultName: String) -> [String]? { store[defaultName] as? [String] }
    package override func integer(forKey defaultName: String) -> Int { (store[defaultName] as? NSNumber)?.intValue ?? Int((store[defaultName] as? String) ?? "") ?? 0 }
    package override func float(forKey defaultName: String) -> Float { (store[defaultName] as? NSNumber)?.floatValue ?? 0 }
    package override func double(forKey defaultName: String) -> Double { (store[defaultName] as? NSNumber)?.doubleValue ?? 0 }
    package override func bool(forKey defaultName: String) -> Bool {
        if let n = store[defaultName] as? NSNumber { return n.boolValue }
        if let s = store[defaultName] as? String { return ["yes", "true", "1"].contains(s.lowercased()) }
        return false
    }
    package override func dictionaryRepresentation() -> [String: Any] { store }
}
#endif
