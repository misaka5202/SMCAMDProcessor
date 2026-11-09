//
//  SMCAccess.swift
//  AMD Power Gadget
//
//  Minimal AppleSMC bridge, used only for the fan side of the performance
//  profiles. The CPU side keeps using the existing AMDRyzenCPUPowerManagement
//  IOUserClient (setCPB / setPPM / setLPM), so nothing about the working
//  CPU path changes.
//
//  Reads are always allowed. Writes go through AppleSMC's write selector,
//  which requires root: a non-root call returns kIOReturnNotPrivileged and
//  callers surface that instead of silently pretending the profile changed.
//

import Foundation
import IOKit

/// Mirrors SMCKeyData_t. The field order and packing matter: AppleSMC
/// interprets this buffer as a raw struct, so it must stay byte identical.
struct SMCKeyData {
    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    struct KeyData {
        var key: UInt32 = 0
        var vers: UInt8 = 0
        var pLimit: UInt16 = 0
        var lTotal: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
             0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
    }

    var key: UInt32 = 0
    var vers: UInt8 = 0
    var pLimit: UInt16 = 0
    var lTotal: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var keyInfo = KeyInfo()
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
         0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
}

final class SMCAccess {

    static let shared = SMCAccess()

    // AppleSMC user client selectors.
    private let kSMCUserClientOpen: UInt32 = 0
    private let kSMCUserClientClose: UInt32 = 1
    private let kSMCHandleYPCEvent: UInt32 = 2

    // data8 command codes used inside SMCKeyData.
    private let kSMCReadKey: UInt8 = 5
    private let kSMCWriteKey: UInt8 = 6
    private let kSMCGetKeyInfo: UInt8 = 9

    private let kSMCKeyNotFound: Int32 = -13987

    private var connect: io_connect_t = 0
    private var opened = false

    private init() {}

    // MARK: - connection

    @discardableResult
    func open() -> Bool {
        if opened { return true }

        let service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        if service == 0 {
            NSLog("SMCAccess: AppleSMC not found")
            return false
        }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connect)
        if kr != KERN_SUCCESS {
            NSLog("SMCAccess: IOServiceOpen failed: %@",
                  String(cString: mach_error_string(kr)))
            return false
        }

        opened = true
        return true
    }

    func close() {
        guard opened else { return }
        IOServiceClose(connect)
        connect = 0
        opened = false
    }

    // MARK: - key plumbing

    /// "F0Ac" -> packed UInt32 the same way SMC_MAKE_IDENTIFIER does it.
    private func keyCode(_ key: String) -> UInt32? {
        guard key.count == 4 else { return nil }
        var v: UInt32 = 0
        for ch in key.utf8 {
            v = (v << 8) | UInt32(ch)
        }
        return v
    }

    /// Struct call into AppleSMC. Returns the kern result and the reply.
    private func callStruct(_ input: inout SMCKeyData,
                            _ output: inout SMCKeyData) -> kern_return_t {
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return withUnsafePointer(to: &input) { inPtr in
            inPtr.withMemoryRebound(to: UInt8.self, capacity: 1) { inBytes in
                withUnsafeMutablePointer(to: &output) { outPtr in
                    outPtr.withMemoryRebound(to: UInt8.self, capacity: 1) { outBytes in
                        IOConnectCallStructMethod(connect,
                                                  kSMCHandleYPCEvent,
                                                  inBytes,
                                                  MemoryLayout<SMCKeyData>.stride,
                                                  outBytes,
                                                  &outputSize)
                    }
                }
            }
        }
    }

    /// Ask AppleSMC for a key's size and type.
    private func keyInfoBlocking(_ code: UInt32) -> SMCKeyData.KeyInfo? {
        var req = SMCKeyData()
        req.key = code
        req.data8 = kSMCGetKeyInfo

        var out = SMCKeyData()
        let kr = callStruct(&req, &out)
        guard kr == KERN_SUCCESS, out.keyInfo.dataSize > 0 else { return nil }
        return out.keyInfo
    }

    /// Read the 4-char type of a key ("ui8 ", "fpe2", ...). nil if absent.
    func keyType(_ key: String) -> String? {
        guard opened || open(), let code = keyCode(key),
              let info = keyInfoBlocking(code) else { return nil }

        var t = info.dataType
        var s = ""
        for _ in 0..<4 {
            // UnicodeScalar(UInt8) is non-failable in Swift 5.
            s.append(Character(UnicodeScalar(UInt8(t >> 24))))
            t <<= 8
        }
        return s
    }

    /// Raw bytes of a key (up to 32). nil when the key does not exist.
    func readBytes(_ key: String) -> [UInt8]? {
        guard opened || open(), let code = keyCode(key) else { return nil }

        // The key must exist first; AppleSMC needs its size to answer reads.
        guard let info = keyInfoBlocking(code) else { return nil }

        var req = SMCKeyData()
        req.key = code
        req.data8 = kSMCReadKey
        req.keyInfo = info

        var out = SMCKeyData()
        let kr = callStruct(&req, &out)
        guard kr == KERN_SUCCESS else { return nil }

        let n = Int(min(info.dataSize, 32))
        return withUnsafeBytes(of: out.bytes) { raw in
            Array(raw.prefix(n))
        }
    }

    /// Write up to 32 bytes. Returns a KERN_* result so the UI can explain a
    /// permission problem rather than silently dropping the write.
    ///
    /// Writing SMC keys requires root; a non-root attempt yields
    /// kIOReturnNotPrivileged.
    func writeBytes(_ key: String, bytes: [UInt8]) -> kern_return_t {
        guard opened || open() else { return kIOReturnNotOpen }
        guard let code = keyCode(key), !bytes.isEmpty, bytes.count <= 32 else {
            return kIOReturnBadArgument
        }
        guard let info = keyInfoBlocking(code) else { return kIOReturnNotFound }

        var req = SMCKeyData()
        req.key = code
        req.data8 = kSMCWriteKey
        req.keyInfo = info
        req.keyInfo.dataSize = UInt32(bytes.count)

        // Copy the payload into the tuple without going through safe indexing
        // on a tuple, which Swift does not allow.
        withUnsafeMutableBytes(of: &req.bytes) { raw in
            for (i, b) in bytes.enumerated() where i < 32 {
                raw[i] = b
            }
        }

        var out = SMCKeyData()
        return callStruct(&req, &out)
    }

    // MARK: - typed helpers

    /// fpe2 is fixed point with 4 steps per RPM: stored = RPM * 4.
    func readFanRPM(_ key: String) -> Int? {
        guard let b = readBytes(key), b.count >= 2 else { return nil }
        return Int(b[0]) * 64 + Int(b[1]) / 4
    }

    /// ui8 key (plain 0-255 value).
    func readUInt8(_ key: String) -> Int? {
        guard let b = readBytes(key), let first = b.first else { return nil }
        return Int(first)
    }
}
