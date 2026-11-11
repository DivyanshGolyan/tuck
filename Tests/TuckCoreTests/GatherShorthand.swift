@testable import TuckCore

extension MenuBar {
    /// One gather as the shell runs it: survey `rows` through `previous`, then observe.
    static func observe(_ rows: MenuRows, running: [AppProcess], readings: [AppReading], previous: MenuBar) -> MenuBar {
        observe(previous.survey(rows, running: running), readings: readings)
    }
}
