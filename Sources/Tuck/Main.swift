import AppKit
import ApplicationServices
import TuckCore

@main
struct TuckMain {
    static func argument(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    @MainActor static func main() {
        let defaultConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tuck/config.json")
        let configURL = argument("--config").map { URL(fileURLWithPath: $0) } ?? defaultConfig
        if CommandLine.arguments.contains("--help") {
            print("""
            Tuck — click to reveal/hide menu bar icons
            Usage: Tuck [--config PATH] [--no-prompt]
                   Tuck --inventory
                   Tuck --validate PATH
            Default config: ~/.config/tuck/config.json
            Right-click the control to open the config or quit.
            """)
            return
        }
        if let path = argument("--validate") {
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                let data = try handle.read(upToCount: ConfigStore.maximumBytes + 1) ?? Data()
                guard data.count <= ConfigStore.maximumBytes else { throw ConfigStoreError.tooLarge }
                let config = try JSONDecoder().decode(TuckConfig.self, from: data)
                try config.validate()
                print("Valid: \(config.visible.count) visible, \(config.hidden.count) hidden")
            } catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--inventory") {
            let app = NSApplication.shared
            Task { @MainActor in
                do {
                    let rows = try await Gather.rows(on: SerialWorker(label: "local.tuck.inventory"),
                                                     adding: standInAnchors(Display.current()))
                    let bar = try await Gather.bar(rows, previous: .none, running: RunningApps().current(),
                                                   reach: .full, reader: AppReader())
                    let issues = bar.rows.fault.map { [WorkIssue(recovery: .retry, message: $0)] } ?? bar.issues
                    let counts = Dictionary(bar.roles.map { ($0.identity, 1) }, uniquingKeysWith: +)
                    let icons = bar.roles.filter { counts[$0.identity] == 1 }.compactMap { role -> [String: Any]? in
                        let rows = (bar.referenceRow.map { [$0] } ?? []) + Array(bar.rows.rows.indices)
                        guard let row = rows.first(where: { bar.frame(of: role, row: $0) != nil }),
                              let key = role.members[row], let frame = bar.frame(of: role, row: row) else { return nil }
                        return ["id": role.identity.key, "bundleID": role.identity.bundle, "label": role.label,
                                "item": role.identity.item as Any? ?? NSNull(), "movable": role.movable,
                                "windowID": key.number, "x": frame.minX, "width": frame.width]
                    }
                    let data: [String: Any] = ["accessibility": AXIsProcessTrusted(), "complete": bar.complete,
                        "ambiguous": issues.map(\.message), "issues": issues.map { ["recovery": $0.recovery.rawValue, "message": $0.message] },
                        "icons": icons]
                    let json = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
                    FileHandle.standardOutput.write(json); print(""); exit(0)
                } catch { fputs("\(error)\n", stderr); exit(1) }
            }
            app.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(configURL: configURL)
        app.delegate = delegate
        app.run()
    }

    /// `--inventory` has no status items of its own, and rows are anchored by Tuck's
    /// control. It stands in a control and separator just past the right edge of each
    /// display's menu row, where they cover no icon.
    static func standInAnchors(_ displays: [Display]) -> [StatusWindow] {
        let edges = Dictionary(displays.map { ($0.frame.minY, $0.frame.maxX) }, uniquingKeysWith: max).sorted { $0.key < $1.key }
        return edges.enumerated().flatMap { index, edge -> [StatusWindow] in
            let number = UInt32(index * 2 + 1)
            return [StatusWindow(key: WindowKey(pid: getpid(), number: number),
                                 frame: CGRect(x: edge.value, y: edge.key, width: 20, height: 24), onScreen: true,
                                 title: index == 0 ? OwnItem.control.title : ""),
                    StatusWindow(key: WindowKey(pid: getpid(), number: number + 1),
                                 frame: CGRect(x: edge.value + 20, y: edge.key, width: 4, height: 24), onScreen: true,
                                 title: index == 0 ? OwnItem.separator.title : "")]
        }
    }
}
