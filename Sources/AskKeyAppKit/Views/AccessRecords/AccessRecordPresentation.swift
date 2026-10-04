import Foundation
import AskKeyVault

/// Access records as date-grouped rows: a time, one sentence and one
/// colored result.
struct AccessRecordPresentation: Equatable {
    struct Row: Equatable {
        let id: Int
        let time: String
        let sentence: EmphasizedSentence
        let resultTitle: String
        let resultRole: StatusLabel.Role
    }

    struct Section: Equatable {
        let title: String
        let rows: [Row]
    }

    let sections: [Section]

    init(
        records: [CredentialAccessEvent],
        credentialName: (String?) -> String,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = AppLanguage.locale(for: AppLanguage.current)
    ) {
        let ordered = records.enumerated().sorted { $0.element.timestamp > $1.element.timestamp }
        var sections: [Section] = []
        var currentDay: Date?
        var rows: [Row] = []
        for (index, event) in ordered {
            let day = calendar.startOfDay(for: event.timestamp)
            if day != currentDay {
                if let currentDay, !rows.isEmpty {
                    sections.append(.init(title: Self.dayTitle(currentDay, now: now, calendar: calendar, locale: locale), rows: rows))
                }
                currentDay = day
                rows = []
            }
            rows.append(Self.row(index: index, event: event, credentialName: credentialName, calendar: calendar, locale: locale))
        }
        if let currentDay, !rows.isEmpty {
            sections.append(.init(title: Self.dayTitle(currentDay, now: now, calendar: calendar, locale: locale), rows: rows))
        }
        self.sections = sections
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        if day == today { return appLocalized("Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return appLocalized("Yesterday")
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: today)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMdEEE" : "yMMMd")
        return formatter.string(from: day)
    }

    private static func row(
        index: Int,
        event: CredentialAccessEvent,
        credentialName: (String?) -> String,
        calendar: Calendar,
        locale: Locale
    ) -> Row {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "HH:mm"
        let caller = event.callerHint ?? appLocalized("Local Caller")
        let name = credentialName(event.credentialID)
        let sentence: EmphasizedSentence
        switch event.operation {
        case .catalog:
            sentence = .init(format: appLocalized("%@ browsed the credential list"), arguments: [caller])
        case .runtimeRead:
            if let executable = event.executableBasename, !executable.isEmpty {
                sentence = .init(
                    format: appLocalized("%1$@ used %2$@ to run %3$@"),
                    arguments: [caller, name, executable]
                )
            } else {
                sentence = .init(format: appLocalized("%1$@ used %2$@"), arguments: [caller, name])
            }
        case .create:
            sentence = .init(format: appLocalized("%1$@ created credential %2$@"), arguments: [caller, name])
        case .modify:
            sentence = .init(format: appLocalized("%1$@ changed credential %2$@"), arguments: [caller, name])
        case .delete:
            sentence = .init(format: appLocalized("%1$@ deleted credential %2$@"), arguments: [caller, name])
        }
        let result = Self.result(event)
        return .init(
            id: index,
            time: formatter.string(from: event.timestamp),
            sentence: sentence,
            resultTitle: result.title,
            resultRole: result.role
        )
    }

    private static func result(_ event: CredentialAccessEvent) -> (title: String, role: StatusLabel.Role) {
        switch event.result {
        case .allowed:
            let isWrite = [.create, .modify, .delete].contains(event.operation)
            return (isWrite ? appLocalized("Approved") : appLocalized("Allowed"), .accent)
        case .denied: return (appLocalized("Denied"), .warning)
        case .failed: return (appLocalized("Failed"), .warning)
        case .hiddenNameRejected: return (appLocalized("Hidden"), .neutral)
        }
    }
}
