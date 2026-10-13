import Foundation

/// Date of the last change, as short as it can be: the time today, "Hier", then the day.
enum NoteDate {
    static func label(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Hier" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.day().month(.abbreviated)) }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// Under the title of a note of the trash: what becomes of it.
    static func trashMeta(daysLeft: Int) -> String {
        switch daysLeft {
        case 0: "Dans la corbeille  ·  supprimée au prochain lancement"
        case 1: "Dans la corbeille  ·  supprimée dans 1 jour"
        default: "Dans la corbeille  ·  supprimée dans \(daysLeft) jours"
        }
    }

    /// Under a note's title, short: the day it was created (the year only when it isn't this
    /// one), then when it was last changed, said the way one would — "aujourd'hui", "hier", or the
    /// day — with the time. `fullMeta` says it in full, for the tooltip.
    static func meta(created: Date, modified: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        "Créée \(created.formatted(day(created, now: now, calendar: calendar)))  ·  modifiée \(relative(modified, now: now, calendar: calendar))"
    }

    /// The dates in full, years and times included.
    static func fullMeta(created: Date, modified: Date) -> String {
        let style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()
        return "Créée le \(created.formatted(style))\nModifiée le \(modified.formatted(style))"
    }

    private static func day(_ date: Date, now: Date, calendar: Calendar) -> Date.FormatStyle {
        calendar.isDate(date, equalTo: now, toGranularity: .year) ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year()
    }

    private static func relative(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "aujourd'hui à \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "hier à \(time)" }
        return "le \(date.formatted(day(date, now: now, calendar: calendar))) à \(time)"
    }
}
