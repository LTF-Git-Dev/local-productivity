//
//  WelcomeView.swift
//  Local Productivity
//
//  The first thing anyone sees: one decision to make — which folder to use.
//

import SwiftUI

struct WelcomeView: View {

    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            WelcomeBackdrop()

            VStack(spacing: 0) {
                Spacer(minLength: 48)

                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)

                Text("LP")
                    .font(.lp(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.lpInk)
                    .padding(.top, 18)

                Text("LOCAL PRODUCTIVITY")
                    .font(.lp(size: 11, weight: .semibold))
                    .kerning(2.2)
                    .foregroundStyle(Color.lpInkTertiary)
                    .padding(.top, 2)

                Text("A calm home for your notes, tasks and calendar.\nPlain files, in a folder you choose.")
                    .font(.lp(size: 15))
                    .foregroundStyle(Color.lpInkSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 8)

                Button {
                    app.chooseWorkspace()
                } label: {
                    Label("Choose a Folder…", systemImage: "folder")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 28)

                if !app.library.records.isEmpty {
                    recents
                        .padding(.top, 36)
                }

                Spacer(minLength: 48)

                Label("Your notes stay on your Mac, as ordinary files.", systemImage: "lock")
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpInkTertiary)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.lp(size: 11, weight: .semibold))
                .foregroundStyle(Color.lpInkTertiary)
                .padding(.leading, 12)

            VStack(spacing: 1) {
                ForEach(app.library.records.prefix(4)) { record in
                    RecentWorkspaceRow(record: record)
                }
            }
            .padding(5)
            .background(Color.lpSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous).strokeBorder(Color.lpHairline, lineWidth: 1))
        }
    }
}

private struct RecentWorkspaceRow: View {
    let record: WorkspaceRecord
    @Environment(AppModel.self) private var app
    @State private var isHovering = false

    var body: some View {
        Button {
            app.openWorkspace(record)
        } label: {
            HStack(spacing: 11) {
                WorkspaceBadge(name: record.name, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.name)
                        .font(.lp(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.lpInk)
                        .lineLimit(1)
                    Text(record.displayPath)
                        .font(.lp(size: 11.5))
                        .foregroundStyle(Color.lpInkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.lp(size: 11, weight: .semibold))
                    .foregroundStyle(Color.lpInkTertiary)
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 48)
            .background(isHovering ? Color.lpFillHover : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Remove from Recents", systemImage: "minus.circle") { app.library.forget(record) }
        }
    }
}

/// A quiet wash of colour behind the welcome screen, so it is not just an empty window.
private struct WelcomeBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 0.75 : 1.0
        ZStack {
            Color.lpCanvas
            Circle()
                .fill(Color.accentColor.opacity(0.20 * strength))
                .frame(width: 620, height: 620)
                .blur(radius: 140)
                .offset(x: -300, y: -260)
            Circle()
                .fill(Color.purple.opacity(0.12 * strength))
                .frame(width: 560, height: 560)
                .blur(radius: 150)
                .offset(x: 340, y: 280)
            Circle()
                .fill(Color.teal.opacity(0.09 * strength))
                .frame(width: 420, height: 420)
                .blur(radius: 130)
                .offset(x: 380, y: -300)
        }
        .drawingGroup()
    }
}

/// The one filled, accent-coloured button style in the app, reserved for the main action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration)
    }

    private struct Appearance: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.lp(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 40)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .brightness(configuration.isPressed ? -0.08 : (isHovering ? 0.05 : 0))
                .shadow(color: Color.accentColor.opacity(0.28), radius: 12, x: 0, y: 5)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(.lpQuick, value: configuration.isPressed)
                .onHover { isHovering = $0 }
        }
    }
}
