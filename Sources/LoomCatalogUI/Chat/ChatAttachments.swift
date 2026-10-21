import Foundation
import LoomChat

/// An attachment that learns the host forgot its session (deleted through Loom): it stops writing the session's files.
@MainActor
protocol ChatHostedAttachment: AnyObject {
    func hostForgot()
}

/// An attachment that can say it is needed now (a view shows it, or its run lives): it is kept past the limit.
@MainActor
protocol ChatDriverAttachment: AnyObject {
    var isInUse: Bool { get }
}

/// What the app keeps per Chat driver while the host keeps the driver: the live chat's `LiveChatFeed` and the composer's
/// `ChatComposerModel`. It is UI state, so it lives here and not in the host; the host only says, through
/// `ChatSessionHost`'s `driverForgotten`, when a driver goes (`driverForgotten(_:)` is that hook's body).
///
/// Made by `make` on first use, then the same object, whichever card the driver's run is on (it follows a `/clear` with the
/// driver). The live chat keeps the session's presentation here, so it outlives the views that show it. Gone with
/// `driverForgotten(_:)`, with `releaseAttachment(for:)` once nothing uses it, or as the least recently used of more than
/// `limit` (one in use stays).
@MainActor
final class ChatAttachments {
    /// How many `ChatDriverAttachment`s are kept at most, besides those in use (`ChatDriverAttachment.isInUse`).
    static let limit = 4

    private struct Key: Hashable {
        let driver: ObjectIdentifier
        let type: ObjectIdentifier
    }

    /// By driver and by the type of the thing kept.
    private var held: [Key: (driver: ChatSessionDriver, value: AnyObject)] = [:]
    /// The `ChatDriverAttachment`s by last use, the newest last: past `limit`, the oldest one not in use goes. Other
    /// attachments (the composer's model, which holds an unsent draft) are not trimmed.
    private var order: [Key] = []

    func existingAttachment<T: AnyObject>(for driver: ChatSessionDriver) -> T? {
        guard let found = held[Key(driver: ObjectIdentifier(driver), type: ObjectIdentifier(T.self))],
              found.driver === driver else { return nil }
        return found.value as? T
    }

    func attachment<T: AnyObject>(for driver: ChatSessionDriver, make: () -> T) -> T {
        let key = Key(driver: ObjectIdentifier(driver), type: ObjectIdentifier(T.self))
        if let found = held[key], found.driver === driver, let value = found.value as? T {
            if value is ChatDriverAttachment { touch(key) }
            return value
        }
        let value = make()
        held[key] = (driver, value)
        if value is ChatDriverAttachment { touch(key) }
        trim()
        return value
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// The driver's trimmable attachments go unless they are in use; a view that shows the session again makes a new one.
    func releaseAttachment(for driver: ChatSessionDriver) {
        let id = ObjectIdentifier(driver)
        for key in order where key.driver == id {
            guard let found = held[key], found.driver === driver, !Self.isInUse(found.value) else { continue }
            drop(key)
        }
    }

    /// The drivers that have a trimmable attachment, the least recently used first (tests).
    var attachedDriverOrder: [ObjectIdentifier] {
        order.filter { held[$0] != nil }.map(\.driver)
    }

    /// Everything of one type kept for the drivers (Quit flushes the composers this way).
    func kept<T: AnyObject>(ofType type: T.Type) -> [T] {
        held.values.compactMap { $0.value as? T }
    }

    /// The host is dropping the driver: what it holds goes. What a session's composer still holds in memory is told first, so
    /// it never writes the deleted session's draft again.
    func driverForgotten(_ driver: ChatSessionDriver) {
        let id = ObjectIdentifier(driver)
        for key in Array(held.keys) where key.driver == id {
            (held[key]?.value as? ChatHostedAttachment)?.hostForgot()
            drop(key)
        }
    }

    private func trim() {
        var excess = order.count - Self.limit
        for key in order where excess > 0 {
            guard let found = held[key], !Self.isInUse(found.value) else { continue }
            drop(key)
            excess -= 1
        }
    }

    private func drop(_ key: Key) {
        held[key] = nil
        order.removeAll { $0 == key }
    }

    private static func isInUse(_ value: AnyObject) -> Bool { (value as? ChatDriverAttachment)?.isInUse ?? false }
}
