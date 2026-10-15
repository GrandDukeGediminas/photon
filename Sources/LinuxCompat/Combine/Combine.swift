// Linux stand-in for Combine (docs/linux-port.md §4): the part PhotonApp uses, so AppState and PlaylistController
// build unchanged. `ObservableObject` + `objectWillChange`, `@Published` (notifies the enclosing object before the value
// changes, as Combine does) and its projected publisher, which sends the current value on subscription and every new
// value before it is stored, with `map`, `filter`, `removeDuplicates`, `dropFirst`, `sink` and `AnyCancellable`.
// Everything runs synchronously on the caller's thread (the app model is main-thread only).

import Foundation

public final class AnyCancellable: Hashable {
    private var cancelAction: (() -> Void)?

    public init(_ cancel: @escaping () -> Void) { cancelAction = cancel }

    public func cancel() {
        cancelAction?()
        cancelAction = nil
    }

    deinit { cancel() }

    public func store(in set: inout Set<AnyCancellable>) { set.insert(self) }
    public func store(in array: inout [AnyCancellable]) { array.append(self) }

    public static func == (a: AnyCancellable, b: AnyCancellable) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

/// A value stream: `subscribe` registers a receiver and returns its cancellable.
public final class Publisher<Output> {
    private let subscribe: (@escaping (Output) -> Void) -> AnyCancellable

    public init(_ subscribe: @escaping (@escaping (Output) -> Void) -> AnyCancellable) { self.subscribe = subscribe }

    public func sink(receiveValue: @escaping (Output) -> Void) -> AnyCancellable { subscribe(receiveValue) }

    public func map<T>(_ transform: @escaping (Output) -> T) -> Publisher<T> {
        Publisher<T> { receive in self.subscribe { receive(transform($0)) } }
    }

    public func filter(_ include: @escaping (Output) -> Bool) -> Publisher<Output> {
        Publisher { receive in self.subscribe { if include($0) { receive($0) } } }
    }

    public func dropFirst(_ count: Int = 1) -> Publisher<Output> {
        Publisher { receive in
            var seen = 0
            return self.subscribe { v in
                if seen < count { seen += 1; return }
                receive(v)
            }
        }
    }

    public func removeDuplicates(by same: @escaping (Output, Output) -> Bool) -> Publisher<Output> {
        Publisher { receive in
            var last: Output?
            return self.subscribe { v in
                if let l = last, same(l, v) { return }
                last = v
                receive(v)
            }
        }
    }

    /// Delivery happens on the sender's thread; `receive(on:)` keeps the chain (the model is main-thread only).
    public func receive<S>(on _: S) -> Publisher<Output> { self }
}

extension Publisher where Output: Equatable {
    public func removeDuplicates() -> Publisher<Output> { removeDuplicates(by: ==) }
}

/// A list of receivers.
final class Subscribers<Value> {
    private var receivers: [(UInt64, (Value) -> Void)] = []
    private var next: UInt64 = 0

    func add(_ r: @escaping (Value) -> Void) -> AnyCancellable {
        next += 1
        let id = next
        receivers.append((id, r))
        return AnyCancellable { [weak self] in self?.receivers.removeAll { $0.0 == id } }
    }

    func send(_ v: Value) { for (_, r) in receivers { r(v) } }
}

/// `objectWillChange`: sent before any `@Published` property of the object changes.
public final class ObservableObjectPublisher {
    private let subscribers = Subscribers<Void>()
    public init() {}
    public func send() { subscribers.send(()) }
    public func sink(receiveValue: @escaping () -> Void) -> AnyCancellable { subscribers.add { receiveValue() } }
}

public protocol ObservableObject: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
}

/// One publisher per object, created on first use (Combine stores it in the object; a table keyed by identity here).
private final class PublisherTable {
    static let shared = PublisherTable()
    private var entries: [ObjectIdentifier: (object: Weak, publisher: ObservableObjectPublisher)] = [:]
    private let lock = NSLock()
    struct Weak { weak var value: AnyObject? }

    func publisher(for object: AnyObject) -> ObservableObjectPublisher {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(object)
        if let e = entries[key], e.object.value === object { return e.publisher }
        if entries.count > 64 { entries = entries.filter { $0.value.object.value != nil } }
        let p = ObservableObjectPublisher()
        entries[key] = (Weak(value: object), p)
        return p
    }
}

extension ObservableObject {
    public var objectWillChange: ObservableObjectPublisher { PublisherTable.shared.publisher(for: self) }
}

@propertyWrapper
public struct Published<Value> {
    final class Storage {
        var value: Value
        let subscribers = Subscribers<Value>()
        init(_ v: Value) { value = v }
    }

    let storage: Storage

    public init(wrappedValue: Value) { storage = Storage(wrappedValue) }
    public init(initialValue: Value) { storage = Storage(initialValue) }

    @available(*, unavailable, message: "@Published is only available on properties of classes")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() } // swiftlint:disable:this unused_setter_value
    }

    /// The current value on subscription, then every new value before it is stored (Combine's `Published.Publisher`).
    public var projectedValue: Publisher<Value> {
        let s = storage
        return Publisher { receive in
            receive(s.value)
            return s.subscribers.add(receive)
        }
    }

    public static subscript<EnclosingSelf: AnyObject>(
        _enclosingInstance object: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Published<Value>>
    ) -> Value {
        get { object[keyPath: storageKeyPath].storage.value }
        set {
            let s = object[keyPath: storageKeyPath].storage
            (object as? ObservableObject)?.objectWillChange.send()
            s.subscribers.send(newValue)
            s.value = newValue
        }
    }
}
