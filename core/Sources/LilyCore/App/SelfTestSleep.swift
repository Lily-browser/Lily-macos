import AppKit

/// "Sleep Tab" frees a background tab's memory on demand: the tab on screen can't be put to sleep, a background web page can,
/// and the sleeping tab stays in the list.
@MainActor
enum SleepProbe {
    static func run(window: BrowserWindowController) async -> (ok: Bool, detail: JSONValue) {
        let background = window.tabs.create(url: nil, activate: false)
        background.load(URL(string: "https://localhost:9/sleep-probe")!)
        let front = window.tabs.create(url: nil)
        front.load(URL(string: "https://localhost:9/sleep-probe-front")!)
        let model = window.model
        let backgroundCan = model.canSleep(background.id)
        let frontCan = model.canSleep(front.id)
        model.sleepTabs([background.id, front.id])
        let slept = background.isSleeping
        let frontAwake = !front.isSleeping
        let stillListed = window.tabs.tab(background.id) != nil
        model.toast = nil
        window.tabs.close(background.id)
        window.tabs.close(front.id)
        return (backgroundCan && !frontCan && slept && frontAwake && stillListed,
                ["backgroundCanSleep": .bool(backgroundCan), "frontCannotSleep": .bool(!frontCan), "backgroundSlept": .bool(slept),
                 "frontStayedAwake": .bool(frontAwake), "stillListed": .bool(stillListed)])
    }
}
