import Foundation
import LoomCore
import LoomRemora

/// What Home says around Remora's own sentences (DESIGN §9 and §20): the headings, the date line, the reading line, the
/// footer, the states and the failure sentences, in Sphyrna's plain voice. Plain values, so a test reads the words without a
/// view. The sentences of the brief and of an answer are the model's and are not made here.
enum HomeRemoraText {
    static let heading = "Where you left off"
    static let fieldPlaceholder = "Ask Remora about your sessions"
    static let allProjects = "All projects"
    static let catchMeUp = "Catch Me Up"
    static let catchMeUpAnyway = "Catch Me Up Anyway"
    static let tryAgain = "Try Again"
    static let showBrief = "Show Brief"
    static let sources = "Sources"
    static let memory = "Memory…"
    static let settings = "Settings…"

    /// When I ask, and a brief that has not been written: the catalog's tiles stand in.
    static let whenIAsk = "Your latest sessions, newest first."
    /// Before any session.
    static let beforeAnySession = "Remora reads your sessions and tells you where you left off. It answers once you have a session."
    /// The login sentence (the Claude Code login is missing or expired).
    static let notLoggedIn = "Remora uses your Claude Code login. Log in with claude in a terminal."
    /// Every other kind of failure.
    static let couldNotAnswer = "Remora could not get an answer from Claude."
    /// A stopped question keeps its words and says so; a stopped brief points at Catch Me Up.
    static let stoppedQuestion = "Stopped. Ask again for the whole answer."
    static let stoppedBrief = "Stopped. Catch Me Up writes the whole brief."

    /// The sentence for a failure of the brief, and whether it offers Try Again.
    static func failure(_ kind: RemoraFailure.Kind) -> String { kind == .notLoggedIn ? notLoggedIn : couldNotAnswer }

    /// "Less than a tenth of your 5-hour limit is left until 13:40, so the morning brief waits. Questions still run." The share is the
    /// setting (a tenth by default); the time is when the window resets, and is left out when it is not known.
    static func waitSentence(threshold: Double, resetsAt: Date?, timeZone: TimeZone, locale: Locale = .current) -> String {
        let share = abs(threshold - 0.10) < 0.0005 ? "a tenth" : UsageFormat.percent(fraction: threshold)
        let until = resetsAt.map { " until " + LoomDateFormat.time24($0, zone: timeZone, locale: locale) } ?? ""
        return "Less than \(share) of your 5-hour limit is left\(until), so the morning brief waits. Questions still run."
    }

    // MARK: Dates

    /// "tuesday 20 october · 09:12": the day and the time of the brief (the span it covers is not exposed by the host).
    static func whenLine(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        HomeBandText.dateLine(date, zone: zone, locale: locale, calendar: calendar)
    }

    /// "You asked at 11:20".
    static func youAskedAt(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        "You asked at " + LoomDateFormat.time24(date, zone: zone, locale: locale, calendar: calendar)
    }

    /// The Earlier line's time, "11:20".
    static func earlierTime(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        LoomDateFormat.time24(date, zone: zone, locale: locale, calendar: calendar)
    }

    /// "quiet since Wednesday" within the week, "quiet since 12 october" before it. Lower-case dates, as the date line.
    static func quietSince(_ date: Date, now: Date, zone: TimeZone? = nil, locale: Locale = .current,
                           calendar: Calendar = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        if let zone { calendar.timeZone = zone }
        if now.timeIntervalSince(date) < 6 * 86_400 {
            return "quiet since " + LoomDateFormat.weekdayLong(date, zone: zone, locale: locale, calendar: calendar)
        }
        let parts = calendar.dateComponents([.day, .month], from: date)
        let month = parts.month.flatMap { calendar.standaloneMonthSymbols.indices.contains($0 - 1) ? calendar.standaloneMonthSymbols[$0 - 1] : nil }
        return "quiet since " + [parts.day.map(String.init), month].compactMap { $0 }.joined(separator: " ").lowercased(with: locale)
    }

    /// The tile's head time: a project note's day as "today", "yesterday" or "20 october".
    static func noteDay(_ day: String, now: Date, zone: TimeZone? = nil, locale: Locale = .current,
                        calendar: Calendar = .current) -> String? {
        var calendar = calendar
        calendar.locale = locale
        if let zone { calendar.timeZone = zone }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        let month = calendar.standaloneMonthSymbols.indices.contains(parts[1] - 1) ? calendar.standaloneMonthSymbols[parts[1] - 1] : nil
        return ([String(parts[2])] + [month].compactMap { $0 }).joined(separator: " ").lowercased(with: locale)
    }

    // MARK: Reading, footer, sources

    /// "Reading 6 sessions and 3 project notes…"; a question about one project names it ("Reading 3 sessions in loom and its note…");
    /// before the pack is known, "Reading your sessions…".
    static func readingLine(_ reading: RemoraReading?) -> String {
        guard let reading else { return "Reading your sessions…" }
        let sessions = plural(reading.sessions, "session")
        let subject = reading.project?.name.map { " in \($0)" } ?? ""
        if reading.projectNotes <= 0 { return "Reading \(sessions)\(subject)…" }
        if reading.project != nil, reading.projectNotes == 1 { return "Reading \(sessions)\(subject) and its note…" }
        return "Reading \(sessions)\(subject) and \(plural(reading.projectNotes, "project note"))…"
    }

    /// "Remora read 6 sessions and 3 project notes · 4.6 s". The host's footer is "read 6 sessions and 3 project notes".
    static func footer(_ footer: String, duration: TimeInterval?) -> String {
        var line = "Remora " + footer
        if let duration { line += " \u{00B7} " + seconds(duration) }
        return line
    }

    /// "4.6 s".
    static func seconds(_ value: TimeInterval) -> String { String(format: "%.1f s", max(0, value)) }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The Sources popover's foot: "6 sessions · 3 notes · 28K tokens · 4.6 s".
    static func sourcesFoot(sessions: Int, notes: Int, tokens: Int?, duration: TimeInterval?) -> String {
        var parts = [plural(sessions, "session"), plural(notes, "note")]
        if let tokens { parts.append(UsageFormat.tokens(Int64(tokens)) + " tokens") }
        if let duration { parts.append(seconds(duration)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func sourcesLabel(brief: Bool) -> String { brief ? "Read for this brief" : "Read for this answer" }

    static func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)" + (count == 1 ? "" : "s") }

    // MARK: The fold

    /// "morning brief 09:12 · 2 of 3 picked up"; the time is left out when it is not known. "Remora · " goes before it.
    static func foldTail(startedAt: Date?, pickedUp: Int, of total: Int, zone: TimeZone? = nil, locale: Locale = .current,
                         calendar: Calendar = .current) -> String {
        var line = "morning brief"
        if let startedAt { line += " " + LoomDateFormat.time24(startedAt, zone: zone, locale: locale, calendar: calendar) }
        return line + " \u{00B7} \(pickedUp) of \(total) picked up"
    }

    // MARK: Put in Draft

    /// The button's title, its help tag and its accessibility hint (D-95): Put in Draft only where the line will be placed, Copy to
    /// Clipboard where it can only be copied, and Copied once it was. The accessibility label is the title. Put in Draft has no help
    /// tag: its hover popover says where the line goes.
    static func draftButton(plan: RemoraHomeDraftPlan, result: RemoraHomeDraftResult?) -> (title: String, help: String?, hint: String) {
        switch result {
        case .copied(let reason): return ("Copied", copyReason(reason), copyReason(reason))
        case .copiedNotSaved:
            let why = "The session's draft could not be saved, so the line was copied"
            return ("Copied", why, why)
        case .placed, nil: break
        }
        switch plan {
        case .place:
            return ("Put in Draft", nil, "Puts the next step below the session's composer text without sending it, and opens the session")
        case .copy(let reason): return ("Copy to Clipboard", copyReason(reason), copyReason(reason))
        }
    }

    /// The harness `RemoraCopyReason.codex` names.
    private static let codexName = HarnessCapabilities.intrinsic(of: .codex).displayName

    static func copyReason(_ reason: RemoraCopyReason) -> String {
        switch reason {
        case .terminal: "This session runs in the terminal, so the line is copied"
        case .codex: "Sphyrna cannot open \(codexName) sessions yet, so the line is copied"
        }
    }

    /// The hover popover's first line, from what Put in Draft would do now.
    static func hoverWhere(_ plan: RemoraHomeDraftPlan) -> String {
        switch plan {
        case .place: "Goes below its composer's text, not sent, and the session opens"
        case .copy(.terminal): "It runs in the terminal, so this is copied"
        case .copy(.codex): "Sphyrna cannot open \(codexName) sessions yet, so this is copied"
        }
    }

    static let hoverKey = "The composer's own \u{21B5} sends it. Sphyrna never does."
}
