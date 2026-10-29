import Foundation

/// App-owned identity for one managed child run. Native identity is observed
/// separately; the generation and all credentials remain run-local.
public struct ManagedTaskRun: Equatable, Sendable {
    public let taskID: UUID
    public let sessionID: UUID
    public let runID: UUID
    public let generation: UUID
    public let workingDirectory: String
    public let requestedChoices: HarnessLaunchChoices
    /// The app-selected `--session-id` for a fresh Claude launch, or a saved
    /// resume identity. This expectation is not a provider observation.
    public let expectedNativeSessionID: String?

    public init(taskID: UUID, sessionID: UUID, runID: UUID, generation: UUID,
                workingDirectory: String, requestedChoices: HarnessLaunchChoices,
                expectedNativeSessionID: String? = nil) {
        self.taskID = taskID; self.sessionID = sessionID; self.runID = runID; self.generation = generation
        self.workingDirectory = workingDirectory; self.requestedChoices = requestedChoices
        self.expectedNativeSessionID = expectedNativeSessionID
    }
}

/// Values actually reported by the provider; nil means unknown, not a default.
public struct ManagedTaskEffectiveSettings: Equatable, Sendable {
    public let model: String?
    public let effort: String?
    public let permissionMode: String?

    public init(model: String?, effort: String?, permissionMode: String?) {
        self.model = model; self.effort = effort; self.permissionMode = permissionMode
    }
}

/// The only text automatically sent to a managed child is a bounded pointer;
/// the task body is read through the scoped task command.
public struct ManagedTaskInput: Equatable, Sendable {
    public static let maximumBytes = 1_024
    public let taskID: UUID
    public let run: ManagedTaskRun
    public let roundID: UUID
    public let operationID: UUID
    /// Nil is reserved for the first input of a fresh, app-ID-pinned Claude
    /// pipe. Later inputs require the actually observed native binding.
    public let binding: SessionTaskBinding?
    public let clientMessageID: UUID
    public let pointer: String

    public init(run: ManagedTaskRun, roundID: UUID, operationID: UUID, binding: SessionTaskBinding?,
                clientMessageID: UUID, pointer: String) throws {
        guard !pointer.isEmpty, pointer.utf8.count <= Self.maximumBytes,
              pointer.utf8.allSatisfy({ (0x20...0x7e).contains($0) }),
              binding.map({ $0.sessionID == run.sessionID && $0.managedRunID == run.runID &&
                            $0.generation == run.generation }) ??
                  (run.expectedNativeSessionID.flatMap(UUID.init(uuidString:)) != nil) else {
            throw SessionTaskError.invalidPayload
        }
        self.taskID = run.taskID; self.run = run; self.roundID = roundID; self.operationID = operationID
        self.binding = binding; self.clientMessageID = clientMessageID; self.pointer = pointer
    }
}

/// A provider event correlated by the controller to the exact submitted input.
/// The execution reference describes its provenance; a client UUID is not a
/// fabricated provider-native turn ID.
public struct ManagedTaskInputObservation: Equatable, Sendable {
    public let input: ManagedTaskInput
    /// Observed native identity, never the unverified first-launch expectation.
    public let binding: SessionTaskBinding
    public let execution: SessionTaskExecutionReference

    public init(input: ManagedTaskInput, binding: SessionTaskBinding, execution: SessionTaskExecutionReference) throws {
        let run = input.run
        guard binding.sessionID == run.sessionID, binding.managedRunID == run.runID,
              binding.generation == run.generation, input.binding == nil || input.binding == binding,
              run.expectedNativeSessionID.map({ $0.caseInsensitiveCompare(binding.nativeSessionID) == .orderedSame }) ?? true else {
            throw SessionTaskError.staleBinding
        }
        self.input = input; self.binding = binding; self.execution = execution
    }
}

/// One live native request occurrence. `originalInput` is the exact bounded
/// tool input; it is held for this request, not logged or broadcast.
public struct ManagedTaskPermissionOccurrence: Equatable, Sendable, Identifiable {
    public static let maximumInputBytes = 16 * 1_024
    public let id: UUID
    public let binding: SessionTaskBinding
    public let taskID: UUID
    public let roundID: UUID
    public let operationID: UUID
    public let nativeRequestID: JSONValue
    public let request: ProviderPendingRequest
    public let originalInput: JSONValue

    public init(id: UUID, binding: SessionTaskBinding, taskID: UUID, roundID: UUID, operationID: UUID,
                nativeRequestID: JSONValue, request: ProviderPendingRequest, originalInput: JSONValue) throws {
        switch nativeRequestID {
        case let .string(value):
            guard !value.isEmpty, value.utf8.count <= 256, !value.utf8.contains(0) else { throw SessionTaskError.invalidPayload }
        case let .number(value):
            guard value.isFinite, value.rounded() == value else { throw SessionTaskError.invalidPayload }
        default: throw SessionTaskError.invalidPayload
        }
        guard let bytes = try? JSONEncoder().encode(originalInput), bytes.count <= Self.maximumInputBytes,
              !request.requestID.isEmpty, request.requestID.utf8.count <= 256,
              request.toolName.utf8.count <= 256, request.summary.utf8.count <= Self.maximumInputBytes,
              (request.note?.utf8.count ?? 0) <= Self.maximumInputBytes else { throw SessionTaskError.invalidPayload }
        self.id = id; self.binding = binding; self.taskID = taskID; self.roundID = roundID; self.operationID = operationID
        self.nativeRequestID = nativeRequestID; self.request = request; self.originalInput = originalInput
    }
}

/// User actions apply to one occurrence only. Allow uses the original tool
/// input and adds no permission rules. Answer is for a native question only.
public enum ManagedTaskUserDecision: Equatable, Sendable {
    case allow
    case deny
    /// Runtime/controller must bound the encoded answer and verify the native question shape.
    case answer(JSONValue)
}

/// Reloadable display data, not a task result or input-consumption proof.
public struct ManagedTaskProgress: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case message, tool, notice }
    public static let maximumTextBytes = 8 * 1_024
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) throws {
        guard text.utf8.count <= Self.maximumTextBytes, !text.utf8.contains(0) else { throw SessionTaskError.invalidPayload }
        self.kind = kind; self.text = text
    }
}

/// A selected managed child's transient presentation. The runtime, not the
/// view, owns the run and verifies every identity and request occurrence.
public struct ManagedTaskPresentation: Equatable, Sendable {
    public static let maximumProgressRows = 32
    public static let maximumProgressBytes = 64 * 1_024
    public static let maximumPermissions = 8

    public let run: ManagedTaskRun
    public let binding: SessionTaskBinding?
    public let effectiveSettings: ManagedTaskEffectiveSettings?
    public let status: SessionTaskNativeStatus
    public let progress: [ManagedTaskProgress]
    public let permissions: [ManagedTaskPermissionOccurrence]
    public let canTakeOver: Bool

    public init(run: ManagedTaskRun, binding: SessionTaskBinding?,
                effectiveSettings: ManagedTaskEffectiveSettings?, status: SessionTaskNativeStatus,
                progress: [ManagedTaskProgress], permissions: [ManagedTaskPermissionOccurrence],
                canTakeOver: Bool) throws {
        guard progress.count <= Self.maximumProgressRows,
              progress.reduce(0, { $0 + $1.text.utf8.count }) <= Self.maximumProgressBytes,
              permissions.count <= Self.maximumPermissions,
              Set(permissions.map(\.id)).count == permissions.count,
              [effectiveSettings?.model, effectiveSettings?.effort, effectiveSettings?.permissionMode].allSatisfy({
                  $0.map { !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) } ?? true
              }),
              binding.map({ actual in
                  actual.sessionID == run.sessionID && actual.managedRunID == run.runID &&
                  actual.generation == run.generation && !actual.nativeSessionID.isEmpty &&
                  actual.nativeSessionID.utf8.count <= 256 && !actual.nativeSessionID.utf8.contains(0) &&
                  (run.expectedNativeSessionID.map { $0.caseInsensitiveCompare(actual.nativeSessionID) == .orderedSame } ?? true)
              }) ?? true,
              permissions.allSatisfy({ $0.taskID == run.taskID && $0.binding == binding }),
              !canTakeOver || binding != nil else { throw SessionTaskError.invalidPayload }
        self.run = run; self.binding = binding; self.effectiveSettings = effectiveSettings
        self.status = status; self.progress = progress; self.permissions = permissions; self.canTakeOver = canTakeOver
    }
}

/// Every event is scoped to the factory's exact run and generation. The host
/// revalidates the binding and the corresponding operation before using it.
public struct ManagedTaskControllerEvent: Sendable {
    public enum Kind: Sendable {
        /// Native fields may be absent until reported; initialize alone is not identity proof.
        case initialized(nativeSessionID: String?, workingDirectory: String?, settings: ManagedTaskEffectiveSettings)
        case inputObserved(ManagedTaskInputObservation)
        case status(SessionTaskNativeStatus)
        case progress(ManagedTaskProgress)
        case permissionRequested(ManagedTaskPermissionOccurrence)
        case permissionResolved(UUID)
        /// A native turn end is not the child's explicit task report.
        case turnEnded(execution: SessionTaskExecutionReference?, failed: Bool)
        case ended
    }
    public let run: ManagedTaskRun
    public let kind: Kind

    public init(run: ManagedTaskRun, kind: Kind) { self.run = run; self.kind = kind }
}

/// Begin synchronously when stdout arrives, before it can wait in a buffer.
/// End only after its complete events have been awaited through `emit`; a
/// fragmented frame keeps its fence until the remaining bytes are processed.
/// Balance every begin on cancellation; invalidate on malformed/lost proof or
/// buffer overflow. The callbacks never grant authority to a caller's IDs.
public struct ManagedTaskIngress: Sendable {
    public let begin: @Sendable () -> Void
    public let end: @Sendable () -> Void
    public let invalidate: @Sendable () -> Void
    public let emit: @Sendable (ManagedTaskControllerEvent) async -> Void

    public init(begin: @escaping @Sendable () -> Void, end: @escaping @Sendable () -> Void,
                invalidate: @escaping @Sendable () -> Void,
                emit: @escaping @Sendable (ManagedTaskControllerEvent) async -> Void) {
        self.begin = begin; self.end = end; self.invalidate = invalidate; self.emit = emit
    }
}

/// A synchronous fence around the actual nonblocking write. Nil means no
/// syscall was admitted; the closure must not await or retain the write.
public typealias ManagedTaskWriteAdmission = @Sendable (@Sendable () throws -> Int) throws -> Int?

public enum ManagedTaskWriteOutcome: Equatable, Sendable {
    /// The frame was written. A separate native observation proves consumption.
    case submitted
    /// No byte was written; the operation may wait for another safe boundary.
    case deferred
    /// Bytes may have been written; never replay automatically.
    case unknown
}

/// Protocol state and I/O only: the existing SessionRuntime/ProcessSupervisor
/// creates, owns and stops the process. No view or terminal surface is retained.
public protocol ManagedTaskController: Sendable {
    /// Must exist before the supervisor spawns the pipe child.
    var outputSink: any PipeOutputSink { get }
    /// Attach exactly once to the owned run's pipe and initialize its protocol.
    func attach(pipe: PipeEndpoint) async throws
    /// The admission must surround the actual bounded nonblocking write, not a queue append.
    func submit(_ input: ManagedTaskInput, admission: @escaping ManagedTaskWriteAdmission) async -> ManagedTaskWriteOutcome
    /// Only an explicit user choice for the still-live occurrence may be sent.
    func respond(occurrenceID: UUID, decision: ManagedTaskUserDecision,
                 admission: @escaping ManagedTaskWriteAdmission) async -> ManagedTaskWriteOutcome
    /// Verified only after the exact execution is observed ended; a receipt is insufficient.
    func interrupt(_ target: SessionTaskRoundTarget, admission: @escaping ManagedTaskWriteAdmission) async -> SessionTaskEffect
    /// Release readers, writers and pending requests; process Stop belongs to the supervisor.
    func close() async
}

/// The app injects a Claude controller without introducing an upward Core→Chat dependency.
public typealias ManagedTaskControllerFactory = @Sendable (ManagedTaskRun, ManagedTaskIngress) throws -> any ManagedTaskController
