//
//  CommentMargin.swift
//  Weft: comments beside the paper, the way Google Docs does it. The white
//  paper sits on the left and a comment column on its right; each card lines
//  up with its highlighted passage, and when cards would overlap the later
//  ones move down (the open card stays level with its passage).
//
//  Used by the teacher's grading screen (add, edit, delete, resolve, private
//  or shared) and, read-only, by the student's returned-work screen.
//

import SwiftUI
import AppKit

// MARK: - Model

/// One comment as the margin shows it.
struct MarginItem: Identifiable, Equatable {
    let id: String
    var body: String
    /// "You" for the viewer's own comments, else "Teacher".
    var author: String
    var createdAt: Date?
    var isPrivate: Bool
    var resolved: Bool
    /// Where the passage is in the plain paper text; nil = passage not found.
    var anchor: NSRange?
}

/// What the teacher can do to a comment. All nil = read-only (the student).
struct CommentHandlers {
    var saveEdit: ((String, String) async -> Bool)? = nil
    var delete: ((String) -> Void)? = nil
    var setResolved: ((String, Bool) -> Void)? = nil
    var setPrivate: ((String, Bool) -> Void)? = nil

    var editable: Bool { saveEdit != nil }
}

// MARK: - Relative time

enum RelativeTime {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()
    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    /// "Just now", "2 min ago", "3 hr ago", "Yesterday", "Monday", "Nov 3".
    static func label(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        let cal = Calendar.current
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if cal.isDateInToday(date) { return "\(Int(seconds / 3600)) hr ago" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 6 * 86400 { return weekdayFormatter.string(from: date) }
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return dayFormatter.string(from: date)
        }
        return yearFormatter.string(from: date)
    }
}

// MARK: - Stacking layout

private struct MarginY: LayoutValueKey { static let defaultValue: CGFloat = 0 }
private struct MarginPinned: LayoutValueKey { static let defaultValue = false }

/// Places each card at its wanted height (its passage), pushing later cards
/// down so none overlap. The pinned (open) card keeps its height; cards above
/// it move up to make room, unless there is no room above, in which case the
/// column simply stacks from the top.
struct MarginStack: Layout {
    var gap: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 260
        let frames = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews)
        for (i, f) in frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX, y: bounds.minY + f.minY),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: f.height))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let n = subviews.count
        guard n > 0 else { return [] }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let wants = subviews.map { max(0, $0[MarginY.self]) }
        let order = (0..<n).sorted { wants[$0] != wants[$1] ? wants[$0] < wants[$1] : $0 < $1 }
        var y = [CGFloat](repeating: 0, count: n)   // indexed by position in `order`

        func forward(from start: Int) {
            guard start < n else { return }
            for k in start..<n {
                let floor = k == 0 ? 0 : y[k - 1] + heights[order[k - 1]] + gap
                y[k] = max(wants[order[k]], floor)
            }
        }

        if let p = order.firstIndex(where: { subviews[$0][MarginPinned.self] }) {
            y[p] = wants[order[p]]
            forward(from: p + 1)
            var k = p - 1
            while k >= 0 {
                y[k] = min(wants[order[k]], y[k + 1] - gap - heights[order[k]])
                k -= 1
            }
            if y[0] < 0 { forward(from: 0) }
        } else {
            forward(from: 0)
        }

        var frames = [CGRect](repeating: .zero, count: n)
        for k in 0..<n {
            let i = order[k]
            frames[i] = CGRect(x: 0, y: y[k], width: width, height: heights[i])
        }
        return frames
    }
}

// MARK: - Paper + margin

/// The white paper with its comment column. Owns the selection, the draft
/// card and the "Show resolved" switch; the caller owns the comments.
struct MarginedPaper: View {
    let paragraphs: [String]
    /// Every comment on this paper, resolved ones included.
    let comments: [MarginItem]
    @Binding var activeId: String?
    var handlers: CommentHandlers = .init()
    /// Posts a new comment: (selection, body, private). Returns an error
    /// message, or nil when it was saved. nil = no adding (read-only).
    var onAdd: ((PaperSelection, String, Bool) async -> String?)? = nil
    /// Shown in the empty column when there are no comments yet.
    var emptyHint: String? = nil

    private struct Draft {
        var range: NSRange
        var quote: String
        var top: CGFloat
        var text = ""
        var isPrivate = false
        var busy = false
        var error: String?
    }

    static let draftId = "__draft__"

    @State private var selection: PaperSelection?
    @State private var tops: [String: CGFloat] = [:]
    @State private var draft: Draft?
    @State private var clearToken = 0
    @State private var showResolved = false

    private var canComment: Bool { onAdd != nil }
    private var visible: [MarginItem] { comments.filter { !$0.resolved || showResolved } }
    private var resolvedCount: Int { comments.filter(\.resolved).count }
    private var openCount: Int { comments.count - resolvedCount }

    private var marks: [PaperMark] {
        var out: [PaperMark] = visible.compactMap { c in
            guard let r = c.anchor else { return nil }
            let style: PaperMark.Style = c.resolved ? .hidden : (c.id == activeId ? .active : .normal)
            return PaperMark(id: c.id, range: r, style: style)
        }
        if let draft { out.append(PaperMark(id: Self.draftId, range: draft.range, style: .draft)) }
        return out
    }

    // Measurements that follow the room available.
    private struct Metrics {
        var paperWidth: CGFloat
        var padH: CGFloat
        var padV: CGFloat
        var gutter: CGFloat
        var column: CGFloat
    }

    private func metrics(for width: CGFloat) -> Metrics {
        let avail = max(320, width - 2 * Theme.Space.lg)
        let column: CGFloat = avail >= 980 ? 288 : (avail >= 700 ? 248 : (avail >= 560 ? 212 : 188))
        let gutter: CGFloat = canComment ? (avail >= 640 ? 40 : 32) : 20
        let paper = min(760, avail - column - gutter)
        let padH: CGFloat = paper >= 620 ? 64 : (paper >= 460 ? 44 : 28)
        let padV: CGFloat = paper >= 460 ? 52 : 36
        return Metrics(paperWidth: paper, padH: padH, padV: padV, gutter: gutter, column: column)
    }

    var body: some View {
        GeometryReader { geo in
            let m = metrics(for: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        columnHeader(m)
                        HStack(alignment: .top, spacing: 0) {
                            paper(m)
                            Color.clear.frame(width: m.gutter, height: 1)
                            column(m)
                                .frame(width: m.column, alignment: .topLeading)
                        }
                    }
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.top, Theme.Space.md)
                    .padding(.bottom, Theme.Space.xxxl)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: activeId) { _, id in
                    guard let id else { return }
                    // Let the column settle on the new layout first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: nil) }
                    }
                }
            }
        }
        .onChange(of: comments.map(\.id)) { _, ids in
            if let a = activeId, !ids.contains(a) { activeId = nil }
        }
    }

    // MARK: Paper

    private func paper(_ m: Metrics) -> some View {
        PaperTextView(
            paragraphs: paragraphs,
            marks: marks,
            clearSelectionToken: clearToken,
            onSelection: { sel in selection = sel },
            onMarkTops: { t in tops = t },
            onMarkClick: { id in
                guard draft == nil else { return }
                withAnimation(.easeOut(duration: 0.18)) { activeId = id }
            })
            .padding(.vertical, m.padV)
            .padding(.horizontal, m.padH)
            .frame(width: m.paperWidth, alignment: .topLeading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                addButton(m)
            }
    }

    /// The floating "add comment" button at the selection's height.
    @ViewBuilder private func addButton(_ m: Metrics) -> some View {
        if canComment, draft == nil, let sel = selection {
            Button {
                openDraft(sel)
            } label: {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.14), radius: 3, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("m", modifiers: [.command, .option])
            .help("Add a comment (\u{2325}\u{2318}M)")
            .accessibilityLabel("Add comment on the selected text")
            .linkPointer()
            .offset(x: m.gutter / 2 + 15, y: m.padV + sel.top - 6)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    // MARK: Column

    @ViewBuilder private func columnHeader(_ m: Metrics) -> some View {
        if !comments.isEmpty {
            HStack(spacing: 0) {
                Color.clear.frame(width: m.paperWidth + m.gutter, height: 1)
                HStack(spacing: Theme.Space.sm) {
                    Text(openCount == 1 ? "1 comment" : "\(openCount) comments")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                    if resolvedCount > 0 {
                        Button(showResolved ? "Hide resolved" : "Show resolved (\(resolvedCount))") {
                            withAnimation(.easeOut(duration: 0.18)) { showResolved.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .linkPointer()
                        .accessibilityLabel(showResolved ? "Hide resolved comments"
                                                         : "Show \(resolvedCount) resolved comments")
                    }
                }
                .frame(width: m.column)
            }
        }
    }

    private func column(_ m: Metrics) -> some View {
        let pinned = draft != nil ? Self.draftId : activeId
        return MarginStack(gap: 10) {
            if comments.isEmpty, draft == nil, let emptyHint {
                Text(emptyHint)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.muted2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .layoutValue(key: MarginY.self, value: m.padV)
            }
            ForEach(visible) { item in
                CommentCardView(
                    item: item,
                    active: item.id == activeId && draft == nil,
                    handlers: handlers,
                    onActivate: {
                        withAnimation(.easeOut(duration: 0.18)) { activeId = item.id }
                    })
                    .id(item.id)
                    .layoutValue(key: MarginY.self,
                                 value: m.padV + (item.anchor == nil ? 0 : (tops[item.id] ?? 0)))
                    .layoutValue(key: MarginPinned.self, value: pinned == item.id)
            }
            if draft != nil {
                DraftCommentCard(
                    text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 }),
                    isPrivate: Binding(get: { draft?.isPrivate ?? false }, set: { draft?.isPrivate = $0 }),
                    busy: draft?.busy ?? false,
                    error: draft?.error,
                    onPost: post,
                    onCancel: cancelDraft)
                    .id(Self.draftId)
                    .layoutValue(key: MarginY.self,
                                 value: m.padV + (tops[Self.draftId] ?? draft?.top ?? 0))
                    .layoutValue(key: MarginPinned.self, value: true)
            }
        }
        .animation(.easeOut(duration: 0.18), value: tops)
        .animation(.easeOut(duration: 0.18), value: activeId)
        .animation(.easeOut(duration: 0.18), value: showResolved)
    }

    // MARK: Draft actions

    private func openDraft(_ sel: PaperSelection) {
        withAnimation(.easeOut(duration: 0.15)) {
            activeId = nil
            draft = Draft(range: sel.range, quote: sel.text, top: sel.top)
        }
    }

    private func cancelDraft() {
        withAnimation(.easeOut(duration: 0.15)) { draft = nil }
        selection = nil
        clearToken += 1
    }

    private func post() {
        guard let d = draft, let onAdd else { return }
        let body = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !d.busy else { return }
        draft?.busy = true
        draft?.error = nil
        let sel = PaperSelection(range: d.range, text: d.quote, top: d.top)
        Task {
            let error = await onAdd(sel, body, d.isPrivate)
            if let error {
                draft?.busy = false
                draft?.error = error
            } else {
                withAnimation(.easeOut(duration: 0.15)) { draft = nil }
                selection = nil
                clearToken += 1
            }
        }
    }
}

// MARK: - Cards

private struct Avatar: View {
    let name: String
    var body: some View {
        ZStack {
            Circle().fill(Theme.accentSoft.opacity(0.18))
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

/// The card frame shared by comment and draft cards.
private struct CardChrome: ViewModifier {
    var active: Bool
    var dimmed: Bool = false
    var tint: Color = .white

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(active ? Theme.accent.opacity(0.55) : Color.black.opacity(0.10),
                            lineWidth: active ? 1.5 : 1))
            .shadow(color: Color.black.opacity(active ? 0.16 : 0.05),
                    radius: active ? 10 : 2, x: 0, y: active ? 4 : 1)
            .opacity(dimmed ? 0.62 : 1)
            .offset(x: active ? -8 : 0)
    }
}

struct CommentCardView: View {
    let item: MarginItem
    let active: Bool
    let handlers: CommentHandlers
    let onActivate: () -> Void

    @State private var editing = false
    @State private var editText = ""
    @State private var busy = false
    @State private var confirmDelete = false
    @FocusState private var editFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if editing {
                editor
            } else {
                Text(item.body)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.inkSoft)
                    .lineSpacing(2)
                    .lineLimit(active ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if item.anchor == nil {
                Label("Passage not found", systemImage: "questionmark.text.page")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warn)
                    .help("The words this comment points at are no longer in the paper.")
            }
            if handlers.editable, !editing {
                visibilityButton
            }
        }
        .modifier(CardChrome(active: active, dimmed: item.resolved,
                             tint: item.isPrivate && handlers.editable
                                 ? Color(red: 0.975, green: 0.972, blue: 0.965) : .white))
        .contentShape(Rectangle())
        // Off while editing, so clicks reach the text field.
        .simultaneousGesture(TapGesture().onEnded { if !editing { onActivate() } },
                             including: editing ? .subviews : .all)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment by \(item.author)")
        .accessibilityAction(named: "Show passage") { onActivate() }
        .alert("Delete this comment?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { handlers.delete?(item.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Avatar(name: item.author)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.author)
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                subtitle
            }
            Spacer(minLength: 4)
            if handlers.editable {
                iconButton(item.resolved ? "arrow.uturn.backward" : "checkmark",
                           label: item.resolved ? "Reopen comment" : "Resolve comment") {
                    handlers.setResolved?(item.id, !item.resolved)
                }
                Menu {
                    Button("Edit") { startEditing() }
                    Button("Delete", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More actions for this comment")
            }
        }
    }

    @ViewBuilder private var subtitle: some View {
        let parts: (Date?) -> String = { now in
            var bits: [String] = []
            if let d = item.createdAt { bits.append(RelativeTime.label(d, now: now ?? .now)) }
            if item.resolved { bits.append("Resolved") }
            return bits.joined(separator: " \u{00B7} ")
        }
        if item.createdAt != nil || item.resolved {
            TimelineView(.everyMinute) { ctx in
                Text(parts(ctx.date))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
    }

    private func iconButton(_ system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHover(corner: 6, strength: 0.08)
        .help(label)
        .accessibilityLabel(label)
    }

    private var visibilityButton: some View {
        Button {
            handlers.setPrivate?(item.id, !item.isPrivate)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.isPrivate ? "lock" : "eye")
                    .font(.system(size: 10, weight: .semibold))
                Text(item.isPrivate ? "Private note" : "Visible to student")
                    .font(.system(size: 11))
            }
            .foregroundStyle(item.isPrivate ? Theme.muted : Theme.good)
        }
        .buttonStyle(.plain)
        .linkPointer()
        .help(item.isPrivate
              ? "Only teachers see this. Click to show it to the student."
              : "The student sees this when you share the grade. Click to make it a private note.")
        .accessibilityLabel(item.isPrivate ? "Private note. Show to student" : "Visible to student. Make private")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Comment", text: $editText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.sans(13))
                .lineLimit(1...10)
                .focused($editFocused)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.accent.opacity(editFocused ? 0.6 : 0.25), lineWidth: 1))
                .onExitCommand { editing = false }
                .accessibilityLabel("Edit comment")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { editing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveEdit() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy || editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Save (\u{2318}\u{21A9})")
            }
            .controlSize(.small)
        }
    }

    private func startEditing() {
        editText = item.body
        editing = true
        onActivate()
        DispatchQueue.main.async { editFocused = true }
    }

    private func saveEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let save = handlers.saveEdit else { return }
        if text == item.body { editing = false; return }
        busy = true
        Task {
            let ok = await save(item.id, text)
            busy = false
            if ok { editing = false }
        }
    }
}

/// The new-comment card: text field, shared or private, Comment / Cancel.
struct DraftCommentCard: View {
    @Binding var text: String
    @Binding var isPrivate: Bool
    let busy: Bool
    let error: String?
    let onPost: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Avatar(name: "You")
                Text("You")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.inkSoft)
            }
            TextField("Add a comment", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.sans(13))
                .lineLimit(2...10)
                .focused($focused)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.accent.opacity(focused ? 0.6 : 0.25), lineWidth: 1))
                .onExitCommand { onCancel() }
                .accessibilityLabel("New comment")
            Button {
                isPrivate.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isPrivate ? "lock" : "eye")
                        .font(.system(size: 10, weight: .semibold))
                    Text(isPrivate ? "Private note" : "Visible to student")
                        .font(.system(size: 11))
                }
                .foregroundStyle(isPrivate ? Theme.muted : Theme.good)
            }
            .buttonStyle(.plain)
            .linkPointer()
            .help(isPrivate ? "Only teachers will see this. Click to show it to the student."
                            : "The student sees this when you share the grade. Click to make it private.")
            .accessibilityLabel(isPrivate ? "Private note. Show to student" : "Visible to student. Make private")
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel (Esc)")
                Button("Comment", action: onPost)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(empty || busy)
                    .help("Comment (\u{2318}\u{21A9})")
            }
            .controlSize(.small)
        }
        .modifier(CardChrome(active: true))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
