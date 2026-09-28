// Spike DNS responder: answers A queries for *.keg (and apex "keg") with
// 127.0.0.1 over UDP. In-zone AAAA/HTTPS/ANY get empty NOERROR so resolvers
// fall back to A. Everything else: NXDOMAIN.
//
//   swiftc -O -o dnsspike dnsspike.swift && ./dnsspike
//   dig @127.0.0.1 -p 15353 +short memos.keg A
//
// Port 15353 because container-apiserver 1.4.1 already squats on 127.0.0.1:1053.
// Raw sockets on purpose — validates that an in-process responder is trivial.
// Spike only; production version would be SwiftNIO inside Keg.
import Darwin

let port: UInt16 = 15353
let zone = "keg"

func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

func parseName(_ q: [UInt8], _ start: Int) -> (name: String, end: Int)? {
    var labels: [String] = []
    var i = start
    while i < q.count {
        let len = Int(q[i])
        if len == 0 { return (labels.joined(separator: ".").lowercased(), i + 1) }
        if len & 0xC0 != 0 { return nil }  // compression never appears in questions
        i += 1
        guard i + len <= q.count else { return nil }
        labels.append(String(decoding: q[i..<i + len], as: UTF8.self))
        i += len
    }
    return nil
}

func respond(_ q: [UInt8]) -> [UInt8]? {
    guard q.count > 12 else { return nil }
    let qdcount = Int(q[4]) << 8 | Int(q[5])
    guard qdcount == 1 else { return nil }
    guard let (name, qEnd) = parseName(q, 12), qEnd + 4 <= q.count else { return nil }
    let qtype = Int(q[qEnd]) << 8 | Int(q[qEnd + 1])
    let questionEnd = qEnd + 4  // name + root label + QTYPE + QCLASS

    let inZone = name == zone || name.hasSuffix("." + zone)
    let answerable = inZone && qtype == 1  // A

    var flags: UInt16 = 0x8400  // QR=1, AA=1, opcode 0, RCODE=0 (NOERROR)
    if !inZone { flags |= 0x0003 }  // NXDOMAIN

    var m: [UInt8] = []
    m += q[0..<2]  // echo ID
    m += u16(flags)
    m += u16(1)  // QDCOUNT
    m += u16(answerable ? 1 : 0)  // ANCOUNT
    m += [0, 0, 0, 0]  // NSCOUNT, ARCOUNT
    m += q[12..<questionEnd]  // echo question
    if answerable {
        m += [0xC0, 0x0C]  // NAME: pointer to question at offset 12
        m += u16(1)  // TYPE A
        m += u16(1)  // CLASS IN
        m += [0, 0, 0, 5]  // TTL 5s (short: spike iterations see changes fast)
        m += u16(4)  // RDLENGTH
        m += [127, 0, 0, 1]
    }
    return m
}

let fd = socket(AF_INET, SOCK_DGRAM, 0)
precondition(fd >= 0, "socket: \(String(cString: strerror(errno)))")
var yes: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)  // s_addr is network byte order
let bound = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
precondition(bound == 0, "bind 127.0.0.1:\(port): \(String(cString: strerror(errno)))")
print("dnsspike: 127.0.0.1:\(port) — *.\(zone) → 127.0.0.1")

var buf = [UInt8](repeating: 0, count: 4096)
while true {
    var from = sockaddr_storage()
    var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let n = withUnsafeMutablePointer(to: &from) { fp in
        fp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(fd, &buf, buf.count, 0, $0, &fromLen)
        }
    }
    guard n > 0 else { continue }
    guard let resp = respond(Array(buf[0..<n])) else { continue }
    _ = resp.withUnsafeBufferPointer { bp in
        withUnsafePointer(to: &from) { fp in
            fp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bp.baseAddress!, resp.count, 0, $0, fromLen)
            }
        }
    }
}
