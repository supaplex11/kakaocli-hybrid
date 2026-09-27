import Foundation
import Darwin

/// Signal callbacks run outside signal context. A condition wakes idle polling promptly.
public final class ReceiveStop: @unchecked Sendable {
    private let condition = NSCondition()
    private var stopped = false
    private var sources: [DispatchSourceSignal] = []
    public init() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.condition.lock()
                self.stopped = true
                self.condition.broadcast()
                self.condition.unlock()
            }
            sources.append(source)
            source.resume()
        }
    }
    public var requested: Bool {
        condition.lock(); defer { condition.unlock() }
        return stopped
    }
    public func wait(_ seconds: Double) {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !stopped && condition.wait(until: deadline) {}
    }
    public func close() { for source in sources { source.cancel() } }
}
