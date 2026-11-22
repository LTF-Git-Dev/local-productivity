//
//  UpdateView.swift
//  Local Productivity
//
//  The Software Update window: checking, "LP x is available" with its release notes, the download
//  and install, and what went wrong.
//

import SwiftUI

struct UpdateView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    private var updater: Updater { app.updater }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.lp(size: 17, weight: .semibold))
                        .foregroundStyle(Color.lpInk)
                    Text(subtitle)
                        .font(.lp(size: 13))
                        .foregroundStyle(Color.lpInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            buttons
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.lpCanvas)
    }

    private var title: String {
        switch updater.phase {
        case .idle: return "Software Update"
        case .checking: return "Checking for Updates…"
        case .upToDate: return "LP Is Up to Date"
        case .available(let offer): return "LP \(offer.manifest.version)\(offer.manifest.prerelease ? " Beta" : "") Is Available"
        case .downloading(let offer, _): return "Downloading LP \(offer.manifest.version)…"
        case .installing(let offer): return "Installing LP \(offer.manifest.version)…"
        case .installed(let offer): return "LP \(offer.manifest.version) Is Installed"
        case .failed: return "Couldn’t Update LP"
        }
    }

    private var subtitle: String {
        switch updater.phase {
        case .idle, .checking:
            return "You have \(Updater.currentDescription)."
        case .upToDate:
            return "You have \(Updater.currentDescription), the newest version\(updater.includesBetas ? " (betas included)" : "")."
        case .available:
            return "You have \(Updater.currentDescription). Your notes and settings stay as they are."
        case .downloading, .installing:
            return "LP restarts by itself when the update is in place."
        case .installed:
            return "Quit LP and open it again to start using the new version."
        case .failed(let message, _):
            return message
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .available(let offer):
            if !offer.notes.isEmpty {
                ScrollView {
                    Text(notes(offer.notes))
                        .font(.lp(size: 13))
                        .foregroundStyle(Color.lpInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(height: 200)
                .background(Color.lpSurface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMedium).strokeBorder(Color.lpHairline))
            }
            if offer.manifest.prerelease {
                Label("A beta: new things first, and possibly rough edges.", systemImage: "flask")
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpInkSecondary)
            }
        case .downloading(let offer, let fraction):
            ProgressView(value: fraction) {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(Double(offer.manifest.size) * fraction), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(offer.manifest.size), countStyle: .file))")
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpInkSecondary)
            }
        case .checking, .installing:
            ProgressView().progressViewStyle(.linear)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updater.phase {
        case .downloading, .installing, .checking:
            EmptyView()
        default:
            buttonRow
        }
    }

    @ViewBuilder private var buttonRow: some View {
        HStack {
            switch updater.phase {
            case .available(let offer):
                Button("Skip This Version") { updater.skip(); dismissWindow() }
                Spacer()
                Link("Release Notes", destination: offer.page)
                Button("Later") { updater.later(); dismissWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Install and Restart") { updater.install() }
                    .keyboardShortcut(.defaultAction)
            case .failed(_, let page):
                if let page { Link("Open GitHub Releases", destination: page) }
                Spacer()
                Button("Close") { updater.later(); dismissWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { updater.checkNow() }
                    .keyboardShortcut(.defaultAction)
            case .downloading, .installing, .checking:
                Spacer()
            default:
                Spacer()
                Button("OK") { updater.later(); dismissWindow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Release notes are Markdown (the CHANGELOG entry): headings in bold, list items as bullets,
    /// inline styling and links kept.
    private func notes(_ text: String) -> AttributedString {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            let trimmed = line.drop { $0 == " " }
            let indent = String(repeating: "   ", count: (line.count - trimmed.count) / 2)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? "" : "**\(title)**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return indent + "• " + trimmed.dropFirst(2) }
            return line
        }
        let joined = lines.joined(separator: "\n")
        var notes = (try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(joined)
        // The notes aren't signed: their links are shown as text, never opened from here.
        for run in notes.runs where run.link != nil { notes[run.range].link = nil }
        return notes
    }
}
