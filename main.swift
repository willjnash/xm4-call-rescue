// xm4-call-rescue
//
// Fixes the Sony WH-1000XM4 bug on macOS where taking the headphones off during a
// call makes the headset tear down the Bluetooth HFP voice link (SCO). CoreAudio
// keeps the device "running", so nothing re-creates the link when you put them
// back on and the call goes silent in both directions.
//
// How it works:
//   1. Tails the unified log for bluetoothd "voice disconnection" / "voice audio
//      connected" events to track whether the SCO link is up.
//   2. Every second, checks whether a Bluetooth input device (the HFP mic, which
//      only exists for headsets) is in use by some app, i.e. a call is active.
//   3. If a call is active and SCO has been down for ~0.3s, it briefly moves the
//      system default output and input off the headset and back (or onto it and back, if the headset isn't the default).
//      That makes coreaudiod re-create the voice link, typically within 0.5s.
//      Retries every 1.5s until the link comes back or the call ends.

import CoreAudio
import Foundation

// MARK: - Config

struct Config {
    var address: String? = nil      // e.g. "88:C9:E8:7A:F7:00"; nil = any headset
    var settle: TimeInterval = 0.3  // wait this long after a drop before acting
    var bounceHold: UInt32 = 100_000 // µs to hold the built-in device during a bounce
    var verbose = false
}

var config = Config()
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--address": config.address = args.next()?.uppercased()
    case "--settle": config.settle = TimeInterval(args.next() ?? "") ?? config.settle
    case "-v", "--verbose": config.verbose = true
    case "-h", "--help":
        print("usage: xm4-call-rescue [--address AA:BB:CC:DD:EE:FF] [--settle seconds] [-v]")
        exit(0)
    default:
        FileHandle.standardError.write("unknown argument: \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

func log(_ s: String) {
    let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                         formatOptions: [.withInternetDateTime])
    print("\(ts) \(s)")
    fflush(stdout)
}

// MARK: - CoreAudio helpers

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ sel: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getUInt32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var a = address(sel, scope)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = address(sel)
    var v: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let s = v else { return nil }
    return s.takeRetainedValue() as String
}

func allDevices() -> [AudioObjectID] {
    var a = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func hasStreams(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
    var a = address(kAudioDevicePropertyStreams, scope)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr && size > 0
}

func isBluetooth(_ dev: AudioObjectID) -> Bool {
    getUInt32(dev, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBluetooth
}

func isBuiltIn(_ dev: AudioObjectID) -> Bool {
    getUInt32(dev, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
}

func uid(_ dev: AudioObjectID) -> String { getString(dev, kAudioDevicePropertyDeviceUID) ?? "" }
func name(_ dev: AudioObjectID) -> String { getString(dev, kAudioObjectPropertyName) ?? "#\(dev)" }

/// Bluetooth device UIDs look like "88-C9-E8-7A-F7-00:input".
func matchesAddress(_ dev: AudioObjectID) -> Bool {
    guard let want = config.address else { return true }
    return uid(dev).uppercased().replacingOccurrences(of: "-", with: ":").hasPrefix(want)
}

/// A Bluetooth device with input streams is a headset in HFP mode. If some app is
/// doing IO on it, a call (or at least mic capture) is in progress.
func activeHeadsetInput() -> AudioObjectID? {
    allDevices().first { dev in
        isBluetooth(dev) && hasStreams(dev, kAudioObjectPropertyScopeInput) && matchesAddress(dev)
            && getUInt32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }
}

func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioObjectID {
    getUInt32(systemObject, sel) ?? 0
}

@discardableResult
func setDefaultDevice(_ sel: AudioObjectPropertySelector, _ dev: AudioObjectID) -> Bool {
    var a = address(sel)
    var v = dev
    return AudioObjectSetPropertyData(systemObject, &a, 0, nil,
                                      UInt32(MemoryLayout<AudioObjectID>.size), &v) == noErr
}

func builtIn(_ scope: AudioObjectPropertyScope) -> AudioObjectID? {
    allDevices().first { isBuiltIn($0) && hasStreams($0, scope) }
}

/// Briefly change the system default device and change it back. Moving the default
/// on or off the headset makes coreaudiod's Bluetooth driver re-evaluate the call
/// route and re-create the missing voice link. The calling app doesn't have to
/// follow the system default for this to work.
///  - default is the headset  -> built-in, then back
///  - default is something else -> the headset, then back
func bounce(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
            headset: AudioObjectID?) -> Bool {
    let current = defaultDevice(sel)
    let temp: AudioObjectID?
    if isBluetooth(current) && matchesAddress(current) {
        temp = builtIn(scope)
    } else {
        temp = headset
    }
    guard let other = temp, other != current else { return false }
    setDefaultDevice(sel, other)
    usleep(config.bounceHold)
    setDefaultDevice(sel, current)
    return true
}

/// The headset's output device (same Bluetooth address as its HFP input).
func headsetOutput(for input: AudioObjectID) -> AudioObjectID? {
    let base = uid(input).components(separatedBy: ":").first ?? ""
    return allDevices().first { dev in
        isBluetooth(dev) && hasStreams(dev, kAudioObjectPropertyScopeOutput) && uid(dev).hasPrefix(base)
    }
}

// MARK: - SCO state from the unified log

final class State {
    private let lock = NSLock()
    private var _scoUp = true
    private var _changedAt = Date.distantPast
    var scoUp: Bool { lock.withLock { _scoUp } }
    var changedAt: Date { lock.withLock { _changedAt } }
    func set(up: Bool) { lock.withLock { _scoUp = up; _changedAt = Date() } }
}
let state = State()

func startLogStream() -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    p.arguments = ["stream", "--style", "compact", "--predicate",
                   #"process == "bluetoothd" AND (eventMessage CONTAINS "voice disconnection event" OR eventMessage CONTAINS "voice audio connected event")"#]
    let pipe = Pipe()
    p.standardOutput = pipe
    var buffer = Data()
    pipe.fileHandleForReading.readabilityHandler = { h in
        let chunk = h.availableData
        if chunk.isEmpty { return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<nl], as: UTF8.self)
            buffer.removeSubrange(...nl)
            if let want = config.address, !line.uppercased().contains(want) { continue }
            if line.contains("voice disconnection event") {
                state.set(up: false)
                if config.verbose { log("SCO down") }
            } else if line.contains("voice audio connected event") {
                state.set(up: true)
                if config.verbose { log("SCO up") }
            }
        }
    }
    p.terminationHandler = { _ in
        log("log stream exited; quitting so launchd restarts us")
        exit(1)
    }
    try! p.run()
    return p
}

// MARK: - Main loop

let logProcess = startLogStream()
signal(SIGTERM) { _ in logProcess.terminate(); exit(0) }
signal(SIGINT) { _ in logProcess.terminate(); exit(0) }
log("xm4-call-rescue started (address: \(config.address ?? "any headset"))")

var attempts = 0
var nextAttempt = Date.distantPast
var dropAt = Date()

// Poll often so we react within ~0.5s of the drop. Each tick is a few cheap
// property reads; when the link is up it returns immediately.
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    let now = Date()
    guard !state.scoUp else {
        if attempts > 0 {
            log(String(format: "voice link restored after %d attempt(s), %.1fs after the drop",
                       attempts, now.timeIntervalSince(dropAt)))
        }
        attempts = 0
        return
    }
    guard let dev = activeHeadsetInput() else {
        // SCO is down but nobody is using the headset mic: call ended normally.
        attempts = 0
        return
    }
    if attempts == 0 { dropAt = state.changedAt }
    guard now.timeIntervalSince(state.changedAt) >= config.settle, now >= nextAttempt else { return }

    attempts += 1
    // In testing, the link only came back when BOTH defaults were bounced in the
    // same attempt (output then input): that makes the call app stop and restart
    // IO on the headset mic, which is what triggers eSCO re-creation.
    var actions: [String] = []
    if bounce(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeOutput,
              headset: headsetOutput(for: dev)) {
        actions.append("bounce-output")
    }
    if bounce(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeInput,
              headset: dev) {
        actions.append("bounce-input")
    }
    log("voice link down during call on \(name(dev)); attempt \(attempts): "
        + (actions.isEmpty ? "nothing could be done" : actions.joined(separator: ", ")))
    // Retry every 1.5s for the first few tries (headphones may still be off your
    // head), then every 5s.
    nextAttempt = now.addingTimeInterval(attempts < 6 ? 1.5 : 5)
}
RunLoop.main.run()
