// appvolume — per-app volume via public Core Audio process taps (macOS 14.3+).
// Build: swiftc -O main.swift -o appvolume -framework CoreAudio -framework AudioToolbox
// Run:   ./appvolume <pid|name> <volume 0..2>
// Mutes the target app's normal output, re-renders a gain-scaled copy to the
// default output device. Ctrl-C to stop (restores the app).
//
// Written from Apple's public tap APIs only. Not derived from SoundSource.

import Foundation
import CoreAudio
import AudioToolbox
import Accelerate

// ---- helpers ----------------------------------------------------------------

func check(_ status: OSStatus, _ what: String) {
    if status != noErr {
        let c = status
        let chars = [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff),
                     UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
        let fourCC = String(bytes: chars, encoding: .ascii) ?? ""
        FileHandle.standardError.write("ERROR \(what): \(c) '\(fourCC)'\n".data(using: .utf8)!)
        exit(1)
    }
}

// Perceptual volume taper. knob 0..1 -> dB floor -64..0 (log); knob>1 -> linear boost.
func perceptualGain(_ v: Float) -> Float {
    if v <= 0.001 { return 0 }
    if v >= 1 { return v }                 // boost region: linear above unity
    let db = -64.0 * (1 - v)               // -64 dB at 0, 0 dB at 1
    return powf(10, db / 20)
}

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

func deviceUID(_ dev: AudioObjectID) -> CFString {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    var uid: Unmanaged<CFString>?
    check(AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid), "device UID")
    return uid!.takeRetainedValue()
}

// pid -> AudioObjectID for the process (needed by CATapDescription)
func processObject(forPID pid: pid_t) -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var inPID = pid
    var obj = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                     UInt32(MemoryLayout<pid_t>.size), &inPID, &size, &obj),
          "translate PID")
    return obj
}

func resolvePID(_ arg: String) -> pid_t {
    if let n = Int32(arg) { return n }
    // match by process name via pgrep
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", arg]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if let first = out.split(separator: "\n").first, let n = Int32(first) { return n }
    FileHandle.standardError.write("no process named \(arg)\n".data(using: .utf8)!)
    exit(1)
}

// ---- args -------------------------------------------------------------------

guard CommandLine.arguments.count == 3,
      let initialKnob = Float(CommandLine.arguments[2]) else {
    print("usage: appvolume <pid|name> <volume 0..2>")
    exit(2)
}

// Live volume state. knob is the 0..2 dial; target/current are the realtime gains.
var knob = min(max(initialKnob, 0), 2)
var targetGain = perceptualGain(knob)   // read by realtime IOProc
var currentGain = targetGain            // owned by IOProc, ramps toward target
let pid = resolvePID(CommandLine.arguments[1])
let procObj = processObject(forPID: pid)
guard procObj != 0 else { FileHandle.standardError.write("process has no audio object\n".data(using: .utf8)!); exit(1) }

// ---- tap --------------------------------------------------------------------

let tapDesc = CATapDescription(stereoMixdownOfProcesses: [procObj])
tapDesc.isPrivate = true
tapDesc.muteBehavior = CATapMuteBehavior.mutedWhenTapped   // original app output muted; we re-render

var tapID = AudioObjectID(0)
check(AudioHardwareCreateProcessTap(tapDesc, &tapID), "create tap")

// tap UID
var tapUIDUnmanaged: Unmanaged<CFString>?
var tapUIDSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
var tapUIDAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                            mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
check(AudioObjectGetPropertyData(tapID, &tapUIDAddr, 0, nil, &tapUIDSize, &tapUIDUnmanaged), "tap UID")
let tapUID = tapUIDUnmanaged!.takeRetainedValue()

// ---- aggregate device (default output + tap), private ----------------------

let outDev = getProp(AudioObjectID(kAudioObjectSystemObject),
                     kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
let outUID = deviceUID(outDev)

let aggUID = "appvolume-\(getpid())" as CFString
let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "appvolume",
    kAudioAggregateDeviceUIDKey as String: aggUID,
    kAudioAggregateDeviceIsPrivateKey as String: 1,
    kAudioAggregateDeviceIsStackedKey as String: 0,
    kAudioAggregateDeviceMainSubDeviceKey as String: outUID,
    kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outUID]],
    kAudioAggregateDeviceTapListKey as String: [[
        kAudioSubTapUIDKey as String: tapUID,
        kAudioSubTapDriftCompensationKey as String: 1,
    ]],
]

var aggID = AudioObjectID(0)
check(AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID), "create aggregate")

// ---- IO proc: input (tap) * gain -> output ---------------------------------

var ioProc: AudioDeviceIOProcID?
let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, nil) {
    (_, inInput, _, outOutput, _) in
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
    let outList = UnsafeMutableAudioBufferListPointer(outOutput)
    let n = min(inList.count, outList.count)
    let target = targetGain                      // sample once per cycle
    for i in 0..<n {
        let src = inList[i]
        let dst = outList[i]
        guard let s = src.mData, let d = dst.mData else { continue }
        let bytes = min(src.mDataByteSize, dst.mDataByteSize)
        let count = Int(bytes) / MemoryLayout<Float>.size
        let sp = s.assumingMemoryBound(to: Float.self)
        let dp = d.assumingMemoryBound(to: Float.self)
        // linear gain ramp currentGain->target across the buffer (click-free)
        var start = currentGain
        var step = count > 0 ? (target - currentGain) / Float(count) : 0
        vDSP_vrampmul(sp, 1, &start, &step, dp, 1, vDSP_Length(count))
    }
    currentGain = target
    // zero any extra output buffers
    if outList.count > n { for i in n..<outList.count {
        if let d = outList[i].mData { memset(d, 0, Int(outList[i].mDataByteSize)) } } }
}
check(ioStatus, "create IOProc")
check(AudioDeviceStart(aggID, ioProc), "start")

func showKnob() {
    let pct = Int((knob * 100).rounded())
    FileHandle.standardOutput.write("\rapp \(pid)  volume \(pct)%   (arrows adjust, q quit)   ".data(using: .utf8)!)
}

// ---- raw terminal for live keys --------------------------------------------

var origTerm = termios()
let isTTY = tcgetattr(0, &origTerm) == 0
if isTTY {
    var raw = origTerm
    raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON))
    tcsetattr(0, TCSANOW, &raw)
}
showKnob()

func setKnob(_ v: Float) {
    knob = min(max(v, 0), 2)
    targetGain = perceptualGain(knob)
    showKnob()
}

// ---- cleanup ----------------------------------------------------------------

func teardown() {
    if let p = ioProc { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    if isTTY { tcsetattr(0, TCSANOW, &origTerm) }
}

if isTTY {
    let keys = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
    keys.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 3)
        let n = read(0, &buf, 3)
        if n == 1 && (buf[0] == 0x71 || buf[0] == 0x03) {       // 'q' or Ctrl-C
            teardown(); print("\nstopped"); exit(0)
        }
        if n == 3 && buf[0] == 0x1b && buf[1] == 0x5b {         // arrow: ESC [ A/B
            if buf[2] == 0x41 { setKnob(knob + 0.05) }          // up
            if buf[2] == 0x42 { setKnob(knob - 0.05) }          // down
        }
    }
    keys.resume()
}

signal(SIGINT, SIG_IGN)
let sigsrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigsrc.setEventHandler { teardown(); print("\nstopped"); exit(0) }
sigsrc.resume()
dispatchMain()
