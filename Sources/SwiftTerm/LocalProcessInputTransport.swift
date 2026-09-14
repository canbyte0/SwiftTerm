//
//  LocalProcessInputTransport.swift
//
//  Generic, shared input-transport authority for a LocalProcess PTY.
//
//  Every byte that enters the child's PTY (keyboard input, paste, acknowledged
//  writes, exclusive multi-write transactions) is serialized through this
//  single authority, so cross-source ordering is deterministic and verifiable.
//
//  This file is generic SwiftTerm infrastructure. It knows nothing about
//  bracketed paste, submit semantics, commands, agents, or approvals.
//
//  Frozen semantics:
//   - accepted-prefix accounting: accepted = requested - remaining reported by
//     the underlying write backend (never guessed, never "queued == accepted").
//     For a started physical write, the accepted prefix is derived ONLY from
//     that write's terminal backend settlement (done == true or errno != 0);
//     intermediate progress callbacks never settle anything.
//   - close barrier (explicit `closing` state): when the channel is about to
//     close, new writes are refused, queued-but-not-started operations fail
//     immediately (accepted = 0), and an in-flight write is retained until its
//     terminal backend callback (forced by the subsequent `io.close()`)
//     settles it exactly once. Close alone is never a settlement event for a
//     started write; late duplicate callbacks are ignored.
//   - transaction admission: from the admission point of the begin marker
//     (the `pending` phase) until the transaction terminates, ordinary input
//     is routed into one held FIFO and delivered after the transaction, in
//     admission order. No ordinary write can physically execute between two
//     writes of one transaction, including ordinary sends admitted while the
//     begin marker was still pending.
//   - process exit / channel close settle every pending continuation exactly
//     once with a generic transport error.
//   - lifetime design B: the in-flight write's backend handler retains the
//     transport until terminal settlement, so continuations are never leaked
//     even when the owning LocalProcess is released first; `io.close()`
//     guarantees the terminal callback.
//

#if !os(iOS) && !os(Windows)
import Foundation
import Dispatch
import Darwin

// MARK: - Public result / error model

/// Generic transport-level outcome for a Local PTY input write.
/// Deliberately free of any command/agent semantics; higher layers map these
/// to their own error models.
public enum LocalProcessInputTransportError: Error, Equatable {
    /// The child process is no longer running.
    case processUnavailable
    /// The physical write failed. The bytes accepted before the failure are
    /// carried by the accompanying result.
    case writeFailed (errno: Int32)
    /// The calling task was cancelled; no further writes were scheduled on its
    /// behalf. An already in-flight physical write is not rolled back.
    case cancelled
    /// The I/O channel (this PTY input incarnation) is closed or was replaced.
    case channelClosed
    /// Another exclusive transaction is already active (or the transaction is
    /// no longer usable).
    case transactionUnavailable
}

/// Exact accounting of one acknowledged write attempt.
public struct LocalProcessInputWriteResult: Equatable {
    /// Number of bytes the caller asked to write.
    public let requestedBytes: Int
    /// Number of bytes actually accepted, derived from the remaining-byte
    /// count reported by the underlying backend. Never assumed.
    public let acceptedBytes: Int
    /// nil when, and only when, all requested bytes were accepted.
    public let error: LocalProcessInputTransportError?

    public var succeeded: Bool { error == nil && acceptedBytes == requestedBytes }

    public init (requestedBytes: Int, acceptedBytes: Int, error: LocalProcessInputTransportError?)
    {
        self.requestedBytes = requestedBytes
        self.acceptedBytes = acceptedBytes
        self.error = error
    }
}

// MARK: - Physical write backend seam

/// The narrow seam between the transport scheduler and the physical write
/// primitive. Production uses the LocalProcess DispatchIO stream channel;
/// tests inject deterministic fakes to simulate short writes, errors,
/// progress callbacks and delayed completion.
protocol LocalProcessInputWriteBackend: AnyObject {
    /// Issue one physical stream write. The handler must be invoked
    /// asynchronously on `queue`, possibly multiple times; every invocation
    /// carries (done, the *remaining* unwritten data, errno). The final
    /// invocation has done == true with empty (or nil) remaining data, or a
    /// non-zero errno.
    func write (data: DispatchData, queue: DispatchQueue, handler: @escaping (Bool, DispatchData?, Int32) -> Void)
}

/// Production backend bound to the process's existing DispatchIO channel.
final class DispatchIOLocalProcessInputWriteBackend: LocalProcessInputWriteBackend {
    private let io: DispatchIO

    init (io: DispatchIO)
    {
        self.io = io
    }

    func write (data: DispatchData, queue: DispatchQueue, handler: @escaping (Bool, DispatchData?, Int32) -> Void)
    {
        io.write (offset: 0, data: data, queue: queue, ioHandler: handler)
    }
}

// MARK: - Channel incarnation

/// One PTY input incarnation. Its identity is this object's lifetime — never
/// the raw file descriptor number — so an fd reused by the OS for a later
/// process can never retarget an older transaction.
final class LocalProcessInputChannel {
    let backend: LocalProcessInputWriteBackend
    let generation: UInt64

    init (backend: LocalProcessInputWriteBackend, generation: UInt64)
    {
        self.backend = backend
        self.generation = generation
    }
}

// MARK: - Operations

final class InputWriteOp {
    let channel: LocalProcessInputChannel
    let requested: Int
    let data: DispatchData
    // Acknowledged writes resume this exactly once; fire-and-forget sends use
    // `fireAndForgetSettled` instead and surface no errors to callers.
    // Transaction writes attach their continuation here at enqueue time.
    var completion: ((LocalProcessInputWriteResult) -> Void)?
    let fireAndForgetSettled: ((_ acceptedBytes: Int, _ errno: Int32) -> Void)?
    // Remaining bytes as last reported by the backend; monotonically
    // non-increasing over the op's lifetime.
    var lastRemaining: Int
    var settled = false

    init (channel: LocalProcessInputChannel, data: DispatchData,
          completion: ((LocalProcessInputWriteResult) -> Void)? = nil,
          fireAndForgetSettled: ((_ acceptedBytes: Int, _ errno: Int32) -> Void)? = nil)
    {
        self.channel = channel
        self.data = data
        self.requested = data.count
        self.lastRemaining = data.count
        self.completion = completion
        self.fireAndForgetSettled = fireAndForgetSettled
    }
}

// MARK: - Exclusive transaction state

final class LocalProcessInputTransactionState {
    // Bound when the begin marker is processed: the channel incarnation this
    // transaction exclusively owns. Strong reference: the transaction keeps
    // the incarnation (and its I/O objects) alive for its duration.
    fileprivate(set) var channel: LocalProcessInputChannel?
    fileprivate(set) var ended = false
    fileprivate(set) var failReason: LocalProcessInputTransportError?
}

/// Opaque writer capability handed to the body of an exclusive transaction.
/// It can perform multiple ordered writes; ordinary input admitted while the
/// transaction is active cannot interleave with them.
public final class LocalProcessInputTransactionWriter {
    private let transport: LocalProcessInputTransport
    private let state: LocalProcessInputTransactionState

    fileprivate init (transport: LocalProcessInputTransport, state: LocalProcessInputTransactionState)
    {
        self.transport = transport
        self.state = state
    }

    /// Perform one ordered write inside the exclusive transaction.
    ///
    /// Returns the exact accepted-prefix accounting; it never throws for
    /// transport outcomes, so the caller can decide whether a follow-up
    /// (e.g. repair) write is appropriate. The transport itself never invents
    /// repair bytes and holds the transaction until the scope ends.
    ///
    /// - Parameter forceWhenCancelled: if the surrounding task has been
    ///   cancelled, writes normally refuse with `.cancelled`; an explicit
    ///   caller may pass true to request one more write (caller-controlled
    ///   repair). Cancellation never rolls back an already in-flight write.
    public func write (_ bytes: ArraySlice<UInt8>, forceWhenCancelled: Bool = false) async -> LocalProcessInputWriteResult
    {
        let requested = bytes.count
        if state.ended {
            return LocalProcessInputWriteResult (requestedBytes: requested, acceptedBytes: 0,
                                                 error: state.failReason ?? .transactionUnavailable)
        }
        if Task.isCancelled && !forceWhenCancelled {
            return LocalProcessInputWriteResult (requestedBytes: requested, acceptedBytes: 0, error: .cancelled)
        }
        let op = InputWriteOp (channel: state.channel ?? transport.anyChannelPlaceholder,
                               data: LocalProcessInputTransport.dispatchData (from: bytes))
        return await withCheckedContinuation { (continuation: CheckedContinuation<LocalProcessInputWriteResult, Never>) in
            transport.enqueueTransactionWrite (state: state, op: op, continuation: continuation)
        }
    }
}

// MARK: - Transport authority

/// Serial input-transport authority for one LocalProcess PTY.
///
/// Concurrency model: exactly one serialization mechanism — the private
/// `authorityQueue`. Every piece of mutable state below is confined to that
/// queue; public methods only enqueue blocks on it, so no other lock exists
/// and there is no path that synchronously waits on it (no deadlock with the
/// DispatchIO callback queue, process termination, or deinit).
public final class LocalProcessInputTransport: @unchecked Sendable {

    private let authorityQueue = DispatchQueue (label: "SwiftTerm.LocalProcessInputTransport")

    // All state below is confined to authorityQueue.
    private var currentChannel: LocalProcessInputChannel?
    private var channelClosed = false
    private var processAvailable = false
    private var channelGenerationCounter: UInt64 = 0

    private var mainFIFO: [Unit] = []
    // Ordinary-class units admitted while a transaction is pending or active;
    // released in admission order when the transaction terminates.
    private var heldFIFO: [Unit] = []
    // Transaction begin marker admitted but not yet activated (an earlier
    // physical write is still in flight). From this admission point on,
    // ordinary input must be ordered after this transaction.
    private var pendingTransaction: LocalProcessInputTransactionState?
    private var activeTransaction: LocalProcessInputTransactionState?
    private var inFlight: (op: InputWriteOp, channel: LocalProcessInputChannel)?
    // Explicit close state (`closing`): close requested but the close barrier
    // may still be draining an in-flight write.
    private var closeRequested = false

    /// Internal progress hook for the test suite (never set in production).
    /// Invoked on the authority queue with (requested, acceptedSoFar).
    var debugProgressHook: ((_ requested: Int, _ acceptedSoFar: Int) -> Void)?

    // MARK: Test observation (never used in production paths)

    /// Test-only observation of the exclusive-transaction admission phase:
    /// `.pending` spans the window between the admission point of the begin
    /// marker and its activation (an earlier physical write is in flight);
    /// `.active` spans the transaction itself.
    enum DebugTransactionPhase: Equatable {
        case none
        case pending
        case active
    }

    var debugTransactionPhase: DebugTransactionPhase {
        authorityQueue.sync {
            if activeTransaction != nil { return .active }
            if pendingTransaction != nil { return .pending }
            return .none
        }
    }

    /// Test-only observation of the explicit close state.
    var debugCloseRequested: Bool {
        authorityQueue.sync { closeRequested }
    }

    private enum Unit {
        case ordinary (InputWriteOp)
        case acknowledged (InputWriteOp)
        case begin (state: LocalProcessInputTransactionState,
                    continuation: CheckedContinuation<LocalProcessInputTransportError?, Never>)
        case transactionWrite (state: LocalProcessInputTransactionState, op: InputWriteOp)
        case end (state: LocalProcessInputTransactionState)
    }

    // MARK: Ordinary fire-and-forget input (keyboard/paste)

    /// Enqueue ordinary fire-and-forget input bytes. This is the shared path
    /// used by `LocalProcess.send(data:)`; its observable semantics stay
    /// fire-and-forget, but ordering with acknowledged writes and exclusive
    /// transactions is now deterministic.
    func enqueueOrdinarySend (_ bytes: ArraySlice<UInt8>, onSettled: ((_ acceptedBytes: Int, _ errno: Int32) -> Void)? = nil)
    {
        let data = Self.dispatchData (from: bytes)
        authorityQueue.async {
            guard let channel = self.currentChannel, !self.channelClosed else {
                onSettled? (0, 0)
                return
            }
            let op = InputWriteOp (channel: channel, data: data, fireAndForgetSettled: onSettled)
            if self.activeTransaction != nil || self.pendingTransaction != nil {
                self.heldFIFO.append (.ordinary (op))
            } else {
                self.mainFIFO.append (.ordinary (op))
                self._pump ()
            }
        }
    }

    // MARK: Acknowledged ordinary writes

    /// Generic acknowledged input primitive: bytes in, exact accepted-prefix
    /// accounting and outcome out.
    public func write (_ bytes: ArraySlice<UInt8>, completion: @escaping (LocalProcessInputWriteResult) -> Void)
    {
        let data = Self.dispatchData (from: bytes)
        authorityQueue.async {
            if self.channelClosed {
                completion (LocalProcessInputWriteResult (requestedBytes: data.count, acceptedBytes: 0, error: .channelClosed))
                return
            }
            guard let channel = self.currentChannel else {
                completion (LocalProcessInputWriteResult (requestedBytes: data.count, acceptedBytes: 0, error: .processUnavailable))
                return
            }
            let op = InputWriteOp (channel: channel, data: data, completion: completion)
            if self.activeTransaction != nil || self.pendingTransaction != nil {
                self.heldFIFO.append (.acknowledged (op))
            } else {
                self.mainFIFO.append (.acknowledged (op))
                self._pump ()
            }
        }
    }

    public func write (_ bytes: ArraySlice<UInt8>) async -> LocalProcessInputWriteResult
    {
        await withCheckedContinuation { continuation in
            self.write (bytes) { continuation.resume (returning: $0) }
        }
    }

    // MARK: Exclusive input transaction

    /// Acquire the exclusive input transaction for the duration of `body`.
    ///
    /// While the transaction is active, ordinary keyboard/paste sends are
    /// still accepted (they queue) but their bytes cannot enter the PTY
    /// between the transaction's writes. Ordinary input admitted *before* the
    /// acquisition is delivered first (admission order); input admitted during
    /// the transaction is delivered after it terminates. No interleaving.
    ///
    /// The transaction terminates when the body returns or throws, or
    /// deterministically on process exit / channel close (ordinary input is
    /// never permanently blocked). Only one transaction may exist or be
    /// pending; a second concurrent acquisition fails with
    /// `.transactionUnavailable`.
    public func withExclusiveInputTransaction<T> (_ body: (LocalProcessInputTransactionWriter) async throws -> T) async throws -> T
    {
        let state = LocalProcessInputTransactionState()
        let writer = LocalProcessInputTransactionWriter (transport: self, state: state)
        if let failure = await _acquire (state: state) {
            throw failure
        }
        defer { _release (state: state) }
        return try await body (writer)
    }

    private func _acquire (state: LocalProcessInputTransactionState) async -> LocalProcessInputTransportError?
    {
        await withCheckedContinuation { (continuation: CheckedContinuation<LocalProcessInputTransportError?, Never>) in
            authorityQueue.async {
                if self.activeTransaction != nil || self.pendingTransaction != nil {
                    // Only one pending or active exclusive transaction; a
                    // second acquisition never inserts another begin marker.
                    continuation.resume (returning: .transactionUnavailable)
                    return
                }
                // Admission point of the begin marker: from here until the
                // transaction terminates, ordinary input is held behind it —
                // even while an earlier physical write still occupies the
                // channel and the marker cannot activate yet.
                self.pendingTransaction = state
                self.mainFIFO.append (.begin (state: state, continuation: continuation))
                self._pump ()
            }
        }
    }

    private func _release (state: LocalProcessInputTransactionState)
    {
        authorityQueue.async {
            self.mainFIFO.append (.end (state: state))
            self._pump ()
        }
    }

    fileprivate func enqueueTransactionWrite (state: LocalProcessInputTransactionState, op: InputWriteOp,
                                              continuation: CheckedContinuation<LocalProcessInputWriteResult, Never>)
    {
        authorityQueue.async {
            let failure: LocalProcessInputTransportError?
            if self.channelClosed {
                failure = .channelClosed
            } else if state.ended {
                failure = state.failReason ?? .transactionUnavailable
            } else if !self.processAvailable {
                failure = .processUnavailable
            } else {
                failure = nil
            }
            if let failure {
                continuation.resume (returning: LocalProcessInputWriteResult (requestedBytes: op.requested,
                                                                              acceptedBytes: 0, error: failure))
                return
            }
            op.completion = { continuation.resume (returning: $0) }
            self.mainFIFO.append (.transactionWrite (state: state, op: op))
            self._pump ()
        }
    }

    // MARK: Lifecycle (invoked by LocalProcess)

    /// Adopt a new PTY input incarnation (called when the LocalProcess has
    /// created its DispatchIO channel). Any units still pending belong to a
    /// previous incarnation and are failed with `.channelClosed`.
    func adopt (io: DispatchIO)
    {
        adopt (backend: DispatchIOLocalProcessInputWriteBackend (io: io))
    }

    func adopt (backend: LocalProcessInputWriteBackend)
    {
        authorityQueue.async {
            self._failAllQueued (.channelClosed)
            self.channelGenerationCounter &+= 1
            self.currentChannel = LocalProcessInputChannel (backend: backend, generation: self.channelGenerationCounter)
            self.channelClosed = false
            self.closeRequested = false
            self.processAvailable = true
        }
    }

    /// The child process stopped running (exit, EOF, terminate). Future
    /// writes fail with `.processUnavailable`; an in-flight physical write is
    /// left to complete or fail naturally through the still-open channel and
    /// is reported exactly once.
    func processStopped ()
    {
        authorityQueue.async {
            self.processAvailable = false
            self._terminateActiveTransaction (.processUnavailable)
            self._failAllQueued (.processUnavailable)
        }
    }

    /// The I/O channel is about to close (terminate/deinit). This enters the
    /// explicit `closing` state and acts as the close barrier:
    ///  1. new ordinary/transaction writes are refused,
    ///  2. queued-but-not-started operations fail immediately with
    ///     `.channelClosed` (accepted = 0),
    ///  3. an already in-flight physical write is NOT settled here: it is
    ///     retained until its terminal backend callback — forced by the
    ///     subsequent `io.close()` — reports the exact final remaining/error
    ///     state, which settles the operation exactly once,
    ///  4. late duplicate callbacks are ignored via the settled flag.
    /// The accepted prefix is never fabricated from a non-terminal progress
    /// callback (lifetime design B keeps the transport alive until then).
    func channelWillClose ()
    {
        authorityQueue.async {
            self.closeRequested = true
            self.channelClosed = true
            self.pendingTransaction = nil
            self._terminateActiveTransaction (.channelClosed)
            self._failAllQueued (.channelClosed)
        }
    }

    // MARK: Scheduler (authority queue only)

    private func _pump ()
    {
        while inFlight == nil {
            guard !mainFIFO.isEmpty else { return }
            let unit = mainFIFO.removeFirst()
            _dispatch (unit)
        }
    }

    private func _dispatch (_ unit: Unit)
    {
        switch unit {
        case .ordinary (let op):
            if channelClosed || op.channel !== currentChannel || !processAvailable {
                // Incarnation gone; the fire-and-forget caller gets no error
                // (compatible with the previous silent-drop behavior).
                _settle (op, accepted: 0, error: nil)
                return
            }
            _startWrite (op)

        case .acknowledged (let op):
            if channelClosed || op.channel !== currentChannel {
                _settle (op, accepted: 0, error: .channelClosed)
                return
            }
            if !processAvailable {
                _settle (op, accepted: 0, error: .processUnavailable)
                return
            }
            _startWrite (op)

        case .begin (let state, let continuation):
            if pendingTransaction === state {
                pendingTransaction = nil
            }
            if channelClosed {
                continuation.resume (returning: .channelClosed)
            } else if !processAvailable {
                continuation.resume (returning: .processUnavailable)
            } else if activeTransaction != nil {
                // Defensive: enqueue-time check already prevents this.
                continuation.resume (returning: .transactionUnavailable)
            } else {
                state.channel = currentChannel
                activeTransaction = state
                continuation.resume (returning: nil)
            }

        case .transactionWrite (let state, let op):
            if channelClosed || state.channel !== currentChannel {
                _settle (op, accepted: 0, error: .channelClosed)
                return
            }
            if state.ended {
                _settle (op, accepted: 0, error: state.failReason ?? .transactionUnavailable)
                return
            }
            if !processAvailable {
                _settle (op, accepted: 0, error: .processUnavailable)
                return
            }
            _startWrite (op)

        case .end (let state):
            _finishTransaction (state)
        }
    }

    private func _finishTransaction (_ state: LocalProcessInputTransactionState)
    {
        guard activeTransaction === state else { return } // already auto-terminated
        if pendingTransaction === state {
            pendingTransaction = nil // defensive; begin already dispatched
        }
        activeTransaction = nil
        state.ended = true
        if !heldFIFO.isEmpty {
            // Held ordinary units keep their relative admission order; they
            // are prepended ahead of anything queued after the end marker.
            mainFIFO = heldFIFO + mainFIFO
            heldFIFO.removeAll (keepingCapacity: true)
        }
    }

    private func _terminateActiveTransaction (_ reason: LocalProcessInputTransportError)
    {
        if let tx = activeTransaction {
            activeTransaction = nil
            tx.ended = true
            tx.failReason = reason
        }
    }

    private func _startWrite (_ op: InputWriteOp)
    {
        inFlight = (op, op.channel)
        // Strong capture (lifetime design B): the transport must outlive the
        // physical write so the backend's terminal callback can settle the
        // continuation exactly once with the exact final remaining state —
        // even when the owning LocalProcess (and thus the transport's last
        // external reference) is released while the write is in flight.
        // `io.close()` guarantees a terminal callback, so this reference is
        // always released in supported lifecycles.
        op.channel.backend.write (data: op.data, queue: authorityQueue) { [self] done, remaining, errno in
            self._handleProgress (op: op, done: done, remaining: remaining, errno: errno)
        }
    }

    private func _handleProgress (op: InputWriteOp, done: Bool, remaining: DispatchData?, errno: Int32)
    {
        guard !op.settled else { return } // exactly-once settlement
        let remainingCount = remaining?.count ?? 0
        if remainingCount > op.lastRemaining {
            // Backend protocol violation; settle conservatively using the
            // last known-good remaining count so bytes are never double
            // counted.
            inFlight = nil
            _settle (op, accepted: op.requested - op.lastRemaining,
                     error: .writeFailed (errno: errno != 0 ? errno : EINVAL))
            _pump ()
            return
        }
        op.lastRemaining = remainingCount
        let accepted = op.requested - remainingCount
        debugProgressHook? (op.requested, accepted)
        if done || errno != 0 {
            inFlight = nil
            let error: LocalProcessInputTransportError?
            if errno != 0 {
                error = .writeFailed (errno: errno)
            } else if remainingCount > 0 {
                // Final call still reporting unwritten bytes: conservative
                // generic failure, exact prefix preserved.
                error = .writeFailed (errno: EIO)
            } else {
                error = nil
            }
            _settle (op, accepted: accepted, error: error)
            _pump ()
        }
    }

    private func _settle (_ op: InputWriteOp, accepted: Int, error: LocalProcessInputTransportError?)
    {
        op.settled = true
        let result = LocalProcessInputWriteResult (requestedBytes: op.requested, acceptedBytes: accepted, error: error)
        if let completion = op.completion {
            completion (result)
        } else {
            op.fireAndForgetSettled? (accepted, Self.errnoValue (of: error))
        }
    }

    private func _failAllQueued (_ error: LocalProcessInputTransportError)
    {
        let all = heldFIFO + mainFIFO
        heldFIFO.removeAll (keepingCapacity: true)
        mainFIFO.removeAll (keepingCapacity: true)
        for unit in all {
            switch unit {
            case .ordinary (let op):
                _settle (op, accepted: 0, error: nil)
            case .acknowledged (let op), .transactionWrite (_, let op):
                _settle (op, accepted: 0, error: error)
            case .begin (let state, let continuation):
                if pendingTransaction === state {
                    pendingTransaction = nil
                }
                continuation.resume (returning: error)
            case .end:
                break
            }
        }
    }

    // MARK: Helpers

    /// Placeholder used only when a transaction writer is created before its
    /// begin marker ran; the op is always re-validated against the bound
    /// transaction state at dispatch time.
    fileprivate var anyChannelPlaceholder: LocalProcessInputChannel {
        // Only reached for writes issued after the transaction already ended
        // (checked first in `write`), so this never participates in a real
        // dispatch; supply the current channel when available.
        currentChannel ?? LocalProcessInputChannel (backend: NullLocalProcessInputWriteBackend(), generation: 0)
    }

    static func dispatchData (from bytes: ArraySlice<UInt8>) -> DispatchData
    {
        bytes.withUnsafeBytes { DispatchData (bytes: $0) }
    }

    static func errnoValue (of error: LocalProcessInputTransportError?) -> Int32
    {
        if case .writeFailed (let errno) = error { return errno }
        return 0
    }
}

/// Backend used only for the (unreachable) empty placeholder channel above.
final class NullLocalProcessInputWriteBackend: LocalProcessInputWriteBackend {
    func write (data: DispatchData, queue: DispatchQueue, handler: @escaping (Bool, DispatchData?, Int32) -> Void)
    {
        queue.async { handler (true, data, EIO) }
    }
}
#endif
