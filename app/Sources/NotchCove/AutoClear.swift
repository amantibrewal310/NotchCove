import AppKit
import CCoveCore
import Combine
import Quartz

/// How long items stay on the shelf before being cleared automatically.
public enum AutoClear: Int, CaseIterable {
    case oneHour = 3_600
    case twelveHours = 43_200
    case oneDay = 86_400
    case sevenDays = 604_800
    case never = 0

    static let defaultsKey = "AutoClearSeconds"

    public static var current: AutoClear {
        get {
            guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return .twelveHours }
            return AutoClear(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .twelveHours
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    public var title: String {
        switch self {
        case .oneHour: "After 1 Hour"
        case .twelveHours: "After 12 Hours"
        case .oneDay: "After 1 Day"
        case .sevenDays: "After 7 Days"
        case .never: "Never"
        }
    }
}

/// Clears expired items without polling: one timer is armed for the next
/// expiry, and the shelf is also checked at launch and after the Mac wakes
/// (timers don't advance while it sleeps).
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

    /// Clears anything expired now, then arms the timer for the next item.
    func run() {
        let policy = AutoClear.current
        guard policy != .never else {
            timer?.invalidate()
            return
        }
        // Don't pull items out from under an interaction; try again shortly.
        if DragOutCoordinator.shared.isDragging || ItemActions.isSharing || QuickLookController.shared.isVisible {
            arm(after: 60)
            return
        }
        if cove_expire_older_than(UInt64(policy.rawValue)) > 0 {
            CoveEngine.shared.refresh()
            NotchWindowManager.shared.itemsRemoved()
        }
        reschedule()
    }

    private func reschedule() {
        let policy = AutoClear.current
        guard policy != .never else {
            timer?.invalidate()
            return
        }
        let next = cove_next_expiry(UInt64(policy.rawValue))
        guard next > 0 else {
            timer?.invalidate()
            return
        }
        arm(after: max(1, TimeInterval(next) - Date().timeIntervalSince1970 + 1))
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
