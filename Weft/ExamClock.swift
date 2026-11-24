//
//  ExamClock.swift
//  Weft — the text of the exam clock ("12:08 left") and what VoiceOver
//  reads for it (which still includes "Ends at 10:42 AM").
//
//  Pure functions, so the wording can be tested without the app.
//

import Foundation

enum ExamClock {
    /// Top line: time left. "12:08 left", "1:05:08 left", or "Time's up".
    static func leftText(remaining: Int) -> String {
        guard remaining > 0 else { return "Time's up" }
        let h = remaining / 3600
        let m = (remaining % 3600) / 60
        let s = remaining % 60
        if h > 0 { return String(format: "%d:%02d:%02d left", h, m, s) }
        return String(format: "%d:%02d left", m, s)
    }

    /// The real end time, in the Mac's own 12/24-hour style (spoken only).
    static func endsText(deadline: Date, locale: Locale = .autoupdatingCurrent,
                         timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return "Ends at \(deadline.formatted(style))"
    }

    /// What VoiceOver reads: no second-by-second chatter.
    static func spokenText(remaining: Int, deadline: Date, hidden: Bool,
                           locale: Locale = .autoupdatingCurrent,
                           timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let ends = endsText(deadline: deadline, locale: locale, timeZone: timeZone)
        if hidden { return "Time left hidden. \(ends). Show time" }
        guard remaining > 0 else { return "Time's up" }
        let mins = Int((Double(remaining) / 60).rounded(.up))
        return "\(mins) minute\(mins == 1 ? "" : "s") left. \(ends)"
    }
}
