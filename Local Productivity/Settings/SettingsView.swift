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

            UpdateSettingsSection(updater: app.updater)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings → General → Updates.
private struct UpdateSettingsSection: View {
    @Bindable var updater: Updater

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            Toggle("Include beta versions", isOn: $updater.includesBetas)
            LabeledContent {
                Button("Check Now") { updater.checkNow() }
            } label: {
                Text(Updater.currentDescription)
                if let last = updater.lastCheck {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("LP looks for new versions on its GitHub page once a day and asks before installing one. Betas get new features first and may have rough edges.")
        }
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
    /// System Settings → Internet Accounts, where Google, Exchange and other accounts are added to the Mac.
    private static let internetAccounts = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!

    var body: some View {
        @Bindable var sync = sync
        Form {
            Section {
                Label {
                    Text("LP talks to your calendars straight from this Mac — nothing passes through a server of ours, and your sign-in stays in your Keychain. It keeps a year back and two years ahead of your Google and Outlook calendars on this Mac, so they’re there offline. Disconnecting removes LP’s access and that copy.")
                        .font(.lp(size: 12))
                        .foregroundStyle(Color.lpInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(Color.lpInkTertiary)
                        .accessibilityHidden(true)
                }
            }

            Section {
                appleRow
                Button("Add an Account in System Settings…") {
                    NSWorkspace.shared.open(Self.internetAccounts)
                }
            } header: {
                Text("Apple Calendar")
            } footer: {
                Text("Includes iCloud and any Google, Exchange or other account added in System Settings → Internet Accounts — nothing else to set up. macOS syncs them; LP reads them on this Mac. Microsoft 365 work accounts may stop syncing there until Apple updates macOS for a change Microsoft is making.")
            }

            Section {
                ForEach(sync.accounts.filter { $0.kind == .google }) { account in
                    AccountRow(account: account)
                }
                connectButton(.google, title: "Connect Google Account…", isReady: sync.canConnectGoogle) {
                    try await sync.connectGoogle()
                }
                OwnRegistration(
                    fieldTitle: "Client ID", prompt: "…apps.googleusercontent.com", clientID: $sync.googleClientID,
                    hasBuiltIn: BuiltInRegistration.googleClientID != nil,
                    warning: "If you change it later, boards you shared to Google Drive through the earlier one can’t be updated or removed by LP any more: stop sharing them first.",
                    steps: [
                        "Open Google’s Personal mode page, signed in with the Google account you’ll connect — only that account can use it.",
                        "Choose “iOS” with bundle ID \(bundleID), accept the terms and continue, then copy the client ID.",
                        "Turn on the Google Calendar API in that project — and the Google Drive API, to share boards to your Drive.",
                        "Paste the client ID above, then connect."
                    ],
                    links: [
                        ("Personal Mode Page", URL(string: "https://console.cloud.google.com/auth/overview/personal")!),
                        ("Calendar API", URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")!),
                        ("Drive API", URL(string: "https://console.cloud.google.com/apis/library/drive.googleapis.com")!)
                    ],
                    bundleID: bundleID)
            } header: {
                Text("Google Calendar")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if BuiltInRegistration.googleAwaitingReview {
                        Text("One-click Google connect is coming soon — Google is still reviewing LP. Meanwhile, add your Google account in System Settings → Internet Accounts to see its calendars through Apple Calendar above.")
                    }
                    errorText(.google)
                }
            }

            Section {
                ForEach(sync.accounts.filter { $0.kind == .microsoft }) { account in
                    AccountRow(account: account)
                }
                connectButton(.microsoft, title: "Connect Microsoft Account…", isReady: sync.canConnectMicrosoft) {
                    try await sync.connectMicrosoft()
                }
                OwnRegistration(
                    fieldTitle: "Application (client) ID", prompt: "00000000-0000-0000-0000-000000000000",
                    clientID: $sync.microsoftClientID, hasBuiltIn: BuiltInRegistration.microsoftClientID != nil,
                    warning: nil,
                    steps: [
                        "In Microsoft Entra (Azure), open App registrations and choose New registration.",
                        "Allow “Accounts in any organizational directory and personal Microsoft accounts”.",
                        "Under Authentication, add the “iOS / macOS” platform with bundle ID \(bundleID).",
                        "Under API permissions, add the Microsoft Graph delegated permission Calendars.ReadWrite (LP needs nothing else).",
                        "Paste the Application (client) ID above, then connect."
                    ],
                    links: [("Microsoft Entra", URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!)],
                    bundleID: bundleID)
            } header: {
                Text("Microsoft Outlook")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Work or school accounts may need their organisation’s approval the first time.")
                    errorText(.microsoft)
                }
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
    @State private var isRemovingPages = false
    /// Shared pages that couldn't be removed from the account's Drive (offline, say).
    @State private var pagesLeft: Int?

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
            if isRemovingPages { ProgressView().controlSize(.small) }
            Button("Disconnect") { confirmingDisconnect = true }
                .disabled(isRemovingPages)
        }
        .confirmationDialog("Disconnect \(account.name)?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) { disconnect() }
        } message: {
            let pages = SharingServices.drivePageCount(of: account.id)
            Text(pages == 0
                 ? "Its events will no longer appear in LP. Nothing is deleted from the calendar itself."
                 : "Its events will no longer appear in LP, and the \(pages == 1 ? "progress page" : "\(pages) progress pages") you shared from its Google Drive \(pages == 1 ? "is" : "are") deleted first, so \(pages == 1 ? "its link stops" : "their links stop") working. Nothing is deleted from the calendar itself.")
        }
        .confirmationDialog("Some shared pages couldn’t be removed", isPresented: Binding(get: { pagesLeft != nil }, set: { if !$0 { pagesLeft = nil } })) {
            Button("Disconnect Anyway", role: .destructive) { disconnect(anyway: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            let left = pagesLeft ?? 0
            Text("\(left == 1 ? "One progress page" : "\(left) progress pages") couldn’t be deleted from \(account.name)’s Google Drive — you may be offline. Disconnecting anyway leaves \(left == 1 ? "it" : "them") there for you to delete in Drive; or cancel and try again when you’re online.")
        }
    }

    /// Deletes the account's shared Drive pages first (while LP can still reach its Drive), then
    /// disconnects — or asks, if some couldn't be deleted. All in `SharingServices.disconnect`, so
    /// no page can be on its way meanwhile.
    private func disconnect(anyway: Bool = false) {
        isRemovingPages = SharingServices.hasDriveWork(of: account.id)
        Task {
            let left = await SharingServices.disconnect(account, anyway: anyway)
            isRemovingPages = false
            if left > 0, !anyway { pagesLeft = left }
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

/// Advanced: the person's own app registration instead of LP's — or the only way, in a copy of LP
/// built without one — with how to make one. Open by default only when it's needed or in use.
private struct OwnRegistration: View {
    let fieldTitle: String
    let prompt: String
    @Binding var clientID: String
    let hasBuiltIn: Bool
    /// What changing it later means, said whether or not LP has a registration of its own.
    let warning: String?
    let steps: [String]
    let links: [(title: String, url: URL)]
    let bundleID: String
    @State private var isExpanded: Bool

    init(fieldTitle: String, prompt: String, clientID: Binding<String>, hasBuiltIn: Bool, warning: String?,
         steps: [String], links: [(title: String, url: URL)], bundleID: String) {
        self.fieldTitle = fieldTitle
        self.prompt = prompt
        _clientID = clientID
        self.hasBuiltIn = hasBuiltIn
        self.warning = warning
        self.steps = steps
        self.links = links
        self.bundleID = bundleID
        _isExpanded = State(initialValue: !hasBuiltIn || !clientID.wrappedValue.isEmpty)
    }

    var body: some View {
        DisclosureGroup("Use Your Own Client ID", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(hasBuiltIn ? "Optional — leave it empty to use LP’s own registration." : "This copy of LP has no registration of its own, so it needs yours:")
                    .foregroundStyle(Color.lpInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.lpInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField(fieldTitle, text: $clientID, prompt: Text(prompt))
                    .textContentType(.none)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(Color.lpInkSecondary)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 14) {
                    ForEach(links, id: \.title) { link in
                        Link(link.title, destination: link.url)
                    }
                    Spacer()
                    Button("Copy Bundle ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bundleID, forType: .string)
                    }
                }
                .padding(.top, 2)
            }
            .font(.lp(size: 12))
            .padding(.top, 4)
        }
    }
}
