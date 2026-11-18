//
//  SharingSettingsView.swift
//  LP
//
//  Connects LP to GitHub so boards can publish a live progress page. LP only needs
//  permission to create gists; the token is checked before it is saved, and kept in the
//  Keychain.
//

import SwiftUI

struct SharingSettingsView: View {

    @State private var token = ""
    @State private var isChecking = false
    @State private var error: String?
    @State private var confirmingDisconnect = false

    private var account: SharingAccount { .shared }

    var body: some View {
        Form {
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
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.lpCritical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Progress Sharing")
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
            // Show who the saved token belongs to.
            guard account.hasToken, account.login == nil, let saved = GistPublisher.token else { return }
            account.login = try? await GistPublisher.verify(saved)
        }
        .confirmationDialog("Disconnect GitHub?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) {
                try? account.setToken(nil)
            }
        } message: {
            Text("Pages you have already shared stay online, but LP can no longer update or remove them.")
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
