//
//  NotificationSettingsView.swift
//  LP
//
//  What LP reminds you about, and when. The list at the bottom shows what is actually
//  waiting with the system, so it is easy to check that reminders are set up.
//

import SwiftUI

struct NotificationSettingsView: View {

    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                PermissionRow(reminders: app.reminders)
                LabeledContent("Next reminder") {
                    if let next = app.reminders.plan.first {
                        Text("\(next.title) · \(UpcomingReminders.when(next.date))")
                            .lineLimit(1)
                    } else {
                        Text("None in the next 7 days")
                    }
                }
            }

            Section {
                Toggle("Remind me when a task or card is due", isOn: $settings.remindsDueItems)
                DatePicker("Reminder time", selection: timeBinding($settings.dueReminderTime), displayedComponents: .hourAndMinute)
                    .disabled(!settings.remindsDueItems)
            } header: {
                Text("Tasks and Cards")
            } footer: {
                Text("A task or card with its own time is reminded then. Write the time after the date, like 📅\u{00A0}2026-11-20\u{00A0}14:00, or add @@{14:00} to a card.")
            }

            Section {
                Picker("Alert before events", selection: leadBinding) {
                    Text("Off").tag(-1)
                    Text("At start time").tag(0)
                    ForEach(ReminderSettings.leadChoices.filter { $0 > 0 }, id: \.self) { minutes in
                        Text(minutes == 60 ? "1 hour before" : "\(minutes) minutes before").tag(minutes)
                    }
                }
                Toggle("Include Apple Calendar events", isOn: $settings.includesAppleCalendarEvents)
                    .disabled(settings.eventLeadMinutes == nil)
            } header: {
                Text("Calendar")
            } footer: {
                Text("Apple Calendar already alerts for its own events.")
            }

            Section {
                Toggle("Send a summary of the day", isOn: $settings.sendsDailySummary)
                DatePicker("Summary time", selection: timeBinding($settings.summaryTime), displayedComponents: .hourAndMinute)
                    .disabled(!settings.sendsDailySummary)
            } header: {
                Text("Daily Summary")
            } footer: {
                Text("What is due, what is overdue and what is on your calendar. Days with nothing on are skipped.")
            }

            Section {
                UpcomingReminders(plan: app.reminders.plan, hasWorkspace: app.workspace != nil)
            } header: {
                Text("Coming Up")
            }
        }
        .formStyle(.grouped)
        // Scrolls rather than growing past the height of a small screen.
        .frame(height: 620)
        .task {
            await app.reminders.refreshPermission()
            app.updateReminders()
        }
    }

    private var leadBinding: Binding<Int> {
        Binding {
            app.settings.eventLeadMinutes ?? -1
        } set: { value in
            app.settings.eventLeadMinutes = value < 0 ? nil : value
        }
    }

    private func timeBinding(_ time: Binding<TimeOfDay>) -> Binding<Date> {
        Binding {
            time.wrappedValue.date(on: .today)
        } set: { date in
            time.wrappedValue = TimeOfDay(date)
        }
    }
}

// MARK: - Permission

private struct PermissionRow: View {
    let reminders: ReminderCenter

    var body: some View {
        switch reminders.permission {
        case .allowed:
            LabeledContent("Notifications") {
                Label("On", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.lpGood)
                    .labelStyle(.titleAndIcon)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Label("Notifications are turned off for LP", systemImage: "bell.slash")
                    .foregroundStyle(Color.lpWarning)
                Text("Turn on Allow Notifications for LP in System Settings → Notifications.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { reminders.openSystemSettings() }
            }
            .padding(.vertical, 2)
        case .notAsked:
            LabeledContent {
                Button("Allow Notifications…") { Task { await reminders.requestPermission() } }
            } label: {
                Text("Notifications")
                Text("LP needs your permission to show reminders.")
            }
        case .unknown:
            LabeledContent("Notifications") { ProgressView().controlSize(.small) }
        }
    }
}

// MARK: - Coming up

private struct UpcomingReminders: View {
    let plan: [PlannedReminder]
    let hasWorkspace: Bool

    private let shown = 8

    var body: some View {
        if plan.isEmpty {
            Text(hasWorkspace ? "Nothing to remind you about in the next 7 days." : "Open a workspace to see its reminders.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(plan.prefix(shown)) { reminder in
                HStack(spacing: 10) {
                    Image(systemName: symbol(for: reminder.kind))
                        .foregroundStyle(Color.lpInkSecondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    (Text(reminder.title) + Text("  \(reminder.subtitle)").foregroundStyle(.secondary))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(Self.when(reminder.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if plan.count > shown {
                Text("and \(plan.count - shown) more in the next 7 days")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func symbol(for kind: PlannedReminder.Kind) -> String {
        switch kind {
        case .task: return "checkmark.circle"
        case .event: return "calendar"
        case .summary: return "sun.max"
        }
    }

    /// "Today 9:00", "Tomorrow 8:30", "Nov 20 14:00".
    static func when(_ date: Date) -> String {
        "\(Day(date).relativeTitle) \(date.formatted(date: .omitted, time: .shortened))"
    }
}
