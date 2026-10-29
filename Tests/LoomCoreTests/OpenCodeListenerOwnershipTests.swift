import Darwin
import Foundation
import Testing
@testable import LoomCore

@Suite struct OpenCodeListenerOwnershipTests {
    @Test func onlyTheBornProcessAndExactLoopbackListenerPass() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        #expect(got == 0)
        let port = UInt16(bigEndian: address.sin_port)
        let process = try #require(ProcessTable.record(pid: getpid()))
        #expect(OpenCodeListenerOwnership.owns(leader: process.identity, port: port))
        // Hold a second bound, non-listening port so concurrent HTTP fixtures
        // cannot happen to create a valid listener at the negative-control port.
        let otherFD = socket(AF_INET, SOCK_STREAM, 0)
        #expect(otherFD >= 0)
        defer { Darwin.close(otherFD) }
        var other = sockaddr_in()
        other.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        other.sin_family = sa_family_t(AF_INET)
        other.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian
        let otherBound = withUnsafePointer(to: &other) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(otherFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(otherBound == 0)
        var otherLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let otherGot = withUnsafeMutablePointer(to: &other) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(otherFD, $0, &otherLength) }
        }
        #expect(otherGot == 0)
        #expect(!OpenCodeListenerOwnership.owns(leader: process.identity, port: UInt16(bigEndian: other.sin_port)))
        let wrongBirth = ProcessIdentity(pid: process.identity.pid, startSeconds: process.identity.startSeconds + 1,
                                         startMicroseconds: process.identity.startMicroseconds)
        #expect(!OpenCodeListenerOwnership.owns(leader: wrongBirth, port: port))
    }
}
