//
//  SharingSettingsView.swift
//  LP
//
//  Where a board's progress page can be shared, always through the person's own accounts:
//  their Google Drive (the Google account connected for the calendar, once they allow Drive —
//  only files LP creates), or GitHub with a token they make themselves (only gists; checked
//  before it is saved, and kept in the Keychain).
//

import SwiftUI

struct SharingSettingsView: View {

    @State private var token = ""
    @State private var isChecking = false
    @State private var error: String?
    @State private var confirmingDisconnect = false
    @State private var allowingDrive: String?
    @State private var driveError: String?

    @Environment(AppModel.self) private var app
    private var account: SharingAccount { .shared }

    var body: some View {
        Form {
            Section {
                let google = app.calendarSync.accounts.filter { $0.kind == .google }
                if google.isEmpty {
                    Text("Connect a Google account in Settings → Calendars first — sharing uses the same account.")
                        .foregroundStyle(Color.lpInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(google) { account in
                    LabeledContent(account.name) {
                        if app.calendarSync.canUseDrive(account) {
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.lpGood)
                                .labelStyle(.titleAndIcon)
                        } else {
                            HStack(spacing: 8) {
                                if allowingDrive == account.id { ProgressView().controlSize(.small) }
                                Button("Allow Google Drive…") { allowDrive(account) }
                                    .disabled(allowingDrive != nil)
                            }
                        }
                    }
                    #if DEBUG
                    // (Not in snapshots: the user guide's pictures show what everyone sees.)
                    if app.calendarSync.canUseDrive(account), !SnapshotHarness.isActive {
                        DriveSharingTestView(account: account)
                    }
                    #endif
                }
                if let driveError {
                    problem(driveError)
                }
            } header: {
                Text("Google Drive")
            } footer: {
                Text("Share a board’s progress as a Google Doc in your own Drive that anyone with its link can read. LP asks Google only for the files it creates — nothing else in your Drive."
                     + (usesOwnGoogleRegistration ? " With your own client ID, first turn on the Google Drive API in its Google Cloud project." : "")
                     + (BuiltInRegistration.googleAwaitingReview ? " Sharing without your own client ID comes once Google finishes reviewing LP." : ""))
            }

            Section {
                if account.hasToken {
                    LabeledContent("GitHub") {
                        HStack(spacing: 10) {
                            Label(account.login.map { "Connected as \($0)" } ?? "Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Color.lpGood)
                                .labelStyle(.titleAndIcon)
                            Button("Disconnect") { confirmingDisconnect = true }
                        }
                    }
                    if let page = account.accessPage {
                        Link("Manage the Token on GitHub", destination: page)
                    }
                } else {
                    SecureField("Token", text: $token, prompt: Text("ghp_… or github_pat_…"))
                        .onSubmit(connect)
                    HStack(spacing: 10) {
                        Button("Connect", action: connect)
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
                        if isChecking { ProgressView().controlSize(.small) }
                        Spacer()
                        Link("Create a Token on GitHub", destination: GistPublisher.newTokenURL)
                    }
                }
                if let error {
                    problem(error)
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("A board’s progress is shared as a secret GitHub Gist: a page anyone with its link can open, from anywhere. Secret gists aren’t listed or searchable. LP only needs the “gist” permission, and keeps the token in your Keychain.")
            }

            Section {
                Text("Card notes are never shared. A shared page shows the board’s lists, card titles, due dates, tags and recent activity, and LP keeps it up to date as the board changes.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("What others see")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 320)
        .task {
            // Show who the saved token belongs to — unless it was replaced (or removed) while GitHub
            // answered: then the name is another connection's.
            guard account.hasToken, account.login == nil, let saved = GistPublisher.token else { return }
            let changes = account.credentialChanges
            let login = try? await GistPublisher.verify(saved)
            guard account.credentialChanges == changes else { return }
            account.login = login
        }
        .confirmationDialog("Disconnect GitHub?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) {
                try? account.setToken(nil)
            }
        } message: {
            Text("Pages you’ve already shared stay online, but LP can no longer update or remove them. The token itself works until you delete it on GitHub — “Manage the Token on GitHub” opens that page.")
        }
    }

    /// Whether Google sign-ins go to the person's own registration (whose project needs the Drive
    /// API turned on), rather than LP's.
    private var usesOwnGoogleRegistration: Bool {
        !app.calendarSync.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || BuiltInRegistration.googleClientID == nil
    }

    private func problem(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Color.lpCritical)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func allowDrive(_ account: CalendarAccount) {
        guard allowingDrive == nil else { return }
        allowingDrive = account.id
        driveError = nil
        Task {
            do {
                try await app.calendarSync.allowGoogleDrive(for: account)
            } catch CalendarSyncError.cancelled {
                // Closed Google's page: nothing to say.
            } catch {
                driveError = error.localizedDescription
            }
            allowingDrive = nil
        }
    }

    private func connect() {
        let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !isChecking else { return }
        isChecking = true
        error = nil
        Task {
            do {
                let login = try await GistPublisher.verify(candidate)
                try account.setToken(candidate)
                account.login = login
                token = ""
            } catch {
                self.error = error.localizedDescription
            }
            isChecking = false
        }
    }
}
