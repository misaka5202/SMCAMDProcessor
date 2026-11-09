//
//  AdaptiveBoost.swift
//  AMD Power Gadget
//
//  Decides when Core Performance Boost should be on, so the machine stops
//  boosting while it is idle.
//
//  Why this exists
//  ---------------
//  CPB is a single MSR bit (HWCR.CpbDis, bit 25) that raises the ceiling of
//  the whole package. It is not per-core and it cannot follow a single busy
//  thread: once on, every core is allowed to boost, and on a 5800HS in a
//  Zephyrus chassis that is what pushes package temperature up while the
//  desktop sits idle.
//
//  What AMDRyzenCPUPowerManagement already provides is only the switch:
//
//      IOUserClient selector 11   read  [supported, enabled]
//      IOUserClient selector 12   write 1 = on, 0 = off  (HWCR bit 25)
//
//  htmambo's fork added a related change - when the configured SpeedId is 0
//  it calls setPMPStateLimit(1) - but that is not load aware either: it sets
//  pmRyzen_pstatelimit to 1 and resets the P-State table once, at boot. It
//  does not look at what the machine is doing afterwards.
//
//  So the decision loop lives here, in userspace, where the load numbers are
//  already being sampled once a second by StatusbarController.
//
//  How the decision is made
//  ------------------------
//  Two signals, because either one alone misleads:
//
//    busy     highest per-core effective clock, as a fraction of the fastest
//             P-State. A core pinned at its non-boost ceiling means real work
//             is running; a core idling at 1.4 GHz does not.
//
//    load     the per-core load index the kext already computes from the
//             instruction-retired delta. This catches the case where clocks
//             are high because something *just* started.
//
//  Boost is turned on when either signal is high, and off when both are low.
//  The thresholds differ in the two directions (hysteresis) and a change has
//  to persist for a few seconds (dwell), because a single sample of a
//  scheduler tick is not a workload. Without that, CPB would flip every
//  second, and each flip is an MSR write to every core.
//
//  Once CPB is off, the clock ceiling drops to the highest non-boost P-State,
//  so `busy` falls even under the same work. That is why the "off" test uses
//  the load index as the primary signal and the clock only as a veto: judging
//  "still busy" from a clock that was already clamped would keep it off
//  forever.
//

import Foundation

/// What the adaptive loop decided, and why. Surfaced in the menu so the
/// behaviour can be understood without attaching a debugger.
enum BoostReason: String {
    case manual         = "手动"
    case disabled       = "已关闭"
    case idle           = "空闲"
    case busy           = "有负载"
    case dwell          = "等待稳定"
    case unsupported    = "硬件不支持"
}

final class AdaptiveBoost {

    static let shared = AdaptiveBoost()

    // MARK: - Tuning

    /// Above this fraction of the non-boost ceiling, treat the CPU as busy.
    /// 0.85 means "within 15% of the fastest the chip can go without boost",
    /// which in practice only happens when something is actually computing.
    private let busyClockFraction: Float = 0.85

    /// Below this fraction, the clock signal says idle. The gap between this
    /// and busyClockFraction is the hysteresis band: inside it, nothing
    /// changes, so a workload hovering at the boundary does not oscillate.
    private let idleClockFraction: Float = 0.70

    /// Load index thresholds, same idea. 0.35 is roughly "one core with a
    /// real job" on this 16-thread part.
    private let busyLoad: Float = 0.35
    private let idleLoad: Float = 0.15

    /// How long a new decision must hold before it is applied, in seconds.
    /// Long enough to ride out a compiler burst, short enough that a game
    /// starting gets boost within a few seconds.
    private let dwellSeconds: TimeInterval = 4.0

    /// How often a decision may actually be written, in seconds. Each write
    /// is an MP rendezvous that stops every core, so this is deliberately
    /// slower than the sample rate.
    private let minApplyInterval: TimeInterval = 8.0

    // MARK: - State

    private(set) var isEnabled = false          // the user's master switch
    private(set) var boostOn = true             // what we last asked for
    private(set) var reason: BoostReason = .manual
    private(set) var lastSample: (clock: Float, load: Float, temp: Float) = (0, 0, 0)

    private var candidateOn: Bool?
    private var candidateSince: TimeInterval = 0
    private var lastApplyTime: TimeInterval = 0
    private var busyCeiling: Float = 0           // learned from P-States

    private init() {}

    // MARK: - Public

    /// Turn the loop on or off. Turning it off leaves CPB wherever the manual
    /// profile left it, so the user is never stuck with a clamped CPU.
    func setEnabled(_ on: Bool) {
        isEnabled = on
        candidateOn = nil
        reason = on ? .idle : .manual
        if !on {
            // Hand control back to whatever the profile wants.
            boostOn = true
        }
    }

    /// Called once per second from StatusbarController's timer, with the
    /// numbers it has already collected. Returns true when CPB was written,
    /// so the caller can refresh any UI that shows it.
    @discardableResult
    func tick(cpu: ProcessorModel, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard isEnabled else { return false }
        guard cpu.isCPBSupported() else {
            reason = .unsupported
            return false
        }

        // Clocks: highest per-core effective frequency, and the ceiling the
        // chip can reach with boost off.
        let clocks = cpu.getEffectiveFrequencies()
        let peak = clocks.max() ?? 0
        let ceiling = nonBoostCeiling(cpu: cpu)
        let clockFraction = ceiling > 0 ? peak / ceiling : 0

        // Load: the kext's own per-core index.
        let loads = cpu.getLoadIndex()
        let load = loads.max() ?? 0

        let metrics = cpu.getMetric(forced: false)
        let temp = metrics.count > 1 ? metrics[1] : 0
        lastSample = (clockFraction, load, temp)

        // Decide what we *want*. While boost is off the clock is clamped, so
        // "still busy" has to be read from the load index, with the clock only
        // able to veto an idle verdict - never to create one.
        let wantOn: Bool
        if boostOn {
            // Currently boosting: drop it only when both signals are low.
            wantOn = !(clockFraction < idleClockFraction && load < idleLoad)
        } else {
            // Currently clamped: resume when either signal is high.
            wantOn = (clockFraction > busyClockFraction) || (load > busyLoad)
        }

        // Hysteresis in time: the same verdict has to survive dwellSeconds.
        if candidateOn != wantOn {
            candidateOn = wantOn
            candidateSince = now
            reason = .dwell
            return false
        }
        guard now - candidateSince >= dwellSeconds else {
            reason = .dwell
            return false
        }
        guard wantOn != boostOn else {
            reason = wantOn ? .busy : .idle
            return false
        }
        guard now - lastApplyTime >= minApplyInterval else {
            reason = .dwell
            return false
        }

        cpu.setCPB(enabled: wantOn)
        boostOn = wantOn
        lastApplyTime = now
        reason = wantOn ? .busy : .idle
        return true
    }

    /// A short human readable line for the menu, so the state is visible
    /// without opening anything.
    func statusLine() -> String {
        let c = Int(lastSample.clock * 100)
        let l = Int(lastSample.load * 100)
        let t = Int(lastSample.temp)
        return "\(reason.rawValue)  CPB \(boostOn ? "开" : "关")"
             + "  时钟 \(c)%  负载 \(l)%  \(t)°C"
    }

    // MARK: - Internals

    /// The fastest clock available with boost disabled. The P-State table
    /// reports every state the firmware exposes; the highest one is the
    /// non-boost ceiling once CpbDis is set, because boost states are not in
    /// that table.
    private func nonBoostCeiling(cpu: ProcessorModel) -> Float {
        if busyCeiling > 0 { return busyCeiling }
        let valid = cpu.getVaildPStateClocks()
        busyCeiling = valid.max() ?? 0
        return busyCeiling
    }
}
