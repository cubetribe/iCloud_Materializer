import Foundation

actor PauseController {
    private var isPaused = false
    private var isCancelled = false
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        let continuations = waitingContinuations
        waitingContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func cancel() {
        isCancelled = true
        resume()
    }

    func checkpoint() async throws {
        try Task.checkCancellation()
        if isCancelled {
            throw CancellationError()
        }
        if isPaused {
            await withCheckedContinuation { continuation in
                waitingContinuations.append(continuation)
            }
        }
        try Task.checkCancellation()
        if isCancelled {
            throw CancellationError()
        }
    }
}
