import Darwin
import Foundation

/// A port nothing listens on yet, picked by the kernel.
func freeLoopbackPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
    defer { close(descriptor) }
    var reuse: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = socketAddress("127.0.0.1", port: 0)
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    return UInt16(bigEndian: address.sin_port)
}

func socketAddress(_ ip: String, port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    _ = inet_pton(AF_INET, ip, &address.sin_addr)
    return address
}

/// Opens a TCP connection, or returns why none came up within `timeout`
/// seconds: refused, or — when the firewall's stealth mode drops the
/// attempt — timed out.
func connectTCP(_ ip: String, port: UInt16, timeout: Int32 = 3) -> Result<Int32, POSIXError> {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return .failure(POSIXError(.ENOTSOCK)) }
    var io = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &io, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &io, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    let flags = fcntl(descriptor, F_GETFL)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    var address = socketAddress(ip, port: port)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var failure: Int32 = result == 0 ? 0 : errno
    if failure == EINPROGRESS {
        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        if poll(&poller, 1, timeout * 1000) == 1 {
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
        } else {
            failure = ETIMEDOUT
        }
    }
    guard failure == 0 else {
        close(descriptor)
        return .failure(POSIXError(POSIXErrorCode(rawValue: failure) ?? .ECONNREFUSED))
    }
    _ = fcntl(descriptor, F_SETFL, flags)
    return .success(descriptor)
}

/// This Mac's first IPv4 address that is not loopback, if it has one.
func nonLoopbackIPv4() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
    defer { freeifaddrs(interfaces) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(pointer.pointee.ifa_flags)
        guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        return String(cString: host)
    }
    return nil
}
