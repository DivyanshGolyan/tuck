import AppKit
import CoreGraphics
import Foundation

struct BarWindow {
    let id: UInt32
    let frame: CGRect
    let title: String
}
struct GeometrySample {
    let began: UInt64
    let ended: UInt64
    let width: CGFloat?
    let persisted: Bool?
    let adopted: Bool?
}
struct ClickReceipt {
    let id: Int
    let mouseUpNS: UInt64
    let acceptedNS: UInt64
    let committedNS: UInt64?
    let showHidden: Bool?
}
func matchingReceipt(_ receipts: [ClickReceipt], timestamp: UInt64) -> ClickReceipt? {
    guard timestamp > 0 else { return nil }
    let matches = receipts.filter { receipt in
        receipt.mouseUpNS == timestamp && receipt.acceptedNS >= timestamp
            && (receipt.committedNS.map { $0 >= receipt.acceptedNS } ?? true)
    }
    return matches.count == 1 ? matches[0] : nil
}
func confirmedSample(_ samples: [GeometrySample], receipt: ClickReceipt) -> GeometrySample? {
    guard let committed = receipt.committedNS, let expected = receipt.showHidden else { return nil }
    return samples.first {
        guard $0.began >= committed, $0.persisted == expected, let width = $0.width else { return false }
        return expected ? width < 100 : width > 100
    }
}
struct Click {
    let sequence: Int
    let started: UInt64
    let eventTimestamp: UInt64
    let initialWidth: CGFloat?
    let row: CGFloat
    var samples: [GeometrySample] = []
    var receipt: ClickReceipt?
    var lastStage = ""
}
final class VisibilityWatcher {
    let pid: Int32
    let configURL: URL
    let runtimeURL: URL
    let output: FileHandle
    let queue = DispatchQueue(label: "local.tuck.passive-measurement", qos: .userInitiated)
    var tap: CFMachPort?
    var timer: DispatchSourceTimer?
    var processSource: DispatchSourceProcess?
    var current: Click?
    var sequence = 0
    let menuRows: [CGFloat]

    init(pid: Int32, configURL: URL, outputURL: URL) throws {
        self.pid = pid; self.configURL = configURL
        runtimeURL = configURL.deletingLastPathComponent().appendingPathComponent("runtime.json")
        menuRows = NSScreen.screens.compactMap {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(id.uint32Value).minY
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        output = try FileHandle(forWritingTo: outputURL)
    }
    static func json(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    func record(_ value: [String: Any]) {
        var line = value
        line["wallTime"] = ISO8601DateFormatter().string(from: Date())
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(10); try? output.write(contentsOf: data)
    }
    func windows() -> [BarWindow] {
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        return all.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? Int32 == pid,
                  info[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.statusWindow)),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  let id = info[kCGWindowNumber as String] as? UInt32 else { return nil }
            return BarWindow(id: id, frame: frame, title: info[kCGWindowName as String] as? String ?? "")
        }
    }
    func clicked(at point: CGPoint, timestamp: UInt64, received: UInt64, sourceTag: Int64) {
        let all = windows()
        guard let source = all.first(where: { $0.title == "TuckControl" }) else { return }
        let hits = all.filter { abs($0.frame.width-source.frame.width) < 2 && $0.frame.contains(point) }
        guard hits.count == 1 else { return }
        if let previous = current {
            record(["event": "superseded", "click": previous.sequence,
                    "reason": "Another mouse release arrived before a correlated state confirmation",
                    "acceptedClickID": previous.receipt?.id as Any? ?? NSNull(),
                    "elapsedMS": Double(received-previous.started)/1_000_000])
        }
        sequence += 1
        let started = timestamp > 0 && timestamp <= received ? timestamp : received
        let separators = all.filter {
            abs($0.frame.minY-hits[0].frame.minY) < 2 && abs($0.frame.width-source.frame.width) >= 2
        }
        let initialWidth = separators.count == 1 ? separators[0].frame.width : nil
        current = Click(sequence: sequence, started: started, eventTimestamp: timestamp,
                        initialWidth: initialWidth, row: hits[0].frame.minY)
        record(["event": "click", "click": sequence, "mouseUpNS": timestamp, "sourceTag": sourceTag,
                "initialWidth": initialWidth as Any? ?? NSNull(),
                "deliveryMS": Double(received-started)/1_000_000,
                "observerQueueMS": Double(DispatchTime.now().uptimeNanoseconds-received)/1_000_000,
                "row": hits[0].frame.minY])
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.sample() }
            timer = source; source.resume()
        }
    }
    func sample() {
        guard var click = current else { return }
        let began = DispatchTime.now().uptimeNanoseconds
        let config = Self.json(configURL)
        let runtime = Self.json(runtimeURL)
        guard runtime["pid"] as? Int32 == pid else { return }
        let receipts = (runtime["clickTraces"] as? [[String: Any]] ?? []).compactMap { value -> ClickReceipt? in
            guard let id = value["id"] as? Int,
                  let timestamp = (value["mouseUpNS"] as? NSNumber)?.uint64Value,
                  let accepted = (value["acceptedNS"] as? NSNumber)?.uint64Value else { return nil }
            return ClickReceipt(id: id, mouseUpNS: timestamp, acceptedNS: accepted,
                                committedNS: (value["committedNS"] as? NSNumber)?.uint64Value,
                                showHidden: value["showHidden"] as? Bool)
        }
        click.receipt = matchingReceipt(receipts, timestamp: click.eventTimestamp)
        let all = windows()
        let controlWidth = all.first(where: { $0.title == "TuckControl" })?.frame.width
        let separators = all.filter { window in
            abs(window.frame.minY-click.row) < 2 && controlWidth.map { abs(window.frame.width-$0) >= 2 } == true
        }
        let width = separators.count == 1 ? separators[0].frame.width : nil
        let ended = DispatchTime.now().uptimeNanoseconds
        click.samples.append(GeometrySample(began: began, ended: ended, width: width,
                                            persisted: config["showHidden"] as? Bool,
                                            adopted: runtime["showHidden"] as? Bool))
        if click.samples.count > 1024 { click.samples.removeFirst() }
        let elapsed = Double(ended-click.started)/1_000_000
        let stage = ["phase", "waiting", "error", "pending", "showHidden", "separatorWidth", "fastHides", "fastHideReason"].map { String(describing: runtime[$0] ?? "nil") }.joined(separator: "|")
        if stage != click.lastStage {
            click.lastStage = stage
            record(["event": "stage", "click": click.sequence, "elapsedMS": elapsed,
                    "phase": runtime["phase"] ?? NSNull(), "waiting": runtime["waiting"] ?? NSNull(),
                    "error": runtime["error"] ?? NSNull(), "pending": runtime["pending"] ?? NSNull(),
                    "appShowHidden": runtime["showHidden"] ?? NSNull(), "physicalWidth": width as Any? ?? NSNull(),
                    "scanMS": runtime["scanMS"] ?? NSNull(), "visibilityCheckMS": runtime["visibilityCheckMS"] ?? NSNull(),
                    "fastHides": runtime["fastHides"] ?? NSNull(), "fastHideReason": runtime["fastHideReason"] ?? NSNull()])
        }
        current = click
        if let receipt = click.receipt, let sample = confirmedSample(click.samples, receipt: receipt),
           let expected = receipt.showHidden, let committed = receipt.committedNS {
            let transition = click.initialWidth.map { expected ? $0 > 100 : $0 < 100 } ?? false
            record(["event": "result", "click": click.sequence, "acceptedClickID": receipt.id,
                    "showHidden": expected, "transitionObserved": transition,
                    "acceptedMS": Double(receipt.acceptedNS-click.started)/1_000_000,
                    "committedMS": Double(committed-click.started)/1_000_000,
                    "elapsedMS": Double(sample.ended-click.started)/1_000_000,
                    "receiptObservedMS": elapsed, "samplingIntervalMS": 10,
                    "physicalWidth": sample.width as Any? ?? NSNull(),
                    "measurement": transition ? "Correlated config commit and physical transition" : "State confirmation only; initial geometry already matched or was unavailable"])
            current = nil; timer?.cancel(); timer = nil
        } else if elapsed > 10_000 {
            record(["event": "timeout", "click": click.sequence,
                    "acceptedClickID": click.receipt?.id as Any? ?? NSNull(),
                    "reason": click.receipt == nil ? "No uniquely matching accepted click receipt" : "No committed matching physical state"])
            current = nil; timer?.cancel(); timer = nil
        }
    }

    func start() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let watcher = Unmanaged<VisibilityWatcher>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = watcher.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let point = event.location
            if type == .leftMouseUp && !event.flags.contains(.maskCommand)
                && event.getIntegerValueField(.eventSourceUserData) != 0x5455434B
                && watcher.menuRows.contains(where: { point.y >= $0 && point.y < $0+64 }) {
                let received = DispatchTime.now().uptimeNanoseconds, timestamp = event.timestamp
                let sourceTag = event.getIntegerValueField(.eventSourceUserData)
                watcher.queue.async { watcher.clicked(at: point, timestamp: timestamp, received: received, sourceTag: sourceTag) }
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.leftMouseUp.rawValue,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        queue.async { self.record(["event": "ready", "targetPID": self.pid,
            "showHidden": Self.json(self.configURL)["showHidden"] ?? NSNull(),
            "correlation": "App accepted-click timestamp and committed config receipt; no guessed direction", "sampling": "10ms only after a Tuck click; no input injected",
            "lifetime": "Until manually stopped or target Tuck exits; no idle polling"]) }
        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in
            self?.record(["event": "stopped", "reason": "target Tuck exited"])
            CFRunLoopStop(CFRunLoopGetMain())
        }
        processSource = process
        process.resume()
        return true
    }
}
let args = CommandLine.arguments
if args.count == 2 && args[1] == "--self-test" {
    let receipt = ClickReceipt(id: 1, mouseUpNS: 10_000_000, acceptedNS: 11_000_000,
                               committedNS: 20_000_000, showHidden: false)
    assert(matchingReceipt([receipt], timestamp: 10_000_000)?.id == 1)
    assert(matchingReceipt([receipt], timestamp: 0) == nil)
    assert(matchingReceipt([receipt, receipt], timestamp: 10_000_000) == nil)
    assert(matchingReceipt([receipt], timestamp: 15_000_000) == nil)
    assert(matchingReceipt([receipt], timestamp: 10_500_000) == nil)
    let reversed = ClickReceipt(id: 3, mouseUpNS: 10_000_000, acceptedNS: 9_000_000,
                                committedNS: 20_000_000, showHidden: false)
    let reversedCommit = ClickReceipt(id: 4, mouseUpNS: 10_000_000, acceptedNS: 11_000_000,
                                      committedNS: 10_500_000, showHidden: false)
    assert(matchingReceipt([reversed], timestamp: 10_000_000) == nil)
    assert(matchingReceipt([reversedCommit], timestamp: 10_000_000) == nil)
    let preexisting = GeometrySample(began: 12_000_000, ended: 13_000_000, width: 5016, persisted: false, adopted: false)
    let wrongState = GeometrySample(began: 21_000_000, ended: 22_000_000, width: 20, persisted: false, adopted: false)
    let confirmed = GeometrySample(began: 25_000_000, ended: 26_000_000, width: 5016, persisted: false, adopted: false)
    assert(confirmedSample([preexisting, wrongState], receipt: receipt) == nil)
    assert(confirmedSample([preexisting, wrongState, confirmed], receipt: receipt)?.ended == 26_000_000)
    let uncommitted = ClickReceipt(id: 2, mouseUpNS: 30_000_000, acceptedNS: 31_000_000, committedNS: nil, showHidden: nil)
    assert(confirmedSample([confirmed], receipt: uncommitted) == nil)
    print("PASS: receipt correlation, ambiguous/missing receipts, precommit exclusion, actual committed direction")
    exit(0)
}
guard args.count == 4, let pid = Int32(args[1]) else { fputs("Usage: watch PID CONFIG LOG\n", stderr); exit(2) }
let watcher = try VisibilityWatcher(pid: pid, configURL: URL(fileURLWithPath: args[2]), outputURL: URL(fileURLWithPath: args[3]))
guard watcher.start() else { fputs("Cannot start passive mouse listener. No events captured.\n", stderr); exit(3) }
CFRunLoopRun()
