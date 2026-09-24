import AppKit
import Combine

/// How long items stay on the shelf before being cleared automatically.
enum AutoClear: Int, Setting {
    case oneHour = 3_600
    case twelveHours = 43_200
    case oneDay = 86_400
    case sevenDays = 604_800
    case never = 0

    static let defaultsKey = "AutoClearSeconds"
    static let defaultValue = AutoClear.twelveHours

    var title: String {
        switch self {
        case .oneHour: "After 1 Hour"
        case .twelveHours: "After 12 Hours"
        case .oneDay: "After 1 Day"
        case .sevenDays: "After 7 Days"
        case .never: "Never"
        }
    }
}

/// Clears expired items with one timer armed for the next expiry, plus a
/// check at launch and on wake (timers don't advance during sleep).
@MainActor
final class AutoClearScheduler {
    static let shared = AutoClearScheduler()

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        CoveEngine.shared.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reschedule() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.run() }
            .store(in: &cancellables)
        run()
    }

    func setPolicy(_ policy: AutoClear) {
        AutoClear.current = policy
        run()
    }

    func run() {
        let policy = AutoClear.current
        if policy != .never {
            // Don't pull items out from under an interaction; try again shortly.
            if NotchWindowManager.shared.isBusy { return arm(after: 60) }
            if CoveEngine.shared.expire(olderThan: policy.rawValue) > 0 {
                NotchWindowManager.shared.itemsRemoved()
            }
        }
        reschedule()
    }

    private func reschedule() {
        let policy = AutoClear.current
        guard policy != .never, let next = CoveEngine.shared.nextExpiry(maxAge: policy.rawValue) else {
            timer?.invalidate()
            return
        }
        arm(after: max(1, next.timeIntervalSinceNow + 1))
    }

    private func arm(after delay: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        // Precision doesn't matter here; let the system batch the wakeup.
        timer.tolerance = min(60, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
