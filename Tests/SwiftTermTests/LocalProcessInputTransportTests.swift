//
//  LocalProcessInputTransportTests.swift
//
//  Deterministic tests for the shared Local PTY input transport authority:
//  exact accepted-prefix accounting, ordered writes, exclusive multi-write
//  transactions, one-incarnation binding, and lifecycle settlement.
//
//  No test contains real credentials, hosts, keys, or API secrets; all byte
//  fixtures are harmless local constants.
//

#if !os(iOS) && !os(Windows)
import XCTest
@testable import SwiftTerm

// MARK: - Test support

/// Thread-safe single-value box (avoids mutating captured vars in
/// @Sendable task closures).
final class Box<T> {
    private let lock = NSLock()
    private var storage: T?
    func set (_ value: T?)
    {
        lock.lock(); storage = value; lock.unlock()
    }
    var value: T? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

extension DispatchData {
    func toArrayOfBytes () -> [UInt8]
    {
        var result = [UInt8] (repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { ptr in
            _ = copyBytes (to: ptr)
        }
        return result
    }
}

// MARK: - Deterministic fake backend

/// Simulates DispatchIO stream-write behavior with controllable completion:
/// full acceptance, short writes with progress callbacks, 0/N-byte prefix
/// errors, and delayed completion. Handler invocations are always delivered
/// asynchronously on the queue passed by the transport (like real DispatchIO).
final class FakeInputBackend: LocalProcessInputWriteBackend {
    private final class Pending {
        let bytes: [UInt8]
        let queue: DispatchQueue
        let handler: (Bool, DispatchData?, Int32) -> Void
        init (bytes: [UInt8], queue: DispatchQueue, handler: @escaping (Bool, DispatchData?, Int32) -> Void)
        {
            self.bytes = bytes
            self.queue = queue
            self.handler = handler
        }
    }

    let label: String
    private let lock = NSLock()
    private var writtenStorage: [[UInt8]] = []
    private var pendingStorage: [Pending] = []

    /// When true (default) each write completes fully on the next queue hop.
    /// When false the test drives completion explicitly via deliver(...).
    var autoComplete = true
    /// errno delivered by auto completion (0 = success).
    var autoCompleteErrno: Int32 = 0

    init (label: String)
    {
        self.label = label
    }

    var written: [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        return writtenStorage
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingStorage.count
    }

    func write (data: DispatchData, queue: DispatchQueue, handler: @escaping (Bool, DispatchData?, Int32) -> Void)
    {
        let bytes = data.toArrayOfBytes()
        lock.lock()
        writtenStorage.append (bytes)
        let pending = Pending (bytes: bytes, queue: queue, handler: handler)
        pendingStorage.append (pending)
        let index = pendingStorage.count - 1
        let autoComplete = self.autoComplete
        let errno = self.autoCompleteErrno
        lock.unlock()

        if autoComplete {
            queue.async { [weak self] in
                self?.deliver (index: index, remainingByteCount: 0, errno: errno)
            }
        }
    }

    /// Deliver one handler invocation: `remainingByteCount` bytes of the
    /// original payload are still unwritten. remaining == 0 or errno != 0 is
    /// terminal for the transport.
    func deliver (index: Int, remainingByteCount: Int, errno: Int32)
    {
        lock.lock()
        let pending = pendingStorage[index]
        lock.unlock()
        let remaining = Array (pending.bytes.suffix (remainingByteCount))
        let dd = remaining.withUnsafeBytes { DispatchData (bytes: $0) }
        let done = remainingByteCount == 0
        pending.queue.async {
            pending.handler (done, done ? nil : dd, errno)
        }
    }
}

// MARK: - Tests

final class LocalProcessInputTransportTests: XCTestCase {

    // MARK: Helpers

    private func waitUntil (timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async -> Bool
    {
        let deadline = Date().addingTimeInterval (timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep (nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func makeTransport (_ backend: FakeInputBackend) -> LocalProcessInputTransport
    {
        let transport = LocalProcessInputTransport()
        transport.adopt (backend: backend)
        return transport
    }

    private func bytes (_ string: String) -> ArraySlice<UInt8>
    {
        Array (string.utf8) [...]
    }

    // MARK: Accepted-prefix accounting

    func testFullAcceptanceExactPrefix () async
    {
        let backend = FakeInputBackend (label: "full")
        let transport = makeTransport (backend)
        let result = await transport.write (bytes ("hello"))
        XCTAssertTrue (result.succeeded)
        XCTAssertEqual (result.requestedBytes, 5)
        XCTAssertEqual (result.acceptedBytes, 5)
        XCTAssertNil (result.error)
        XCTAssertEqual (backend.written.first, Array ("hello".utf8))
    }

    func testZeroAcceptedPlusError () async throws
    {
        let backend = FakeInputBackend (label: "zero")
        backend.autoComplete = false
        let transport = makeTransport (backend)
        let resultBox = Box<LocalProcessInputWriteResult>()
        let task = Task { await transport.write (bytes ("abc")) }
        _ = await waitUntil { backend.pendingCount == 1 }
        backend.deliver (index: 0, remainingByteCount: 3, errno: Int32(EIO))
        resultBox.set (await task.value)
        let result = try XCTUnwrap (resultBox.value)
        XCTAssertEqual (result.requestedBytes, 3)
        XCTAssertEqual (result.acceptedBytes, 0)
        XCTAssertEqual (result.error, .writeFailed (errno: Int32(EIO)))
        XCTAssertFalse (result.succeeded)
    }

    func testPositivePrefixPlusError () async throws
    {
        let backend = FakeInputBackend (label: "prefix")
        backend.autoComplete = false
        let transport = makeTransport (backend)
        let task = Task { await transport.write (bytes ("abcd")) }
        _ = await waitUntil { backend.pendingCount == 1 }
        // 1 byte accepted (progress), then the write fails with 3 remaining.
        backend.deliver (index: 0, remainingByteCount: 3, errno: 0)
        backend.deliver (index: 0, remainingByteCount: 3, errno: Int32(EIO))
        let result = await task.value
        XCTAssertEqual (result.requestedBytes, 4)
        XCTAssertEqual (result.acceptedBytes, 1)
        XCTAssertEqual (result.error, .writeFailed (errno: Int32(EIO)))
    }

    func testProgressCallbacksMonotonicNoDoubleCount () async throws
    {
        let backend = FakeInputBackend (label: "progress")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let observed = Box<[(requested: Int, accepted: Int)]>()
        observed.set ([])
        transport.debugProgressHook = { requested, accepted in
            observed.set ((observed.value ?? []) + [(requested, accepted)])
        }

        let task = Task { await transport.write (bytes ("0123456789")) } // 10 bytes
        _ = await waitUntil { backend.pendingCount == 1 }
        backend.deliver (index: 0, remainingByteCount: 6, errno: 0)  // 4 accepted
        backend.deliver (index: 0, remainingByteCount: 6, errno: 0)  // duplicate: no double count
        backend.deliver (index: 0, remainingByteCount: 3, errno: 0)  // 7 accepted
        backend.deliver (index: 0, remainingByteCount: 0, errno: 0)  // done
        let result = await task.value

        XCTAssertEqual (result.acceptedBytes, 10)
        XCTAssertNil (result.error)
        let pairs = (observed.value ?? []).filter { $0.requested == 10 }
        // Monotonic non-increasing remaining == monotonic non-decreasing
        // accepted; duplicates never double count.
        XCTAssertEqual (pairs.map { $0.accepted }, [4, 4, 7, 10])
    }

    func testDelayedCompletionSettlesExactlyOnce () async throws
    {
        let backend = FakeInputBackend (label: "delayed")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let hookCount = Box<Int>()
        hookCount.set (0)
        transport.debugProgressHook = { _, _ in
            hookCount.set ((hookCount.value ?? 0) + 1)
        }

        let task = Task { await transport.write (bytes ("xy")) }
        _ = await waitUntil { backend.pendingCount == 1 }
        backend.deliver (index: 0, remainingByteCount: 0, errno: 0)
        let result = await task.value
        XCTAssertTrue (result.succeeded)
        // A late duplicate handler invocation must not settle again.
        backend.deliver (index: 0, remainingByteCount: 0, errno: 0)
        try? await Task.sleep (nanoseconds: 50_000_000)
        XCTAssertEqual (hookCount.value, 1)
    }

    // MARK: Ordering

    func testOrderingOrdinaryThenTransactionThenOrdinary () async throws
    {
        let backend = FakeInputBackend (label: "order1")
        let transport = makeTransport (backend)

        _ = await transport.write (bytes ("A"))
        try await transport.withExclusiveInputTransaction { writer in
            _ = await writer.write (bytes ("B"))
            _ = await writer.write (bytes ("C"))
        }
        _ = await transport.write (bytes ("D"))

        let flat = backend.written.flatMap { $0 }
        XCTAssertEqual (String (bytes: flat, encoding: .utf8), "ABCD")
    }

    func testOrdinaryQueuedDuringTransactionDoesNotInterleave () async throws
    {
        let backend = FakeInputBackend (label: "order2")
        let transport = makeTransport (backend)

        let ordinaryBox = Box<Task<LocalProcessInputWriteResult, Never>>()
        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                _ = await writer.write (bytes ("B1"))
                // Admitted while the transaction is active: must be held.
                ordinaryBox.set (Task { await transport.write (bytes ("U")) })
                _ = await writer.write (bytes ("B2"))
            }
        }
        try await transactionTask.get()
        let ordinaryResult = await ordinaryBox.value!.value
        XCTAssertTrue (ordinaryResult.succeeded)

        // Transaction writes stay contiguous; the ordinary send lands only
        // after the transaction terminates.
        let flat = backend.written.flatMap { $0 }
        XCTAssertEqual (String (bytes: flat, encoding: .utf8), "B1B2U")
    }

    func testNoInterleavingAdmissionOrder () async throws
    {
        // A ordinary, transaction B C, ordinary D — exactly §22.
        let backend = FakeInputBackend (label: "order3")
        let transport = makeTransport (backend)

        _ = await transport.write (bytes ("A"))

        let dBox = Box<Task<LocalProcessInputWriteResult, Never>>()
        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                _ = await writer.write (bytes ("B"))
                // Admitted while the transaction is active: held until it ends.
                dBox.set (Task { await transport.write (bytes ("D")) })
                _ = await writer.write (bytes ("C"))
            }
        }
        try await transactionTask.get()
        let dResult = await dBox.value!.value
        XCTAssertTrue (dResult.succeeded)

        let flat = backend.written.flatMap { $0 }
        XCTAssertEqual (String (bytes: flat, encoding: .utf8), "ABCD")
    }

    // MARK: Exclusive acquisition

    func testSecondTransactionAcquisitionFails () async throws
    {
        let backend = FakeInputBackend (label: "exclusive")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let errorBox = Box<LocalProcessInputTransportError>()
        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                let w = Task { await writer.write (bytes ("1")) }
                _ = await waitUntil { backend.pendingCount == 1 }
                // Second acquisition attempt while the first is active.
                do {
                    try await transport.withExclusiveInputTransaction { _ -> Void in }
                } catch let error as LocalProcessInputTransportError {
                    errorBox.set (error)
                }
                backend.deliver (index: 0, remainingByteCount: 0, errno: 0)
                _ = await w.value
            }
        }
        try await transactionTask.get()
        XCTAssertEqual (errorBox.value, .transactionUnavailable)
        XCTAssertEqual (backend.written.count, 1)
    }

    // MARK: Cancellation

    func testCancellationPreventsFutureWritesButInFlightCompletes () async throws
    {
        let backend = FakeInputBackend (label: "cancel")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let r1Box = Box<LocalProcessInputWriteResult>()
        let r2Box = Box<LocalProcessInputWriteResult>()
        let r3Box = Box<LocalProcessInputWriteResult>()
        let cancelledFlag = Box<Bool>()

        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                let w1 = Task { await writer.write (bytes ("ONE")) }
                _ = await waitUntil { backend.pendingCount == 1 }
                // Cancel the transaction's task while write 1 is in flight.
                // The in-flight write is NOT rolled back.
                withUnsafeCurrentTask { $0?.cancel() }
                cancelledFlag.set (true)
                r1Box.set (await w1.value)
                r2Box.set (await writer.write (bytes ("TWO")))                          // refused
                r3Box.set (await writer.write (bytes ("R"), forceWhenCancelled: true)) // explicit repair
            }
        }
        _ = await waitUntil { backend.pendingCount == 1 }
        _ = await waitUntil { cancelledFlag.value == true }
        // Settle the in-flight write: it completes normally despite the task
        // cancellation (no rollback).
        backend.deliver (index: 0, remainingByteCount: 0, errno: 0)
        // The repair write reaches the backend; settle it too.
        _ = await waitUntil { backend.pendingCount == 2 }
        backend.deliver (index: 1, remainingByteCount: 0, errno: 0)
        try await transactionTask.get()

        XCTAssertEqual (r1Box.value?.succeeded, true)
        XCTAssertEqual (r1Box.value?.acceptedBytes, 3)
        XCTAssertEqual (r2Box.value?.error, .cancelled)
        XCTAssertEqual (r2Box.value?.acceptedBytes, 0)
        XCTAssertEqual (r3Box.value?.succeeded, true)

        let flat = backend.written.flatMap { $0 }
        XCTAssertEqual (String (bytes: flat, encoding: .utf8), "ONER")
    }

    // MARK: Lifecycle: channel close / process exit

    func testChannelCloseSettlesPendingExactlyOnceAndUnblocksOrdinary () async throws
    {
        let backend1 = FakeInputBackend (label: "close-1")
        backend1.autoComplete = false
        let transport = makeTransport (backend1)

        let wBox = Box<Task<LocalProcessInputWriteResult, Never>>()
        let heldBox = Box<Task<LocalProcessInputWriteResult, Never>>()
        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                wBox.set (Task { await writer.write (bytes ("W1")) })
                heldBox.set (Task { await transport.write (bytes ("H")) })
                _ = await waitUntil { backend1.pendingCount == 1 }
                // Channel closes while the transaction owns the writer.
                transport.channelWillClose ()
            }
        }
        try await transactionTask.get()

        // The held queued unit failed immediately at close time...
        let heldResult = await heldBox.value!.value
        XCTAssertEqual (heldResult.error, .channelClosed)
        XCTAssertEqual (heldResult.acceptedBytes, 0)
        XCTAssertEqual (backend1.written.count, 1) // nothing extra was written

        // ...while the in-flight write stayed pending across the close until
        // its terminal backend callback (forced by io.close() in production)
        // settled it exactly once with the exact final remaining state.
        backend1.deliver (index: 0, remainingByteCount: 1, errno: Int32(EIO))
        let inFlightResult = await wBox.value!.value
        XCTAssertEqual (inFlightResult.requestedBytes, 2)
        XCTAssertEqual (inFlightResult.acceptedBytes, 1)
        XCTAssertEqual (inFlightResult.error, .writeFailed (errno: Int32(EIO)))

        // A late duplicate backend completion must not double-settle.
        backend1.deliver (index: 0, remainingByteCount: 0, errno: 0)
        try? await Task.sleep (nanoseconds: 50_000_000)

        // Ordinary input is not permanently blocked: adopt a new incarnation
        // and a fresh transaction can be acquired and used.
        let backend2 = FakeInputBackend (label: "close-2")
        transport.adopt (backend: backend2)
        let result = await transport.write (bytes ("after"))
        XCTAssertTrue (result.succeeded)
        try await transport.withExclusiveInputTransaction { writer in
            let r = await writer.write (bytes ("tx"))
            XCTAssertTrue (r.succeeded)
        }
        XCTAssertEqual (backend2.written.flatMap { $0 }, Array ("aftertx".utf8))
    }

    func testProcessExitFailsTransactionWritesAndQueuedUnits () async throws
    {
        let backend = FakeInputBackend (label: "exit")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let wBox = Box<Task<LocalProcessInputWriteResult, Never>>()
        let qBox = Box<Task<LocalProcessInputWriteResult, Never>>()
        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                wBox.set (Task { await writer.write (bytes ("T")) })
                qBox.set (Task { await transport.write (bytes ("Q")) })
                _ = await waitUntil { backend.pendingCount == 1 }
                transport.processStopped ()
            }
        }
        try await transactionTask.get()

        // The queued unit was failed at stop time...
        let queuedResult = await qBox.value!.value
        XCTAssertEqual (queuedResult.error, .processUnavailable)
        // ...while the in-flight write settles naturally through the
        // still-open channel (here forced by the fake with an error).
        backend.deliver (index: 0, remainingByteCount: 0, errno: Int32(EIO))
        let writeResult = await wBox.value!.value
        XCTAssertEqual (writeResult.error, .writeFailed (errno: Int32(EIO)))

        // Future writes fail; no attempt is made to find a replacement.
        let after = await transport.write (bytes ("X"))
        XCTAssertEqual (after.error, .processUnavailable)
    }

    func testInFlightWriteCompletesNaturallyAfterProcessStop () async throws
    {
        // While the channel is still open, an in-flight physical write at
        // process-stop time is not rolled back: it settles naturally through
        // the channel and reports its exact accepted prefix.
        let backend = FakeInputBackend (label: "stop-inflight")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let task = Task { await transport.write (bytes ("abcd")) }
        _ = await waitUntil { backend.pendingCount == 1 }
        backend.deliver (index: 0, remainingByteCount: 2, errno: 0) // 2 accepted, still in flight
        transport.processStopped ()
        backend.deliver (index: 0, remainingByteCount: 0, errno: 0) // natural completion
        let result = await task.value
        XCTAssertEqual (result.acceptedBytes, 4)
        XCTAssertNil (result.error)
    }

    func testInFlightWriteReportsExactPrefixOnChannelClose () async throws
    {
        // Channel close while a physical write is in flight: close alone is
        // NOT a settlement event. The continuation stays pending until the
        // write's terminal backend callback, which carries the exact final
        // remaining/error state.
        let backend = FakeInputBackend (label: "close-inflight")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let resultBox = Box<LocalProcessInputWriteResult>()
        let task = Task {
            let r = await transport.write (bytes ("abcd"))
            resultBox.set (r)
            return r
        }
        _ = await waitUntil { backend.pendingCount == 1 }
        backend.deliver (index: 0, remainingByteCount: 2, errno: 0) // 2 accepted
        transport.channelWillClose ()
        // Close must not settle the in-flight write from the last-observed
        // progress state.
        try await Task.sleep (nanoseconds: 50_000_000)
        XCTAssertNil (resultBox.value, "close alone must not settle an in-flight write")

        // Terminal callback: 1 byte remains, write failed with EIO.
        backend.deliver (index: 0, remainingByteCount: 1, errno: Int32(EIO))
        let result = await task.value
        XCTAssertEqual (result.requestedBytes, 4)
        XCTAssertEqual (result.acceptedBytes, 3)
        XCTAssertEqual (result.error, .writeFailed (errno: Int32(EIO)))
    }

    // MARK: R1 — close barrier: exact terminal settlement

    func testCloseBarrierSettlesOnlyOnTerminalCallbackWithFinalRemaining () async throws
    {
        // §11 deterministic seam: callback1 remaining=9, close requested,
        // callback2 remaining=4, terminal remaining=2 errno=EIO.
        // Final: accepted = requested - 2, error = writeFailed(EIO).
        let backend = FakeInputBackend (label: "r1-barrier")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let hookCount = Box<Int>()
        hookCount.set (0)
        transport.debugProgressHook = { _, _ in
            hookCount.set ((hookCount.value ?? 0) + 1)
        }

        let resultBox = Box<LocalProcessInputWriteResult>()
        let task = Task {
            let r = await transport.write (bytes ("0123456789")) // 10 bytes
            resultBox.set (r)
            return r
        }
        _ = await waitUntil { backend.pendingCount == 1 }

        backend.deliver (index: 0, remainingByteCount: 9, errno: 0)  // callback 1 (1 accepted)
        transport.channelWillClose ()                                // close requested
        backend.deliver (index: 0, remainingByteCount: 4, errno: 0)  // callback 2 (6 accepted)

        // Neither close nor a non-terminal progress callback may settle the
        // in-flight write.
        try await Task.sleep (nanoseconds: 50_000_000)
        XCTAssertNil (resultBox.value, "in-flight write must stay pending across close")

        backend.deliver (index: 0, remainingByteCount: 2, errno: Int32(EIO)) // terminal
        let result = await task.value
        XCTAssertEqual (result.requestedBytes, 10)
        XCTAssertEqual (result.acceptedBytes, 8) // requested - final remaining (2)
        XCTAssertEqual (result.error, .writeFailed (errno: Int32(EIO)))
        XCTAssertFalse (result.acceptedBytes == 1, "must not report the callback-1 prefix")
        XCTAssertFalse (result.acceptedBytes == 6, "must not report the callback-2 prefix")

        // Late duplicate terminal callback: ignored, no double resume, no
        // extra progress accounting.
        backend.deliver (index: 0, remainingByteCount: 0, errno: 0)
        try await Task.sleep (nanoseconds: 50_000_000)
        XCTAssertEqual (hookCount.value, 3, "late duplicate callback must be ignored")
    }

    func testCloseBarrierFullSuccessTerminalState () async throws
    {
        // §6 case: the terminal backend callback after close reports full
        // acceptance (the write completed before the channel actually
        // closed); the exact result is success, never downgraded.
        let backend = FakeInputBackend (label: "r1-success")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let task = Task { await transport.write (bytes ("abcd")) }
        _ = await waitUntil { backend.pendingCount == 1 }
        backend.deliver (index: 0, remainingByteCount: 1, errno: 0) // 3 accepted, in flight
        transport.channelWillClose ()
        backend.deliver (index: 0, remainingByteCount: 0, errno: 0) // terminal: full
        let result = await task.value
        XCTAssertEqual (result.acceptedBytes, 4)
        XCTAssertNil (result.error)
        XCTAssertTrue (result.succeeded)
    }

    func testQueuedWriteFailsImmediatelyOnCloseZeroAccepted () async throws
    {
        // §13: queued-but-not-started writes fail immediately with
        // accepted = 0; the in-flight write is a different case and stays
        // pending until its terminal callback.
        let backend = FakeInputBackend (label: "r1-queued")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let inflightBox = Box<LocalProcessInputWriteResult>()
        let inflightTask = Task {
            let r = await transport.write (bytes ("WW"))
            inflightBox.set (r)
            return r
        }
        _ = await waitUntil { backend.pendingCount == 1 }
        backend.deliver (index: 0, remainingByteCount: 1, errno: 0) // 1 accepted, still in flight

        let queuedBox = Box<LocalProcessInputWriteResult>()
        let queuedTask = Task {
            let r = await transport.write (bytes ("Q"))
            queuedBox.set (r)
            return r
        }
        // Q is admitted behind the in-flight WW write and must not start.

        let ordinarySettled = Box<[(accepted: Int, errno: Int32)]>()
        ordinarySettled.set ([])
        transport.enqueueOrdinarySend (bytes ("O")) { accepted, errno in
            ordinarySettled.set ((ordinarySettled.value ?? []) + [(accepted, errno)])
        }
        try? await Task.sleep (nanoseconds: 20_000_000)
        XCTAssertEqual (backend.written.count, 1, "queued units must not physically start")

        transport.channelWillClose ()

        // Acknowledged queued write: immediate failure, zero accepted.
        let queuedResult = await queuedTask.value
        XCTAssertEqual (queuedResult.acceptedBytes, 0)
        XCTAssertEqual (queuedResult.error, .channelClosed)
        // Ordinary fire-and-forget queued send: zero accepted, silent.
        _ = await waitUntil { !(ordinarySettled.value ?? []).isEmpty }
        let ordinary = try XCTUnwrap (ordinarySettled.value?.first)
        XCTAssertEqual (ordinary.accepted, 0)

        // In-flight: still pending across the close...
        try await Task.sleep (nanoseconds: 50_000_000)
        XCTAssertNil (inflightBox.value)
        // ...then settled exactly by its terminal callback (full success).
        backend.deliver (index: 0, remainingByteCount: 0, errno: 0)
        let inflightResult = await inflightTask.value
        XCTAssertEqual (inflightResult.acceptedBytes, 2)
        XCTAssertNil (inflightResult.error)
    }

    // MARK: R1 — pending begin-marker admission window

    func testPendingBeginBlocksLaterOrdinaryInput () async throws
    {
        // §19: A starts and blocks; T's begin marker is admitted (pending);
        // D is admitted while T is still pending; release A → T activates →
        // B, C, end → D. Physical order must be ABCD, never A D B C.
        let backend = FakeInputBackend (label: "r1-pending")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let aTask = Task { await transport.write (bytes ("A")) }
        _ = await waitUntil { backend.pendingCount == 1 }

        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                _ = await writer.write (bytes ("B"))
                _ = await writer.write (bytes ("C"))
            }
        }
        // Begin marker admitted while A is still physically in flight.
        _ = await waitUntil { transport.debugTransactionPhase == .pending }

        // Admitted while the transaction is only pending: must not bypass it.
        let dTask = Task { await transport.write (bytes ("D")) }
        try? await Task.sleep (nanoseconds: 20_000_000)
        XCTAssertEqual (backend.written.count, 1, "D must not physically start while T is pending")

        backend.deliver (index: 0, remainingByteCount: 0, errno: 0)  // release A
        _ = await waitUntil { transport.debugTransactionPhase == .active }
        _ = await waitUntil { backend.pendingCount == 2 }            // B started
        backend.deliver (index: 1, remainingByteCount: 0, errno: 0)  // B done → C
        _ = await waitUntil { backend.pendingCount == 3 }
        backend.deliver (index: 2, remainingByteCount: 0, errno: 0)  // C done → end → D
        _ = await waitUntil { backend.pendingCount == 4 }
        backend.deliver (index: 3, remainingByteCount: 0, errno: 0)  // D done

        _ = await aTask.value
        try await transactionTask.get()
        let dResult = await dTask.value
        XCTAssertTrue (dResult.succeeded)
        XCTAssertEqual (String (bytes: backend.written.flatMap { $0 }, encoding: .utf8), "ABCD")
    }

    func testPendingBeginPreservesHeldAdmissionOrder () async throws
    {
        // §20: A in flight; T pending; D1, D2 admitted; T activates; B; C;
        // D3 admitted while T active; T ends.
        // Required physical order: A B C D1 D2 D3 — no inversion.
        let backend = FakeInputBackend (label: "r1-multi")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let aTask = Task { await transport.write (bytes ("A")) }
        _ = await waitUntil { backend.pendingCount == 1 }

        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                _ = await writer.write (bytes ("B"))
                _ = await writer.write (bytes ("C"))
            }
        }
        _ = await waitUntil { transport.debugTransactionPhase == .pending }

        // D1, D2 admitted while T is pending, in deterministic FIFO
        // admission order (back-to-back enqueue on the serial authority
        // queue).
        let d1Settled = Box<[(accepted: Int, errno: Int32)]>()
        let d2Settled = Box<[(accepted: Int, errno: Int32)]>()
        let d3Settled = Box<[(accepted: Int, errno: Int32)]>()
        // D3 has no subsequent physical start whose observation could also
        // prove that its terminal callback ran. This expectation is fulfilled
        // only after the callback publishes the result into the locked box.
        let d3SettlementPublished = expectation (description: "D3 settlement result published")
        d1Settled.set ([]); d2Settled.set ([]); d3Settled.set ([])
        transport.enqueueOrdinarySend (bytes ("D1")) { a, e in
            d1Settled.set ((d1Settled.value ?? []) + [(a, e)])
        }
        transport.enqueueOrdinarySend (bytes ("D2")) { a, e in
            d2Settled.set ((d2Settled.value ?? []) + [(a, e)])
        }
        // These admission blocks and the release callback are submitted from
        // this task to one serial authority queue. Their FIFO submission order
        // makes D1 and D2 admissions precede A's release without a timing wait.
        XCTAssertEqual (backend.written.count, 1) // neither can start before A settles

        backend.deliver (index: 0, remainingByteCount: 0, errno: 0)  // release A
        _ = await waitUntil { transport.debugTransactionPhase == .active }
        _ = await waitUntil { backend.pendingCount == 2 }            // B started

        // D3 admitted while the transaction is active: also held, behind
        // D1/D2 in admission order.
        transport.enqueueOrdinarySend (bytes ("D3")) { a, e in
            d3Settled.set ((d3Settled.value ?? []) + [(a, e)])
            // Publication must happen before fulfillment so the waiter has a
            // real happens-before edge before it reads d3Settled.
            d3SettlementPublished.fulfill ()
        }

        backend.deliver (index: 1, remainingByteCount: 0, errno: 0)  // B done → C
        _ = await waitUntil { backend.pendingCount == 3 }
        backend.deliver (index: 2, remainingByteCount: 0, errno: 0)  // C done → end → D1 D2 D3
        // Held units start serially; settle each before the next starts.
        _ = await waitUntil { backend.pendingCount == 4 }
        backend.deliver (index: 3, remainingByteCount: 0, errno: 0)  // D1
        _ = await waitUntil { backend.pendingCount == 5 }
        backend.deliver (index: 4, remainingByteCount: 0, errno: 0)  // D2
        _ = await waitUntil { backend.pendingCount == 6 }
        backend.deliver (index: 5, remainingByteCount: 0, errno: 0)  // D3

        // pendingCount == 6 proves that D3 physically started, not that its
        // terminal handler and completion callback have already run.
        await fulfillment (of: [d3SettlementPublished], timeout: 10)

        _ = await aTask.value
        try await transactionTask.get()
        let d1 = try XCTUnwrap (d1Settled.value?.first)
        let d2 = try XCTUnwrap (d2Settled.value?.first)
        let d3 = try XCTUnwrap (d3Settled.value?.first)
        // The three ordinary operations after the transaction each have one
        // physical start, one terminal settlement, and one completion call.
        XCTAssertEqual (backend.written.count, 6)
        XCTAssertEqual (d1Settled.value?.count, 1)
        XCTAssertEqual (d2Settled.value?.count, 1)
        XCTAssertEqual (d3Settled.value?.count, 1)
        XCTAssertEqual (d1.accepted, 2)
        XCTAssertEqual (d2.accepted, 2)
        XCTAssertEqual (d3.accepted, 2)
        XCTAssertEqual (String (bytes: backend.written.flatMap { $0 }, encoding: .utf8),
                        "ABCD1D2D3")
    }

    func testSecondTransactionWhilePendingFails () async throws
    {
        // §18: a second acquisition while the first is pending fails with
        // .transactionUnavailable and never inserts another begin marker.
        let backend = FakeInputBackend (label: "r1-second")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let aTask = Task { await transport.write (bytes ("A")) }
        _ = await waitUntil { backend.pendingCount == 1 }

        let firstTask = Task { try await transport.withExclusiveInputTransaction { _ -> Void in } }
        _ = await waitUntil { transport.debugTransactionPhase == .pending }

        do {
            try await transport.withExclusiveInputTransaction { _ -> Void in }
            XCTFail ("second acquisition while pending must fail")
        } catch let error as LocalProcessInputTransportError {
            XCTAssertEqual (error, .transactionUnavailable)
        }

        backend.deliver (index: 0, remainingByteCount: 0, errno: 0) // release A → T activates & ends
        try await firstTask.get()
        _ = await aTask.value
        // Only one physical write ever happened; no stray transaction bytes.
        XCTAssertEqual (backend.written.count, 1)
    }

    func testTransactionFailureReleasesHeldFIFOInAdmissionOrder () async throws
    {
        // §21: T active; its write fails; held ordinary sends resume
        // afterwards in original admission order.
        let backend = FakeInputBackend (label: "r1-fail")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                _ = await writer.write (bytes ("B")) // fails with EIO
            }
        }
        _ = await waitUntil { backend.pendingCount == 1 && transport.debugTransactionPhase == .active }

        // U1, U2 admitted while T is active, in deterministic FIFO admission
        // order (back-to-back enqueue on the serial authority queue).
        let u1Settled = Box<[(accepted: Int, errno: Int32)]>()
        let u2Settled = Box<[(accepted: Int, errno: Int32)]>()
        u1Settled.set ([]); u2Settled.set ([])
        transport.enqueueOrdinarySend (bytes ("U1")) { a, e in
            u1Settled.set ((u1Settled.value ?? []) + [(a, e)])
        }
        transport.enqueueOrdinarySend (bytes ("U2")) { a, e in
            u2Settled.set ((u2Settled.value ?? []) + [(a, e)])
        }
        try? await Task.sleep (nanoseconds: 20_000_000)
        XCTAssertEqual (backend.written.count, 1) // held while T active

        backend.deliver (index: 0, remainingByteCount: 1, errno: Int32(EIO)) // B fails
        try await transactionTask.get() // body returns → end merges held FIFO
        _ = await waitUntil { backend.pendingCount == 2 }
        backend.deliver (index: 1, remainingByteCount: 0, errno: 0) // U1
        _ = await waitUntil { backend.pendingCount == 3 }
        backend.deliver (index: 2, remainingByteCount: 0, errno: 0) // U2
        _ = await waitUntil { !(u1Settled.value ?? []).isEmpty && !(u2Settled.value ?? []).isEmpty }

        let r1 = try XCTUnwrap (u1Settled.value?.first)
        let r2 = try XCTUnwrap (u2Settled.value?.first)
        XCTAssertEqual (r1.accepted, 2)
        XCTAssertEqual (r2.accepted, 2)
        XCTAssertEqual (String (bytes: backend.written.flatMap { $0 }, encoding: .utf8),
                        "BU1U2")
    }

    func testChannelCloseWhileTransactionPendingSettlesAllUnits () async throws
    {
        // §25: close while T is only pending: begin fails, held ordinary
        // fails with zero accepted, in-flight write settles on its terminal
        // callback.
        let backend = FakeInputBackend (label: "r1-pending-close")
        backend.autoComplete = false
        let transport = makeTransport (backend)

        let aBox = Box<LocalProcessInputWriteResult>()
        let aTask = Task {
            let r = await transport.write (bytes ("AA"))
            aBox.set (r)
            return r
        }
        _ = await waitUntil { backend.pendingCount == 1 }

        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                _ = await writer.write (bytes ("B"))
            }
        }
        _ = await waitUntil { transport.debugTransactionPhase == .pending }

        let dBox = Box<LocalProcessInputWriteResult>()
        let dTask = Task {
            let r = await transport.write (bytes ("D"))
            dBox.set (r)
            return r
        }
        try? await Task.sleep (nanoseconds: 20_000_000)

        transport.channelWillClose ()

        // Pending begin marker: acquisition fails with .channelClosed.
        do {
            try await transactionTask.get()
            XCTFail ("pending transaction must fail on close")
        } catch let error as LocalProcessInputTransportError {
            XCTAssertEqual (error, .channelClosed)
        }
        // Held ordinary send: immediate failure, zero accepted.
        let dResult = await dTask.value
        XCTAssertEqual (dResult.acceptedBytes, 0)
        XCTAssertEqual (dResult.error, .channelClosed)
        // In-flight: retained across the close until its terminal callback.
        try await Task.sleep (nanoseconds: 50_000_000)
        XCTAssertNil (aBox.value)
        backend.deliver (index: 0, remainingByteCount: 0, errno: 0)
        let aResult = await aTask.value
        XCTAssertEqual (aResult.acceptedBytes, 2)
        XCTAssertNil (aResult.error)
    }

    // MARK: Incarnation binding / fd-reuse protection

    func testOldTransactionCannotRetargetAfterReadopt () async throws
    {
        let backend1 = FakeInputBackend (label: "old")
        let transport = makeTransport (backend1)
        let backend2 = FakeInputBackend (label: "new")

        let resultBox = Box<LocalProcessInputWriteResult>()
        let transactionTask = Task<Void, Error> {
            try await transport.withExclusiveInputTransaction { writer -> Void in
                // Simulate process replacement: a new incarnation is adopted.
                transport.adopt (backend: backend2)
                // Even if the OS recycled the old numeric fd, the transaction
                // is bound to the old channel object — never retargeted.
                resultBox.set (await writer.write (bytes ("stale")))
            }
        }
        try await transactionTask.get()

        XCTAssertEqual (resultBox.value?.error, .channelClosed)
        XCTAssertEqual (backend1.written.count, 0)

        // Fresh work after the replacement uses the new incarnation only.
        let fresh = await transport.write (bytes ("fresh"))
        XCTAssertTrue (fresh.succeeded)
        XCTAssertEqual (backend2.written.flatMap { $0 }, Array ("fresh".utf8))
        XCTAssertEqual (backend1.written.count, 0)
    }

    // MARK: Concurrency

    func testTwoOrdinarySendsBothSettleFully () async
    {
        let backend = FakeInputBackend (label: "concurrent")
        let transport = makeTransport (backend)

        async let r1 = transport.write (bytes ("aaa"))
        async let r2 = transport.write (bytes ("bbb"))
        let results = await [r1, r2]
        for result in results {
            XCTAssertTrue (result.succeeded)
        }
        let flat = backend.written.flatMap { $0 }
        // Both payloads delivered as whole units, in admission order, with no
        // interleaving of partial payloads.
        XCTAssertTrue (flat == Array ("aaabbb".utf8) || flat == Array ("bbbaaa".utf8))
    }

    func testOrdinaryVsTransactionAcquisitionRace () async throws
    {
        let backend = FakeInputBackend (label: "race")
        let transport = makeTransport (backend)

        let ordinary = Task { await transport.write (bytes ("O")) }
        let transaction = Task {
            try await transport.withExclusiveInputTransaction { writer in
                _ = await writer.write (bytes ("T"))
            }
        }
        _ = await ordinary.value
        _ = try await transaction.get()

        let flat = backend.written.flatMap { $0 }
        // Deterministic total order by admission: either O before the
        // transaction, or held until it ends — never interleaved.
        XCTAssertTrue (flat == Array ("OT".utf8) || flat == Array ("TO".utf8))
    }

    // MARK: Real PTY integration

    final class EchoCollector: LocalProcessDelegate {
        private let lock = NSLock()
        private var bufferStorage: [UInt8] = []
        var buffer: [UInt8] {
            lock.lock(); defer { lock.unlock() }
            return bufferStorage
        }
        func dataReceived (slice: ArraySlice<UInt8>)
        {
            lock.lock()
            bufferStorage.append (contentsOf: slice)
            lock.unlock()
        }
        func processTerminated (_ source: LocalProcess, exitCode: Int32?) {}
        func getWindowSize () -> winsize
        {
            var ws = winsize()
            ws.ws_col = 80
            ws.ws_row = 24
            return ws
        }
    }

    func testRealPtyByteOrderOrdinaryAndTransaction () async throws
    {
        let collector = EchoCollector()
        let delegateQueue = DispatchQueue (label: "LocalProcessInputTransportTests.delegate")
        let process = LocalProcess (delegate: collector, dispatchQueue: delegateQueue)
        defer { process.terminate() }

        // Harmless byte-echo fixture; no user shell configuration involved.
        process.startProcess (executable: "/bin/cat", args: [])
        guard process.running else {
            throw XCTSkip ("PTY fixture could not start on this machine")
        }

        // A: ordinary keyboard/paste path (fire-and-forget send(data:)).
        process.send (data: bytes ("A"))
        // B, C: exclusive transaction with two ordered writes.
        try await process.inputTransport.withExclusiveInputTransaction { writer in
            _ = await writer.write (bytes ("B"))
            _ = await writer.write (bytes ("C"))
        }
        // D: ordinary again.
        process.send (data: bytes ("D"))

        // Sent byte stream order == observed child byte stream order.
        _ = await waitUntil { collector.buffer.count >= 4 }
        let prefix = String (bytes: collector.buffer.prefix (4), encoding: .utf8)
        XCTAssertEqual (prefix, "ABCD",
                        "sent order A,B,C,D must be preserved; got \(prefix ?? "?")")
    }

    func testRealPtyTransactionWriteFailsAfterTerminate () async throws
    {
        let collector = EchoCollector()
        let delegateQueue = DispatchQueue (label: "LocalProcessInputTransportTests.delegate2")
        let process = LocalProcess (delegate: collector, dispatchQueue: delegateQueue)
        defer { process.terminate() }

        process.startProcess (executable: "/bin/cat", args: [])
        guard process.running else {
            throw XCTSkip ("PTY fixture could not start on this machine")
        }

        let errorBox = Box<LocalProcessInputTransportError>()
        try await process.inputTransport.withExclusiveInputTransaction { writer -> Void in
            process.terminate ()
            let result = await writer.write (bytes ("never"))
            errorBox.set (result.error)
        }

        // Generic transport failure only — no agent semantics leak.
        let error = try XCTUnwrap (errorBox.value)
        XCTAssertTrue (error == .channelClosed || error == .processUnavailable)

        // The transport reports a generic failure for further work too.
        let after = await process.inputTransport.write (bytes ("x"))
        XCTAssertNotNil (after.error)
    }
}
#endif
