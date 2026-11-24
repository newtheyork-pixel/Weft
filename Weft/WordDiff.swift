//
//  WordDiff.swift
//  Weft: a word-level diff between two drafts of an essay, computed on this
//  Mac only (the text never leaves it). Words and punctuation are tokens;
//  paragraph breaks are tokens too, so a split or merged paragraph shows up.
//  The diff is a longest-common-subsequence over the changed middle (the
//  common start and end are trimmed first), then a light cleanup so a
//  rewritten sentence reads as "old words, new words" instead of confetti.
//

import Foundation
import AppKit

enum WordDiff {

    /// One token: a word or a punctuation mark, with the spaces that follow
    /// it in its own draft. Only `text` is compared.
    struct Token: Equatable, Sendable {
        let text: String
        var trailing: String
        let isBreak: Bool
        let isWord: Bool
    }

    enum Kind: Sendable { case same, added, removed }

    struct Piece: Sendable {
        let kind: Kind
        let token: Token
    }

    struct Result: Sendable {
        let pieces: [Piece]
        /// Words (not punctuation) added in the newer draft.
        let added: Int
        /// Words (not punctuation) taken out of the older draft.
        let removed: Int
    }

    // MARK: Tokens

    static func tokens(_ paragraphs: [String]) -> [Token] {
        var out: [Token] = []
        for (i, p) in paragraphs.enumerated() {
            if i > 0 { out.append(Token(text: "\n", trailing: "", isBreak: true, isWord: false)) }
            tokenize(p, into: &out)
        }
        return out
    }

    /// Words in a paper, counted the same way the diff counts them.
    static func wordCount(_ paragraphs: [String]) -> Int {
        tokens(paragraphs).filter(\.isWord).count
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static func tokenize(_ s: String, into out: inout [Token]) {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                if !out.isEmpty, !out[out.count - 1].isBreak { out[out.count - 1].trailing.append(c) }
                i += 1
                continue
            }
            if isWordChar(c) {
                var j = i + 1
                while j < chars.count {
                    let d = chars[j]
                    if isWordChar(d) { j += 1; continue }
                    // Keep "don't", "well-known", "3.5" together.
                    if j + 1 < chars.count, isWordChar(chars[j + 1]) {
                        if d == "'" || d == "\u{2019}" || d == "-" { j += 2; continue }
                        if d == "." || d == ",", chars[j - 1].isNumber, chars[j + 1].isNumber {
                            j += 2; continue
                        }
                    }
                    break
                }
                out.append(Token(text: String(chars[i..<j]), trailing: "", isBreak: false, isWord: true))
                i = j
                continue
            }
            out.append(Token(text: String(c), trailing: "", isBreak: false, isWord: false))
            i += 1
        }
    }

    // MARK: Diff

    /// The newer draft's tokens with the older draft's removed tokens woven
    /// in where they were. Pure and thread-safe, so it can run off the main
    /// thread for long essays.
    static func diff(old: [String], new: [String]) -> Result {
        let a = tokens(old)
        let b = tokens(new)

        // Compare small integers, not strings.
        var ids: [String: Int] = [:]
        func id(_ t: Token) -> Int {
            if let v = ids[t.text] { return v }
            let v = ids.count
            ids[t.text] = v
            return v
        }
        let ai = a.map(id)
        let bi = b.map(id)

        var ops: [(Kind, Int)] = []   // (kind, index into a for .removed, else into b)
        ops.reserveCapacity(a.count + b.count)

        var start = 0
        while start < ai.count, start < bi.count, ai[start] == bi[start] { start += 1 }
        var endA = ai.count, endB = bi.count
        while endA > start, endB > start, ai[endA - 1] == bi[endB - 1] { endA -= 1; endB -= 1 }

        for k in 0..<start { ops.append((.same, k)) }
        middle(ai, start, endA, bi, start, endB, into: &ops)
        for k in 0..<(bi.count - endB) { ops.append((.same, endB + k)) }

        let pieces = cleanup(ops.map { kind, i in
            Piece(kind: kind, token: kind == .removed ? a[i] : b[i])
        })
        let added = pieces.filter { $0.kind == .added && $0.token.isWord }.count
        let removed = pieces.filter { $0.kind == .removed && $0.token.isWord }.count
        return Result(pieces: pieces, added: added, removed: removed)
    }

    /// LCS over a[a0..<a1] and b[b0..<b1]. A suffix table lets the walk go
    /// forward, removals before additions inside each change.
    private static func middle(_ a: [Int], _ a0: Int, _ a1: Int,
                               _ b: [Int], _ b0: Int, _ b1: Int,
                               into ops: inout [(Kind, Int)]) {
        let n = a1 - a0, m = b1 - b0
        // ~2,500 x 2,500 tokens covers any essay; past that, call it a rewrite.
        guard n > 0, m > 0, n * m <= 6_500_000 else {
            for k in 0..<n { ops.append((.removed, a0 + k)) }
            for k in 0..<m { ops.append((.added, b0 + k)) }
            return
        }
        let w = m + 1
        var table = [UInt16](repeating: 0, count: (n + 1) * w)
        table.withUnsafeMutableBufferPointer { t in
            var i = n - 1
            while i >= 0 {
                let ai = a[a0 + i]
                var j = m - 1
                while j >= 0 {
                    t[i * w + j] = ai == b[b0 + j]
                        ? t[(i + 1) * w + j + 1] + 1
                        : max(t[(i + 1) * w + j], t[i * w + j + 1])
                    j -= 1
                }
                i -= 1
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if a[a0 + i] == b[b0 + j] {
                ops.append((.same, b0 + j)); i += 1; j += 1
            } else if table[(i + 1) * w + j] >= table[i * w + j + 1] {
                ops.append((.removed, a0 + i)); i += 1
            } else {
                ops.append((.added, b0 + j)); j += 1
            }
        }
        while i < n { ops.append((.removed, a0 + i)); i += 1 }
        while j < m { ops.append((.added, b0 + j)); j += 1 }
    }

    /// Fold tiny islands of "same" (a lone "the" or comma) that sit between
    /// two changes into the change, then put each change's removed words
    /// before its added words. A rewritten clause then reads as one struck
    /// phrase followed by one new phrase.
    private static func cleanup(_ pieces: [Piece]) -> [Piece] {
        // Group into runs of one kind (removed and added count as "changed").
        var runs: [(changed: Bool, items: [Piece])] = []
        for p in pieces {
            let changed = p.kind != .same
            if let last = runs.last, last.changed == changed {
                runs[runs.count - 1].items.append(p)
            } else {
                runs.append((changed, [p]))
            }
        }
        // How big a change is: the larger of its removed and added words.
        func size(_ items: [Piece]) -> Int {
            let removed = items.filter { $0.kind == .removed && $0.token.isWord }.count
            let added = items.filter { $0.kind == .added && $0.token.isWord }.count
            return max(removed, added)
        }
        if runs.count >= 3 {
            for r in 1..<(runs.count - 1) where !runs[r].changed {
                let items = runs[r].items
                let words = items.filter(\.token.isWord).count
                let short = items.count <= 2 && words <= 1 && !items.contains { $0.token.isBreak }
                // Only inside a real rewrite: a one-word swap next to an
                // unchanged word keeps that word plain.
                guard short, runs[r - 1].changed, runs[r + 1].changed,
                      size(runs[r - 1].items) >= 2, size(runs[r + 1].items) >= 2 else { continue }
                // The same tokens are in both drafts: show them as removed
                // (old spacing) and added (new spacing).
                runs[r].changed = true
                runs[r].items = items.map { Piece(kind: .removed, token: $0.token) }
                    + items.map { Piece(kind: .added, token: $0.token) }
            }
        }
        var out: [Piece] = []
        var pending: [Piece] = []
        func flush() {
            out += pending.filter { $0.kind == .removed }
            out += pending.filter { $0.kind == .added }
            pending = []
        }
        for run in runs {
            if run.changed {
                pending += run.items
            } else {
                flush()
                out += run.items
            }
        }
        flush()
        return out
    }

    // MARK: Rendering

    static let addedFill = NSColor(srgbRed: 0.20, green: 0.66, blue: 0.38, alpha: 0.16)
    static let addedLine = NSColor(srgbRed: 0.02, green: 0.47, blue: 0.34, alpha: 0.85)
    static let removedInk = NSColor(srgbRed: 0.75, green: 0.16, blue: 0.16, alpha: 1)
    static let removedFill = NSColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 0.06)

    /// The paper's look (matches PaperTextView): 15 pt, roomy lines.
    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 18
        return [.font: PaperTextView.font, .foregroundColor: NSColor.black, .paragraphStyle: style]
    }

    /// The newer draft with added words in soft green (underlined) and removed
    /// words struck through in red. Paragraph breaks come from the newer draft;
    /// a removed break shows as a struck pilcrow.
    static func attributed(_ result: Result) -> NSAttributedString {
        let base = baseAttributes()
        var added = base
        added[.backgroundColor] = addedFill
        added[.underlineStyle] = NSUnderlineStyle.single.rawValue
        added[.underlineColor] = addedLine
        var removed = base
        removed[.foregroundColor] = removedInk
        removed[.backgroundColor] = removedFill
        removed[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        removed[.strikethroughColor] = removedInk

        let out = NSMutableAttributedString()
        var lastChar: Character? = nil
        func put(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
            guard !s.isEmpty else { return }
            out.append(NSAttributedString(string: s, attributes: attrs))
            lastChar = s.last
        }
        let pieces = result.pieces
        for (k, p) in pieces.enumerated() {
            let t = p.token
            let next = k + 1 < pieces.count ? pieces[k + 1] : nil
            switch p.kind {
            case .same:
                put(t.isBreak ? "\n" : t.text + t.trailing, base)
            case .added:
                if t.isBreak { put("\n", base); continue }
                put(t.text, added)
                // Spaces inside an added phrase are part of the highlight.
                let inside = next?.kind == .added && next?.token.isBreak == false
                put(t.trailing, inside ? added : base)
            case .removed:
                // Removed words carry the older draft's spacing, which may not
                // fit the newer text around them: make sure they stand apart.
                if let c = lastChar, !c.isWhitespace, t.isWord || t.isBreak { put(" ", base) }
                put(t.isBreak ? "\u{00B6}" : t.text, removed)
                let inside = next?.kind == .removed && next?.token.isBreak == false
                // A word folded in from a rewrite carries the newer draft's
                // spacing; never leave a gap before a closing mark.
                let closes = inside && next.map { ",.;:!?)]\u{201D}".contains($0.token.text) } == true
                if closes {
                    // no space
                } else if !t.trailing.isEmpty {
                    put(inside ? t.trailing : " ", inside ? removed : base)
                } else if t.isBreak || (next?.token.isWord == true && next?.kind != .removed) {
                    put(" ", base)
                }
            }
        }
        return out
    }
}
