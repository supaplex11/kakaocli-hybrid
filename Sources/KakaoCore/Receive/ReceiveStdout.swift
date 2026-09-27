import Foundation
import Darwin

public enum ReceiveStdout {
    /// Bounded writes; caller acknowledges only after the whole NDJSON record.
    /// A crash between write and acknowledgement can duplicate a record.
    public static func write(_ payload: Data, fd: Int32 = STDOUT_FILENO, timeout: Double = 5, shouldStop: () -> Bool = { false }) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ReceiveError.sinkFailed }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        var bytes = payload; bytes.append(10)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard !shouldStop() else { throw ReceiveError.stopped }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw ReceiveError.sinkFailed }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 100)))
                if result < 0 && errno == EINTR { continue }
                guard result >= 0, descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { throw ReceiveError.sinkFailed }
                if result == 0 { continue }
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard written > 0 else { throw ReceiveError.sinkFailed }
                offset += written
            }
        }
    }
}
