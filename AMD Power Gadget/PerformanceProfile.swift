//
//  PerformanceProfile.swift
//  AMD Power Gadget
//
//  Combines the two independent knobs into the three presets the user asked
//  for. They really are independent: on a GA503QM the fan profile alone
//  shifts sustained CPU clock by only ~7% (measured 3403 vs 3652 MHz), so
//  the CPU has to be set explicitly rather than expected to follow the fans.
//
//    silent       fans 1900 RPM   CPB off, PPM on,  LPM on
//    balanced     fans 2500 RPM   CPB on,  PPM off, LPM off
//    performance  fans 4900 RPM   CPB on,  PPM off, LPM off
//
//  CPU side goes through AMDRyzenCPUPowerManagement's existing IOUserClient
//  selectors 12/14/19, which need no privileges and are already proven on
//  this machine. The fan side goes through the F0Tp SMC key published by the
//  patched AsusSMC.kext.
//

import Foundation
import IOKit

enum PerfProfile: Int, CaseIterable {
    case silent = 2
    case balanced = 0
    case performance = 1

    var title: String {
        switch self {
        case .silent:      return "安静"
        case .balanced:    return "标准"
        case .performance: return "增强"
        }
    }

    /// F0Tp value: the EC fan curve selector.
    var fanProfileValue: UInt8 { UInt8(self.rawValue) }

    var cpbEnabled: Bool { self == .balanced || self == .performance }
    var ppmEnabled: Bool { self == .silent }
    var lpmEnabled: Bool { self == .silent }
}

final class FanProfileController {

    static let shared = FanProfileController()

    private let keyThermalProfile = "F0Tp"
    private let keyFan0 = "F0Ac"
    private let keyFan1 = "F1Ac"

    private init() {}

    /// Is the patched AsusSMC publishing F0Tp? If not, the fan half of the
    /// profile is unavailable and the UI should say so rather than silently
    /// doing only half the job.
    func isFanControlAvailable() -> Bool {
        SMCAccess.shared.readUInt8(keyThermalProfile) != nil
    }

    /// The firmware DSTS for the thermal policy is a hardcoded constant and
    /// never reports the live value, so AsusSMC caches what was last written.
    /// On a fresh boot that is balanced.
    func currentProfile() -> PerfProfile {
        guard let v = SMCAccess.shared.readUInt8(keyThermalProfile),
              let p = PerfProfile(rawValue: v) else {
            return .balanced
        }
        return p
    }

    func fanSpeeds() -> (fan0: Int?, fan1: Int?) {
        (SMCAccess.shared.readFanRPM(keyFan0),
         SMCAccess.shared.readFanRPM(keyFan1))
    }

    /// Apply a profile. Returns nil on success, or a human readable reason.
    ///
    /// The CPU part is applied first because it always works; if the fan
    /// write then fails for permissions we report that instead of throwing
    /// away the CPU change the user already got.
    func apply(_ profile: PerfProfile, cpu: ProcessorModel) -> String? {
        var warning: String?

        cpu.setCPB(enabled: profile.cpbEnabled)
        cpu.setPPM(enabled: profile.ppmEnabled)
        cpu.setLPM(enabled: profile.lpmEnabled)

        if isFanControlAvailable() {
            let kr = SMCAccess.shared.writeBytes(keyThermalProfile,
                                                 bytes: [profile.fanProfileValue])
            if kr != KERN_SUCCESS {
                if kr == kIOReturnNotPrivileged {
                    warning = "CPU 已切换，但风扇需要管理员权限才能写入 "
                            + "(F0Tp)。请以 root 运行，或用 fanprofile.sh。"
                } else {
                    warning = String(format: "CPU 已切换，但风扇写入失败 (0x%X)",
                                     kr)
                }
            }
        } else {
            warning = "CPU 已切换，但未找到 F0Tp，风扇档位未变。"
                    + "请确认已加载打过补丁的 AsusSMC.kext。"
        }

        return warning
    }
}
