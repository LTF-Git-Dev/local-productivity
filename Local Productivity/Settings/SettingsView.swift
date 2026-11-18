//
//  SettingsView.swift
//  LP
//
//  The Settings window (⌘,), one tab per area.
//

import SwiftUI

struct SettingsView: View {

    enum Tab: String {
        case general, editor, notifications, calendars, sharing
    }

    private static let tabKey = "settings.tab"

    /// Opens Settings on a particular tab the next time it appears.
    static func select(_ tab: Tab) {
        UserDefaults.standard.set(tab.rawValue, forKey: tabKey)
    }

    @Environment(AppModel.self) private var app
    @AppStorage(SettingsView.tabKey) private var tab = Tab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general.rawValue)
            EditorSettings()
                .tabItem { Label("Editor", systemImage: "textformat") }
                .tag(Tab.editor.rawValue)
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(Tab.notifications.rawValue)
            CalendarSettingsView()
                .tabItem { Label("Calendars", systemImage: "calendar") }
                .tag(Tab.calendars.rawValue)
            SharingSettingsView()
                .tabItem { Label("Sharing", systemImage: "person.2") }
                .tag(Tab.sharing.rawValue)
        }
        .frame(width: 560)
        .preferredColorScheme(app.settings.appearance.colorScheme)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                TextField("Folder", text: $settings.dailyNotesFolder, prompt: Text("Daily Notes"))
            } header: {
                Text("Daily Notes")
            } footer: {
                Text("New daily notes are created in this folder, named by date. Existing notes named like 2026-11-16 are found wherever they are.")
            }

            Section("Workspace") {
                if let workspace = app.workspace {
                    LabeledContent("Folder") {
                        Text(workspace.record.displayPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Button("Reveal in Finder") { workspace.revealInFinder("") }
                        Button("Choose Another Folder…") { app.chooseWorkspace() }
                    }
                } else {
                    Button("Choose a Folder…") { app.chooseWorkspace() }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Editor

private struct EditorSettings: View {
    @Environment(AppModel.self) private var app
    @State private var families: [String] = []

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Font", selection: $settings.editorFont) {
                    ForEach(AppSettings.EditorFont.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                if settings.editorFont == .custom {
                    Picker("Family", selection: $settings.editorFontFamily) {
                        Text("Choose a Font").tag("")
                        ForEach(families, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                }
                LabeledContent("Size") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.editorTextSize, in: EditorTheme.textSizes, step: 1) {
                            Text("Size")
                        } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller")
                                .accessibilityLabel("Smaller")
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger")
                                .accessibilityLabel("Larger")
                        }
                        .labelsHidden()
                        Text("\(Int(settings.editorTextSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Picker("Line spacing", selection: $settings.lineSpacing) {
                    ForEach(AppSettings.LineSpacing.allCases) { spacing in
                        Text(spacing.title).tag(spacing)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Page width", selection: $settings.pageWidth) {
                    ForEach(AppSettings.PageWidth.allCases) { width in
                        Text(width.title).tag(width)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Text")
            } footer: {
                Text("⌘+ and ⌘− change the size while you write; ⌘0 goes back to \(Int(EditorTheme.defaultTextSize)) pt.")
            }

            Section("Preview") {
                TextPreview(theme: settings.editorTheme)
            }

            Section {
                Picker("Interface size", selection: $settings.interfaceSize) {
                    ForEach(AppSettings.InterfaceSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("The sidebar, lists, boards, Home and the calendar.")
            }

            Section {
                Toggle("Check spelling while typing", isOn: $settings.checksSpelling)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // Hidden system families start with a dot.
            families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
        }
    }
}

/// A heading and a paragraph set exactly as the editor will set them.
private struct TextPreview: View {
    let theme: EditorTheme

    var body: some View {
        let heading = theme.baseFont(for: .heading2)
        let body = theme.baseFont(for: .paragraph)
        VStack(alignment: .leading, spacing: 6) {
            Text("Planning the launch")
                .font(Font(heading as CTFont))
            Text("Write the way you think. Headings, lists and to-dos keep their shape, and every page stays a plain Markdown file you own.")
                .font(Font(body as CTFont))
                .lineSpacing(max(0, theme.lineHeight(for: .paragraph) - (body.ascender - body.descender + body.leading)))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.lpInk)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Calendars

struct CalendarSettingsView: View {

    @Environment(AppModel.self) private var app
    @State private var connecting: CalendarProviderKind?
    @State private var errors: [CalendarProviderKind: String] = [:]

    private var sync: CalendarSyncStore { app.calendarSync }
    private var bundleID: String { Bundle.main.bundleIdentifier ?? "LTF.Local-Productivity" }

    var body: some View {
        @Bindable var sync = sync
        Form {
            Section {
                appleRow
            } header: {
                Text("Apple Calendar")
            } footer: {
                Text("Includes iCloud and any Google, Exchange or other account added in System Settings → Internet Accounts. Changes sync through macOS.")
            }

            Section {
                ForEach(sync.accounts.filter { $0.kind == .google }) { account in
                    AccountRow(account: account)
                }
                TextField("Client ID", text: $sync.googleClientID, prompt: Text("…apps.googleusercontent.com"))
                    .textContentType(.none)
                connectButton(.google, title: "Connect Google Account…",
                              isReady: GoogleCalendarMapping.configuration(clientID: sync.googleClientID) != nil) {
                    try await sync.connectGoogle()
                }
                SetupGuide(title: "How to get a Google client ID", link: URL(string: "https://console.cloud.google.com/apis/credentials")!,
                           linkTitle: "Open Google Cloud Console", steps: [
                    "Create a project in Google Cloud Console.",
                    "In APIs & Services → Library, enable the Google Calendar API.",
                    "Set up the OAuth consent screen and add your address as a test user.",
                    "In Credentials, create an OAuth client ID of type “iOS” with bundle ID \(bundleID).",
                    "Paste the client ID above, then connect."
                ], copyValue: bundleID)
            } header: {
                Text("Google Calendar")
            } footer: {
                errorText(.google)
            }

            Section {
                ForEach(sync.accounts.filter { $0.kind == .microsoft }) { account in
                    AccountRow(account: account)
                }
                TextField("Application (client) ID", text: $sync.microsoftClientID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                    .textContentType(.none)
                connectButton(.microsoft, title: "Connect Microsoft Account…",
                              isReady: MicrosoftGraphMapping.configuration(clientID: sync.microsoftClientID, bundleID: bundleID) != nil) {
                    try await sync.connectMicrosoft()
                }
                SetupGuide(title: "How to get a Microsoft client ID", link: URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!,
                           linkTitle: "Open Microsoft Entra", steps: [
                    "In Microsoft Entra (Azure), open App registrations and choose New registration.",
                    "Allow “Accounts in any organizational directory and personal Microsoft accounts”.",
                    "Under Authentication, add the “iOS / macOS” platform with bundle ID \(bundleID).",
                    "Under API permissions, add Microsoft Graph delegated permissions Calendars.ReadWrite and User.Read.",
                    "Paste the Application (client) ID above, then connect."
                ], copyValue: bundleID)
            } header: {
                Text("Microsoft Outlook")
            } footer: {
                errorText(.microsoft)
            }

            if !sync.calendars.isEmpty {
                Section {
                    ForEach(sync.accounts) { account in
                        let calendars = sync.calendars(for: account)
                        if !calendars.isEmpty {
                            Text(account.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(calendars) { calendar in
                                Toggle(isOn: visibility(of: calendar)) {
                                    HStack(spacing: 8) {
                                        Circle().fill(Color(hex: calendar.colorHex)).frame(width: 9, height: 9)
                                        Text(calendar.title)
                                        if !calendar.isWritable {
                                            Text("Read-only").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Show in LP")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
    }

    @ViewBuilder
    private var appleRow: some View {
        if let account = sync.accounts.first(where: { $0.kind == .apple }) {
            AccountRow(account: account)
        } else if EventKitCalendarProvider.wasDenied {
            LabeledContent("Access") {
                Button("Open Privacy Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
            Text("LP was not allowed to use your calendars. Turn on LP in System Settings → Privacy & Security → Calendars.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            connectButton(.apple, title: "Connect Apple Calendar…", isReady: true) {
                try await sync.connectApple()
            }
            errorText(.apple)
        }
    }

    private func visibility(of calendar: SyncCalendar) -> Binding<Bool> {
        Binding(
            get: { !sync.hiddenCalendarIDs.contains(calendar.id) },
            set: { visible in
                if visible { sync.hiddenCalendarIDs.remove(calendar.id) } else { sync.hiddenCalendarIDs.insert(calendar.id) }
            }
        )
    }

    private func connectButton(_ kind: CalendarProviderKind, title: String, isReady: Bool,
                               action: @escaping () async throws -> Void) -> some View {
        HStack {
            Button(title) {
                connecting = kind
                errors[kind] = nil
                Task {
                    do {
                        try await action()
                    } catch CalendarSyncError.cancelled {
                        // Closing the sign-in window is not an error.
                    } catch {
                        errors[kind] = error.localizedDescription
                    }
                    connecting = nil
                }
            }
            .disabled(!isReady || connecting != nil)
            if connecting == kind {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func errorText(_ kind: CalendarProviderKind) -> some View {
        if let message = errors[kind] {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

/// A connected account: its name, how syncing is going, and a way to disconnect.
private struct AccountRow: View {
    let account: CalendarAccount
    @Environment(AppModel.self) private var app
    @State private var confirmingDisconnect = false

    var body: some View {
        let state = app.calendarSync.state(of: account)
        HStack(spacing: 10) {
            Image(systemName: account.kind == .apple ? "applelogo" : "person.crop.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                status(state)
                    .font(.system(size: 11.5))
            }
            Spacer()
            Button("Disconnect") { confirmingDisconnect = true }
        }
        .confirmationDialog("Disconnect \(account.name)?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) { app.calendarSync.disconnect(account) }
        } message: {
            Text("Its events will no longer appear in LP. Nothing is deleted from the calendar itself.")
        }
    }

    @ViewBuilder
    private func status(_ state: CalendarSyncStore.AccountState) -> some View {
        switch state {
        case .idle:
            Text("Connected").foregroundStyle(.secondary)
        case .syncing:
            Text("Syncing…").foregroundStyle(.secondary)
        case .synced(let date):
            Text("Synced \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .needsSignIn:
            Text("Sign-in needed — connect again below").foregroundStyle(.orange)
        }
    }
}

/// Step-by-step setup instructions that stay out of the way until asked for.
private struct SetupGuide: View {
    let title: String
    let link: URL
    let linkTitle: String
    let steps: [String]
    let copyValue: String

    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Link(linkTitle, destination: link)
                    Spacer()
                    Button("Copy Bundle ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyValue, forType: .string)
                    }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12))
            .padding(.top, 4)
        }
    }
}
