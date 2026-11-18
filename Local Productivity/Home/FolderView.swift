//
//  FolderView.swift
//  Local Productivity
//
//  What a folder looks like when you open it: its name, and everything inside it as a
//  list you can read at a glance. Folders are how pages nest, so this is the app's
//  equivalent of a page full of sub-pages.
//

import SwiftUI

struct FolderView: View {

    let workspace: Workspace
    let path: String
    @Environment(AppModel.self) private var app

    private var node: FileNode? { workspace.node(at: path) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "folder")
                    .font(.lp(size: 22, weight: .medium))
                    .foregroundStyle(Color.lpInkSecondary)
                    .frame(width: 60, height: 60)
                    .background(Color.lpFillSubtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(FileNode.fileName(of: path))
                    .font(.lp(size: 28, weight: .bold))
                    .foregroundStyle(Color.lpInk)
                    .padding(.top, 16)

                Text(summary)
                    .font(.lp(size: 14))
                    .foregroundStyle(Color.lpInkSecondary)
                    .padding(.top, 4)

                if let node, !node.children.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                            FolderItemRow(node: child, meta: workspace.meta[child.path]) {
                                if child.isFolder {
                                    workspace.expand(to: child.path)
                                    workspace.expanded.insert(child.path)
                                    app.show(.folder(child.path))
                                } else {
                                    app.openPage(child.path)
                                }
                            }
                            if index < node.children.count - 1 {
                                Rectangle()
                                    .fill(Color.lpHairline)
                                    .frame(height: 1)
                                    .padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .cardSurface(isHovering: false)
                    .padding(.top, 28)
                } else {
                    Text("Nothing in this folder yet.")
                        .font(.lp(size: 14))
                        .foregroundStyle(Color.lpInkTertiary)
                        .padding(.top, 28)
                }

                Button {
                    app.newPage(in: path)
                } label: {
                    Label("New Page", systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 18)
            }
            .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
            .padding(.horizontal, Metrics.pageMargin)
            .padding(.top, 52)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .lpSoftScrollEdge()
        .background(Color.lpCanvas)
        .navigationTitle(FileNode.fileName(of: path))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Breadcrumb(path: path, isFolder: true)
            }
            .lpWithoutSharedBackground()
        }
    }

    private var summary: String {
        guard let node else { return "" }
        let pages = node.pageCount
        let folders = node.children.filter(\.isFolder).count
        var parts = [pages == 1 ? "1 page" : "\(pages) pages"]
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        return parts.joined(separator: " · ")
    }
}

private struct FolderItemRow: View {
    let node: FileNode
    let meta: PageMeta?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PageIcon(emoji: meta?.icon, size: 32, isFolder: node.isFolder, isBoard: meta?.isBoard ?? false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.lp(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.lpInk)
                        .lineLimit(1)
                    Text(detail)
                        .font(.lp(size: 12.5))
                        .foregroundStyle(Color.lpInkTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(node.modified.compactRelative)
                    .font(.lp(size: 12))
                    .foregroundStyle(Color.lpInkTertiary)
                Image(systemName: "chevron.right")
                    .font(.lp(size: 10, weight: .semibold))
                    .foregroundStyle(Color.lpInkFaint)
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .background(isHovering ? Color.lpFillHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var detail: String {
        if node.isFolder {
            let count = node.pageCount
            return count == 1 ? "1 page" : "\(count) pages"
        }
        if let snippet = meta?.snippet, !snippet.isEmpty { return snippet }
        return "Empty page"
    }
}
