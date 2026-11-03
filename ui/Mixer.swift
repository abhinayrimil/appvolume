// Mixer.swift — per-app volume engine (public Core Audio taps, macOS 14.3+).
// One AppTap per controlled process: tap (muted) -> private aggregate (default
// output + tap) -> IOProc multiplies by a ramped gain. 100% = no tap at all.

import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import AppKit

// ---- low-level helpers ------------------------------------------------------

@inline(__always)
func getProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ def: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    var val = def
    _ = withUnsafeMutablePointer(to: &val) {
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
    }
    return val
}

func cfStringProp(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: sel,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    var out: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &out) == noErr, let v = out else { return nil }
    return v.takeRetainedValue() as String
}

func objectList(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: sel,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var arr = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &arr) == noErr else { return [] }
    return arr
}

// perceptual taper: 0..1 -> -64dB..0dB (log), >1 linear boost
func perceptualGain(_ v: Float) -> Float {
    if v <= 0.001 { return 0 }
    if v >= 1 { return v }
    return powf(10, (-64.0 * (1 - v)) / 20)
}

// ---- audio process discovery -----------------------------------------------

struct AudioApp: Identifiable, Hashable {
    let id: AudioObjectID      // process object
    let pid: pid_t
    let name: String
    let bundleID: String?      // stable key for persisted levels
}

func runningAudioApps() -> [AudioApp] {
    let procs = objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    var out: [AudioApp] = []
    for p in procs {
        let active: UInt32 = getProp(p, kAudioProcessPropertyIsRunningOutput, UInt32(0))
        guard active != 0 else { continue }
        let pid: pid_t = getProp(p, kAudioProcessPropertyPID, pid_t(-1))
        guard pid > 0 else { continue }
        let running = NSRunningApplication(processIdentifier: pid)
        let bundleID = running?.bundleIdentifier ?? cfStringProp(p, kAudioProcessPropertyBundleID)
        let name = running?.localizedName ?? bundleID ?? "pid \(pid)"
        out.append(AudioApp(id: p, pid: pid, name: name, bundleID: bundleID))
    }
    return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

// ---- one controlled app -----------------------------------------------------

final class AppTap {
    private let proc: AudioObjectID
    private var tapID = AudioObjectID(0)
    private var aggID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    var target: Float          // read by realtime IOProc
    private var current: Float  // owned by IOProc

    init?(proc: AudioObjectID, knob: Float) {
        self.proc = proc
        self.target = perceptualGain(knob)
        self.current = target

        let desc = CATapDescription(stereoMixdownOfProcesses: [proc])
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr, tapID != 0 else { return nil }

        guard let tapUID = cfStringProp(tapID, kAudioTapPropertyUID) else { teardown(); return nil }
        let outDev = getProp(AudioObjectID(kAudioObjectSystemObject),
                             kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
        guard let outUID = cfStringProp(outDev, kAudioDevicePropertyDeviceUID) else { teardown(); return nil }

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "appvolume-\(proc)",
            kAudioAggregateDeviceUIDKey as String: "appvolume-\(getpid())-\(proc)",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: outUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outUID]],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: tapUID,
                kAudioSubTapDriftCompensationKey as String: 1,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr, aggID != 0 else { teardown(); return nil }

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, nil) { [weak self] (_, inIn, _, outOut, _) in
            guard let self = self else { return }
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inIn))
            let outList = UnsafeMutableAudioBufferListPointer(outOut)
            let n = min(inList.count, outList.count)
            let tgt = self.target
            let boosting = tgt > 1 || self.current > 1   // only soft-clip above unity
            for i in 0..<n {
                guard let s = inList[i].mData, let d = outList[i].mData else { continue }
                let count = Int(min(inList[i].mDataByteSize, outList[i].mDataByteSize)) / MemoryLayout<Float>.size
                let dp = d.assumingMemoryBound(to: Float.self)
                var start = self.current
                var step = count > 0 ? (tgt - self.current) / Float(count) : 0
                vDSP_vrampmul(s.assumingMemoryBound(to: Float.self), 1, &start, &step, dp, 1, vDSP_Length(count))
                if boosting && count > 0 {
                    var cnt = Int32(count)
                    vvtanhf(dp, dp, &cnt)   // soft knee: tanh(x)≈x when quiet, saturates near ±1
                }
            }
            self.current = tgt
        }
        guard status == noErr, let p = ioProc, AudioDeviceStart(aggID, p) == noErr else { teardown(); return nil }
    }

    func setKnob(_ knob: Float) { target = perceptualGain(knob) }

    func teardown() {
        if let p = ioProc { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); ioProc = nil }
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }
    deinit { teardown() }
}

// ---- engine: knob per app ---------------------------------------------------

final class MixerEngine {
    var apps: [AudioApp] = []
    var knobs: [AudioObjectID: Float] = [:]   // 0..2, default 1 (this launch)
    private var taps: [AudioObjectID: AppTap] = [:]
    private var appByID: [AudioObjectID: AudioApp] = [:]

    // persisted levels, keyed by bundle id so they survive relaunch
    private let store = UserDefaults.standard
    private let storeKey = "knobsByBundleID"
    private var savedKnobs: [String: Float] = [:]

    init() {
        savedKnobs = (store.object(forKey: storeKey) as? [String: Float]) ?? [:]
        installOutputListener()
    }

    func refresh() {
        let live = runningAudioApps()
        apps = live
        appByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        let liveIDs = Set(live.map { $0.id })
        for id in taps.keys where !liveIDs.contains(id) { taps[id]?.teardown(); taps[id] = nil }
        for id in knobs.keys where !liveIDs.contains(id) { knobs[id] = nil }
        // restore saved level for apps that just appeared
        for app in live where knobs[app.id] == nil {
            let k = app.bundleID.flatMap { savedKnobs[$0] } ?? 1.0
            knobs[app.id] = k
            if abs(k - 1.0) >= 0.001 { apply(app, k) }
        }
    }

    func knob(_ app: AudioApp) -> Float {
        knobs[app.id] ?? app.bundleID.flatMap { savedKnobs[$0] } ?? 1.0
    }

    func setKnob(_ app: AudioApp, _ v: Float) {
        let knob = min(max(v, 0), 2)
        knobs[app.id] = knob
        apply(app, knob)
        if let b = app.bundleID {                 // persist
            savedKnobs[b] = knob
            store.set(savedKnobs, forKey: storeKey)
        }
    }

    // create / update / tear down the tap for one app (no persistence side-effects)
    private func apply(_ app: AudioApp, _ knob: Float) {
        if abs(knob - 1.0) < 0.001 {              // 100% -> stop tapping, release the app
            taps[app.id]?.teardown(); taps[app.id] = nil
        } else if let t = taps[app.id] {
            t.setKnob(knob)
        } else {
            taps[app.id] = AppTap(proc: app.id, knob: knob)   // nil on failure; slider still moves
        }
    }

    // rebuild active taps when the default output device changes
    private func installOutputListener() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            guard let self = self else { return }
            for (id, _) in self.taps {
                guard let app = self.appByID[id], let k = self.knobs[id] else { continue }
                self.taps[id]?.teardown(); self.taps[id] = nil
                self.apply(app, k)                // recreate against the new default output
            }
        }
    }

    func stopAll() { for t in taps.values { t.teardown() }; taps.removeAll() }
}
