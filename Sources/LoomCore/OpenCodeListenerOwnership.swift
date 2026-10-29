import Darwin
import Darwin.libproc
import Foundation

/// A listener is accepted only while the born child, with the same birth and
/// user identity, owns an IPv4 TCP listener at the exact loopback port.
enum OpenCodeListenerOwnership {
    static func owns(leader: ProcessIdentity, port: UInt16) -> Bool {
        guard port > 0, matches(leader) else { return false }
        let itemSize = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(leader.pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0, needed <= Int32(itemSize * 4096) else { return false }
        let count = min(4096, Int(needed) / itemSize + 64)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let capacity = descriptors.count * itemSize
        let bytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(leader.pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        // A full buffer may be a truncated snapshot. Refuse it rather than
        // concluding anything from an incomplete list.
        guard bytes > 0, Int(bytes) < capacity, Int(bytes) % itemSize == 0 else { return false }
        for descriptor in descriptors.prefix(Int(bytes) / itemSize) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(leader.pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_family == AF_INET, info.psi.soi_type == SOCK_STREAM,
                  info.psi.soi_protocol == IPPROTO_TCP, info.psi.soi_kind == SOCKINFO_TCP,
                  Int32(info.psi.soi_options) & Int32(SO_ACCEPTCONN) != 0 else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let local = tcp.tcpsi_ini
            guard tcp.tcpsi_state == TSI_S_LISTEN,
                  UInt16(bigEndian: UInt16(truncatingIfNeeded: local.insi_lport)) == port,
                  UInt32(bigEndian: local.insi_laddr.ina_46.i46a_addr4.s_addr) == 0x7f000001 else { continue }
            return matches(leader)
        }
        return false
    }

    private static func matches(_ leader: ProcessIdentity) -> Bool {
        guard let record = ProcessTable.record(pid: leader.pid) else { return false }
        return record.identity == leader && record.userID == geteuid() && !record.zombie
    }
}
