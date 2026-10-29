import Foundation

/// The build's products directory: the test bundle sits in it beside the executables the tests run (`loom-hook`,
/// `loom-fake-provider`, `loom-run-host`, `loom-test-child`, `loom-probe`). This target is linked into each test bundle, so
/// the bundle of a class here is the test bundle.
public enum Products {
    public static var directory: URL { Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent() }

    /// An executable of the build, by its product name.
    public static func executable(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private final class Anchor: NSObject {}
}
