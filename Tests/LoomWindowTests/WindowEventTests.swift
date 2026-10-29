import Testing

/// Window tests that send key and mouse events share the app's key window and first responder, so they run one at a time
/// (Swift Testing runs separate suites in parallel). This target runs alone, after every other test target (`check.sh
/// --windows --idle`).
// serialized: one key window and one first responder for the whole target
@Suite(.serialized)
enum WindowEventTests {}
