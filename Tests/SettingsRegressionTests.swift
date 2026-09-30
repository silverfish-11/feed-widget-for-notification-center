import Foundation

@main
struct SettingsRegressionTests {
    static var assertions = 0

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw Failure(description: message) }
    }

    /// A firing may be delivered even after cancellation to model a callback
    /// already queued on the run loop.
    final class ScheduledTimer {
        let interval: TimeInterval
        let action: () -> Void
        var cancelled = false

        init(interval: TimeInterval, action: @escaping () -> Void) {
            self.interval = interval
            self.action = action
        }

        func fire() { action() }
    }

    final class Clock {
        var timers: [ScheduledTimer] = []

        func schedule(interval: TimeInterval, action: @escaping () -> Void) -> FeedRefreshScheduler.Cancel {
            let timer = ScheduledTimer(interval: interval, action: action)
            timers.append(timer)
            return { timer.cancelled = true }
        }
    }

    static func main() throws {
        let suite = "FeedBarSettingsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FeedSettings(defaults: defaults)
        let preferenceKey = "feedbar_refresh_minutes"

        try expect(settings.refreshMinutes == 5 && settings.refreshInterval == 300,
                   "An existing installation without the new preference must keep five-minute refresh")
        try expect(settings.automaticallyRefreshes, "Automatic refresh must remain the default")
        for minutes in FeedSettings.refreshOptions {
            settings.refreshMinutes = minutes
            let reloaded = FeedSettings(defaults: UserDefaults(suiteName: suite)!)
            try expect(reloaded.refreshMinutes == minutes, "The selected interval must persist across settings instances")
            try expect(reloaded.automaticallyRefreshes == (minutes != 0), "Manual mode must disable automatic refresh")
            try expect(reloaded.refreshInterval == (minutes == 0 ? nil : TimeInterval(minutes * 60)),
                       "Timer intervals must use seconds and manual mode must have no timer interval")
        }
        for invalid in [-1, 1, 7, Int.max] {
            settings.refreshMinutes = invalid
            try expect(settings.refreshMinutes == 5 && defaults.integer(forKey: preferenceKey) == 5,
                       "Unsupported writes must persist the five-minute default")
        }
        for invalid: Any in ["manual", false, true, 5.5, -30, Int.max, Data([1, 2])] {
            defaults.set(invalid, forKey: preferenceKey)
            try expect(settings.refreshMinutes == 5 && settings.refreshInterval == 300,
                       "Malformed persisted values must not accidentally select manual mode or another interval")
        }
        defaults.removeObject(forKey: preferenceKey)
        try expect(settings.refreshMinutes == 5, "Removing the preference must restore the existing default")

        let clock = Clock()
        var refreshes = 0
        let scheduler = FeedRefreshScheduler(settings: settings, schedule: clock.schedule) { refreshes += 1 }
        scheduler.start()
        try expect(refreshes == 1 && clock.timers.count == 1 && clock.timers[0].interval == 300,
                   "Automatic startup must schedule the selected interval and refresh once")
        clock.timers[0].fire()
        try expect(refreshes == 2, "An active timer must request a refresh")

        // A preference change must leave any work already requested alone.
        settings.refreshMinutes = 30
        scheduler.reschedule()
        try expect(refreshes == 2, "Rescheduling must not request or restart a collection")
        try expect(clock.timers[0].cancelled && clock.timers.count == 2 && clock.timers[1].interval == 1_800,
                   "Changing the interval must replace the old repeating timer")
        clock.timers[0].fire()
        try expect(refreshes == 2, "A stale callback from the replaced timer must be ignored")
        clock.timers[1].fire()
        try expect(refreshes == 3, "The replacement timer must request the next collection")

        settings.refreshMinutes = 0
        scheduler.reschedule()
        try expect(clock.timers[1].cancelled && clock.timers.count == 2 && refreshes == 3,
                   "Manual mode must remove the timer without triggering or cancelling collection")
        clock.timers[1].fire()
        try expect(refreshes == 3, "A callback queued before manual mode must not refresh")

        settings.refreshMinutes = 10
        scheduler.reschedule()
        try expect(clock.timers.count == 3 && clock.timers[2].interval == 600 && refreshes == 3,
                   "Leaving manual mode must schedule the interval without an immediate collection")
        scheduler.stop()
        try expect(clock.timers[2].cancelled, "Stopping must invalidate the active timer")
        clock.timers[2].fire()
        try expect(refreshes == 3, "A stopped scheduler must ignore queued callbacks")
        settings.refreshMinutes = 60
        scheduler.reschedule()
        try expect(clock.timers.count == 3 && refreshes == 3, "Rescheduling must not revive a stopped scheduler")
        scheduler.start()
        try expect(clock.timers.count == 4 && clock.timers[3].interval == 3_600 && refreshes == 4,
                   "Starting after a stop must use the current preference and refresh once")
        scheduler.stop()

        let manualClock = Clock()
        var manualRefreshes = 0
        settings.refreshMinutes = 0
        let manualScheduler = FeedRefreshScheduler(settings: settings, schedule: manualClock.schedule) { manualRefreshes += 1 }
        manualScheduler.start()
        manualScheduler.reschedule()
        try expect(manualClock.timers.isEmpty && manualRefreshes == 0,
                   "Manual startup must neither create a timer nor contact sources")
        manualScheduler.stop()

        let releaseClock = Clock()
        settings.refreshMinutes = 15
        var releasedRefreshes = 0
        var released: FeedRefreshScheduler? = FeedRefreshScheduler(settings: settings, schedule: releaseClock.schedule) {
            releasedRefreshes += 1
        }
        released?.start()
        released = nil
        try expect(releaseClock.timers[0].cancelled, "Releasing a scheduler must invalidate its timer")
        releaseClock.timers[0].fire()
        try expect(releasedRefreshes == 1, "Released schedulers must not receive queued timer callbacks")

        print("Passed \(assertions) isolated preference persistence and refresh scheduling checks.")
    }
}
