import Testing

/// The suites that host views or follow files share `ChatRenderProbe` and the session memory, so they run one at a time
/// (a nested suite takes its parent's `.serialized`). Each target that has such suites declares its own namespace: a suite
/// nested in another module's type would carry that module's name in its test id, out of its tier's filter.
// serialized: one ChatRenderProbe and one session memory per process
@Suite(.serialized, .timeLimit(.minutes(5)))
enum ChatHosted {}
