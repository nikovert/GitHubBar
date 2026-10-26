import GitHubBarCore
import SwiftUI

struct ReviewDiffView: View {
    @Bindable var review: ReviewWorkspaceModel
    private var files: [PRSearchFile] { review.snapshot?.files ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Since my last review", isOn: Binding(get: { review.sinceLastReview }, set: review.compareSinceLastReview))
                    .disabled(review.baseline == nil || review.loading)
                    .help(review.baseline == nil ? "Submit a review or mark this PR reviewed to save a baseline." : "Compare the last reviewed commit with the current head.")
                Spacer()
                Picker("Diff layout", selection: $review.splitDiff) {
                    Text("Unified").tag(false); Text("Split").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }.padding(12)
            if let notices = review.snapshot?.notices, !notices.isEmpty {
                Text(notices.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if review.sinceLastReview {
                Text("Comparing commits. Switch to the full PR diff before drafting inline comments.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                List(selection: Binding(get: { review.selectedFile?.path }, set: { if let path = $0 { review.selectFile(path) } })) {
                    ForEach(files, id: \.path) { file in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: review.draft.viewedFiles.contains(file.path) ? "checkmark.circle.fill" : "doc")
                                .foregroundStyle(review.draft.viewedFiles.contains(file.path) ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.path).font(.caption).lineLimit(3)
                                Text("+\(file.additions) −\(file.deletions)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }.tag(file.path).help(file.path)
                    }
                }.frame(minWidth: 130, idealWidth: 160, maxWidth: 220)
                if let file = review.selectedFile {
                    fileContent(file).frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No changed files", systemImage: "doc.text.magnifyingglass",
                        description: Text("There may be no changes in this comparison. Check any coverage notice above."))
                }
            }
            if let selected = review.selection {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(selected.path):\(selected.line) · \(selected.side)").font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        Button("Ask agent") {
                            review.showsAgent = true
                            review.question = "Explain this change at \(selected.path):\(selected.line) and any risks."
                        }
                        Button { review.selection = nil } label: { Image(systemName: "xmark") }
                    }
                    if !review.sinceLastReview, review.snapshot?.canDraftInlineComment(in: selected.path) == true {
                        HStack(alignment: .top) {
                            TextField("Draft an inline comment…", text: $review.inlineBody, axis: .vertical).lineLimit(2...4)
                                .textFieldStyle(.roundedBorder)
                            Button("Save draft") { review.addInlineDraft() }
                                .disabled(review.inlineBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || review.submitting || !review.local.canSave)
                        }
                    } else if !review.sinceLastReview {
                        Text("This file or the PR file list is incomplete, so inline drafts cannot be submitted here.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let key = review.snapshot?.key { Link("Comment on GitHub ↗", destination: key.url.appendingPathComponent("files")) }
                    }
                }.padding(12)
            }
        }
    }

    private func fileContent(_ file: PRSearchFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.path).font(.caption.monospaced()).textSelection(.enabled)
                    if let previous = file.previousPath { Text("Renamed from \(previous)").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Toggle("Viewed", isOn: Binding(get: { review.draft.viewedFiles.contains(file.path) },
                    set: { review.markViewed(file.path, viewed: $0) })).controlSize(.small)
                    .disabled(review.sinceLastReview || review.submitting || !review.local.canSave)
            }.padding(10).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let patch = file.patch, !patch.isEmpty {
                GeometryReader { geometry in
                    let lines = PRDiffParser.parse(patch)
                    let textWidth = CGFloat(lines.filter { $0.kind != .hunk }.map { $0.text.count }.max() ?? 0) * 6.7
                    let columnWidth = max(geometry.size.width / 2, textWidth + 55, 280)
                    let contentWidth = review.splitDiff ? columnWidth * 2 + 1 : max(geometry.size.width, textWidth + 120)
                    ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if review.splitDiff {
                                ForEach(splitRows(lines)) { row in
                                    if let hunk = row.hunk { hunkRow(hunk) }
                                    else {
                                        HStack(spacing: 0) {
                                            splitCell(row.left, file: file, side: "LEFT", width: columnWidth)
                                            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1)
                                            splitCell(row.right, file: file, side: "RIGHT", width: columnWidth)
                                        }.frame(height: 22).id(row.id)
                                    }
                                }
                            } else {
                                ForEach(lines) { line in
                                    if line.kind == .hunk { hunkRow(line).id(line.id) }
                                    else { unifiedLine(line, file: file).id(line.id) }
                                }
                            }
                        }.frame(width: contentWidth, alignment: .leading)
                            .id("\(file.path)|\(review.splitDiff)")
                    }
                    .onChange(of: review.selection) { _, selected in
                        guard let selected, selected.path == file.path,
                              let line = PRDiffParser.parse(patch).first(where: {
                                  selected.side == "LEFT" ? $0.oldLine == selected.line : $0.newLine == selected.line
                              }) else { return }
                        let target = review.splitDiff
                            ? splitRows(lines).first(where: { $0.left?.id == line.id || $0.right?.id == line.id })?.id ?? line.id
                            : line.id
                        proxy.scrollTo(target, anchor: .center)
                    }
                    }
                }
            } else {
                ContentUnavailableView("Patch unavailable", systemImage: "doc.questionmark",
                    description: Text("GitHub may omit binary or large patches. Open Files changed on GitHub to inspect this file."))
                if let key = review.snapshot?.key { Link("Open Files changed ↗", destination: key.url.appendingPathComponent("files")).padding() }
            }
        }
    }

    private func color(_ line: PRDiffLine) -> Color {
        switch line.kind {
        case .addition: .green.opacity(0.12)
        case .deletion: .red.opacity(0.12)
        case .hunk: .blue.opacity(0.08)
        default: .clear
        }
    }
    private func hunkRow(_ line: PRDiffLine) -> some View {
        Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .background(color(line))
    }
    private func unifiedLine(_ line: PRDiffLine, file: PRSearchFile) -> some View {
        let side = line.kind == .deletion ? "LEFT" : "RIGHT"
        return Button { select(line, file: file, side: side) } label: {
            HStack(spacing: 0) {
                Text(line.oldLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
                Text(line.newLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
                Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ").frame(width: 24)
                Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, design: .monospaced)).frame(height: 22).padding(.trailing, 12)
            .background(color(line)).contentShape(Rectangle())
            .overlay { if selected(line, side: side) { Rectangle().stroke(Color.accentColor, lineWidth: 1) } }
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func splitCell(_ line: PRDiffLine?, file: PRSearchFile, side: String, width: CGFloat) -> some View {
        if let line {
            Button { select(line, file: file, side: side) } label: {
                HStack(spacing: 8) {
                    Text((side == "LEFT" ? line.oldLine : line.newLine).map(String.init) ?? "")
                        .frame(width: 35, alignment: .trailing).foregroundStyle(.secondary)
                    Text(line.text.isEmpty ? " " : line.text).fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 11, design: .monospaced)).padding(.trailing, 10)
                    .frame(width: width, height: 22).background(color(line)).contentShape(Rectangle())
                    .overlay { if selected(line, side: side) { Rectangle().stroke(Color.accentColor, lineWidth: 1) } }
            }.buttonStyle(.plain)
        } else { Color.secondary.opacity(0.05).frame(width: width, height: 22) }
    }
    private func selected(_ line: PRDiffLine, side: String) -> Bool {
        review.selection?.side == side && review.selection?.line == (side == "LEFT" ? line.oldLine : line.newLine)
    }
    private func select(_ line: PRDiffLine, file: PRSearchFile, side: String) {
        guard let number = side == "LEFT" ? line.oldLine : line.newLine else { return }
        review.selection = ReviewLineSelection(path: file.path, line: number, side: side, text: line.text)
    }
}

private struct SplitDiffRow: Identifiable {
    let id: Int
    var left: PRDiffLine?
    var right: PRDiffLine?
    var hunk: PRDiffLine?
}

private func splitRows(_ lines: [PRDiffLine]) -> [SplitDiffRow] {
    var result: [SplitDiffRow] = []
    var index = 0
    while index < lines.count {
        let line = lines[index]
        if line.kind == .hunk {
            result.append(SplitDiffRow(id: line.id, hunk: line)); index += 1
        } else if line.kind == .context {
            result.append(SplitDiffRow(id: line.id, left: line, right: line)); index += 1
        } else {
            var removed: [PRDiffLine] = [], added: [PRDiffLine] = []
            while index < lines.count && lines[index].kind != .hunk && lines[index].kind != .context {
                if lines[index].kind == .deletion { removed.append(lines[index]) }
                else if lines[index].kind == .addition { added.append(lines[index]) }
                index += 1
            }
            for offset in 0..<max(removed.count, added.count) {
                let left = offset < removed.count ? removed[offset] : nil
                let right = offset < added.count ? added[offset] : nil
                result.append(SplitDiffRow(id: left?.id ?? right!.id, left: left, right: right))
            }
        }
    }
    return result
}
