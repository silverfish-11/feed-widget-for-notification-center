import Foundation
import CoreFoundation

/// Preferences belong to the host app. The widget reads only saved feed data.
final class FeedSettings {
    static let refreshOptions: [Int] = [0, 5, 10, 15, 30, 60]
    private static let refreshMinutesKey = "feedbar_refresh_minutes"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Zero means manual refresh. Missing or unsupported values retain the
    /// existing five-minute behavior, including malformed persisted values.
    var refreshMinutes: Int {
        get {
            guard let value = defaults.object(forKey: Self.refreshMinutesKey) as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return 5 }
            return Self.refreshOptions.first { Double($0) == value.doubleValue } ?? 5
        }
        set {
            defaults.set(Self.refreshOptions.contains(newValue) ? newValue : 5, forKey: Self.refreshMinutesKey)
        }
    }

    var automaticallyRefreshes: Bool { refreshMinutes != 0 }

    var refreshInterval: TimeInterval? {
        let minutes = refreshMinutes
        return minutes == 0 ? nil : TimeInterval(minutes * 60)
    }
}

/// Owns only the repeating timer. Changing preferences never cancels or restarts
/// a collector attempt that is already running.
final class FeedRefreshScheduler {
    typealias Cancel = () -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Cancel

    private let settings: FeedSettings
    private let schedule: Schedule
    private let refresh: () -> Void
    private var cancelTimer: Cancel?
    private var started = false
    private var generation = UUID()

    init(settings: FeedSettings, schedule: @escaping Schedule = FeedRefreshScheduler.scheduleTimer,
         refresh: @escaping () -> Void) {
        self.settings = settings
        self.schedule = schedule
        self.refresh = refresh
    }

    func start() {
        started = true
        reschedule()
        if settings.automaticallyRefreshes { refresh() }
    }

    func reschedule() {
        // Ignore callbacks already queued by the previous timer as well as
        // future firings. This matters when switching to manual refresh.
        generation = UUID()
        cancelTimer?()
        cancelTimer = nil
        guard started, let interval = settings.refreshInterval else { return }
        let expectedGeneration = generation
        cancelTimer = schedule(interval) { [weak self] in
            guard let self, self.started, self.generation == expectedGeneration,
                  self.settings.automaticallyRefreshes else { return }
            self.refresh()
        }
    }

    func stop() {
        started = false
        generation = UUID()
        cancelTimer?()
        cancelTimer = nil
    }

    deinit { cancelTimer?() }

    private static func scheduleTimer(interval: TimeInterval, action: @escaping () -> Void) -> Cancel {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
