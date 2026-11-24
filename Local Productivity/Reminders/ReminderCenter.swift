//
//  ReminderCenter.swift
//  LP
//
//  Hands the planned reminders to macOS and passes back what the person did with them.
//  Notifications wait with the system, so they arrive even when LP is not running; LP plans
//  again whenever something changes while it runs.
//

import AppKit
import UserNotifications

/// What the person did with a delivered reminder.
nonisolated struct ReminderResponse: Sendable {
    enum Action: Sendable { case open, complete, snoozeHour, snoozeTomorrow }

    var action: Action
    var kind: PlannedReminder.Kind
    var title: String
    var subtitle: String
    var body: String
    var info: [String: String]
}

/// Identifiers shared with the system.
nonisolated enum ReminderIDs {
    static let taskCategory = "LP_TASK"
    static let eventCategory = "LP_EVENT"
    static let summaryCategory = "LP_SUMMARY"
    static let done = "LP_DONE"
    static let snoozeHour = "LP_SNOOZE_HOUR"
    static let snoozeTomorrow = "LP_SNOOZE_TOMORROW"
    /// Planned reminders, replaced each time LP plans.
    static let plannedPrefixes = ["lp.task.", "lp.event.", "lp.summary."]
    /// Snoozed reminders, which planning leaves alone.
    static let snoozePrefix = "lp.snooze."

    static func category(for kind: PlannedReminder.Kind) -> String {
        switch kind {
        case .task: return taskCategory
        case .event: return eventCategory
        case .summary: return summaryCategory
        }
    }
}

@Observable
final class ReminderCenter {

    enum Permission: Equatable {
        case unknown, notAsked, allowed, denied
    }

    private(set) var permission: Permission = .unknown
    /// What LP last planned, soonest first. Shown in Settings so it can be checked.
    private(set) var plan: [PlannedReminder] = []
    /// For UI snapshots and previews: plans as usual but never touches the system.
    let isDryRun: Bool
    /// Called on the main actor when the person taps a reminder or one of its buttons.
    @ObservationIgnored var onResponse: ((ReminderResponse) -> Void)?

    @ObservationIgnored private var delegate: ReminderDelegate?
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    init(dryRun: Bool) {
        isDryRun = dryRun
        guard !dryRun else {
            permission = .notAsked
            return
        }
        let delegate = ReminderDelegate { [weak self] response in
            Task { @MainActor [weak self] in self?.onResponse?(response) }
        }
        self.delegate = delegate
        let center = UNUserNotificationCenter.current()
        // Set before launch finishes, so a reminder that launched LP is not missed.
        center.delegate = delegate
        center.setNotificationCategories(Self.categories)
        Task { await refreshPermission() }
    }

    // MARK: Permission

    #if DEBUG
    /// Lets UI snapshots show each permission state.
    func showPermissionForSnapshots(_ value: Permission) {
        permission = value
    }
    #endif

    func refreshPermission() async {
        guard !isDryRun else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        permission = Self.permission(from: status)
    }

    /// Asks once; afterwards the system remembers the answer and the person changes it in
    /// System Settings.
    func requestPermission() async {
        guard !isDryRun else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshPermission()
        // Whatever was planned while waiting can now be scheduled.
        update(with: plan)
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func permission(from status: UNAuthorizationStatus) -> Permission {
        switch status {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .unknown
        }
    }

    // MARK: Scheduling

    /// Makes the reminders waiting with the system match `planned`: stale ones are removed and
    /// new ones added; ones already waiting are left as they are.
    func update(with planned: [PlannedReminder]) {
        plan = planned
        guard !isDryRun, isOn else { return }
        // One change at a time: the previous update or cleanup finishes (an add in flight included) first.
        let previous = updateTask
        previous?.cancel()
        updateTask = Task {
            await previous?.value
            guard !Task.isCancelled, isOn else { return }
            let center = UNUserNotificationCenter.current()
            await refreshPermission()
            guard !Task.isCancelled, isOn else { return }
            // shortcut: a switch-off while macOS's first permission question is open waits for the answer; it's asked once.
            if permission == .notAsked, !planned.isEmpty {
                // Asked for the first time when there is something to remind about.
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                await refreshPermission()
            }
            guard permission == .allowed, !Task.isCancelled else { return }

            let waiting = await center.pendingNotificationRequests().map(\.identifier)
            let wanted = Set(planned.map(\.id))
            let stale = waiting.filter { id in ReminderIDs.plannedPrefixes.contains { id.hasPrefix($0) } && !wanted.contains(id) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }

            // Snoozed reminders keep their place within the system's limit.
            let snoozed = waiting.filter { $0.hasPrefix(ReminderIDs.snoozePrefix) }.count
            let present = Set(waiting)
            for reminder in planned.prefix(max(0, ReminderPlanner.systemLimit - snoozed)) where !present.contains(reminder.id) {
                guard !Task.isCancelled else { return }
                try? await center.add(Self.request(id: reminder.id, kind: reminder.kind, title: reminder.title,
                                                   subtitle: reminder.subtitle, body: reminder.body,
                                                   info: reminder.info, date: reminder.date))
            }
        }
    }

    /// Settings → Notifications' switch, as last set. While off nothing is scheduled or snoozed.
    private(set) var isOn = true

    /// Turns LP's reminders on again (the next update plans them), or off: everything LP has
    /// waiting with the system is cancelled — planned reminders and snoozes alike, whatever the
    /// permission — and an update already under way is stopped first, so it can't bring them back.
    /// Notifications already shown stay in Notification Center.
    func setOn(_ on: Bool) {
        isOn = on
        guard !on else { return }
        plan = []
        guard !isDryRun else { return }
        let previous = updateTask
        previous?.cancel()
        // Every pending notification LP has is a reminder or a snooze: all go — once now, and again
        // after any add in flight, until macOS (which removes them in the background) shows none.
        // Updates and snoozes queue behind this, so a plan made after switching back on survives.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        updateTask = Task {
            await previous?.value
            // A separate task: a later update cancelling this one must not cut the cleanup short.
            await Task {
                let center = UNUserNotificationCenter.current()
                // shortcut: gives up after ~2 s if macOS still lists some; the next switch-off or quit tries again.
                for _ in 0..<40 {
                    center.removeAllPendingNotificationRequests()
                    if await center.pendingNotificationRequests().isEmpty { return }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }.value
        }
    }

    /// Cancels every notification LP has waiting, now (quitting while switched off).
    func cancelAllNow() {
        guard !isDryRun else { return }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    /// Shows the same reminder again later.
    func snooze(_ response: ReminderResponse, until date: Date) {
        guard !isDryRun, isOn else { return }
        let request = Self.request(id: ReminderIDs.snoozePrefix + UUID().uuidString, kind: response.kind,
                                   title: response.title, subtitle: response.subtitle, body: response.body,
                                   info: response.info, date: date)
        // In the same queue as updates and switch-offs, so a switch-off's cleanup comes after it.
        let previous = updateTask
        updateTask = Task {
            await previous?.value
            guard isOn else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private static func request(id: String, kind: PlannedReminder.Kind, title: String, subtitle: String, body: String,
                                info: [String: String], date: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = kind.rawValue
        content.categoryIdentifier = ReminderIDs.category(for: kind)
        content.userInfo = info
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    private static var categories: Set<UNNotificationCategory> {
        let done = UNNotificationAction(identifier: ReminderIDs.done, title: "Mark as Done", options: [])
        let hour = UNNotificationAction(identifier: ReminderIDs.snoozeHour, title: "Remind Me in an Hour", options: [])
        let tomorrow = UNNotificationAction(identifier: ReminderIDs.snoozeTomorrow, title: "Remind Me Tomorrow", options: [])
        return [
            UNNotificationCategory(identifier: ReminderIDs.taskCategory, actions: [done, hour, tomorrow], intentIdentifiers: []),
            UNNotificationCategory(identifier: ReminderIDs.eventCategory, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: ReminderIDs.summaryCategory, actions: [], intentIdentifiers: []),
        ]
    }
}

// MARK: - System callbacks

/// Receives the system's callbacks, which can arrive on any thread, and passes them on as
/// plain values.
nonisolated final class ReminderDelegate: NSObject, UNUserNotificationCenterDelegate {

    private let forward: @Sendable (ReminderResponse) -> Void

    init(forward: @escaping @Sendable (ReminderResponse) -> Void) {
        self.forward = forward
    }

    /// Reminders are shown even while LP is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        defer { completionHandler() }
        let content = response.notification.request.content
        let action: ReminderResponse.Action
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier: action = .open
        case ReminderIDs.done: action = .complete
        case ReminderIDs.snoozeHour: action = .snoozeHour
        case ReminderIDs.snoozeTomorrow: action = .snoozeTomorrow
        default: return
        }
        var info: [String: String] = [:]
        for (key, value) in content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        let kind = info[ReminderInfo.kind].flatMap(PlannedReminder.Kind.init(rawValue:)) ?? .summary
        forward(ReminderResponse(action: action, kind: kind, title: content.title, subtitle: content.subtitle,
                                 body: content.body, info: info))
    }
}
