import EventKit

// Finds the calendar event a recording happened during, to name its folder and tell the summary who was there.
enum MeetingCalendar {
    struct Event: Codable {
        let title: String
        let attendees: [String]
    }

    static func requestAccess() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        EKEventStore().requestFullAccessToEvents { granted, _ in
            Log.write("Meetings: calendar access \(granted ? "granted" : "not granted")")
        }
    }

    static func event(at date: Date) -> Event? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-6 * 3600), end: date.addingTimeInterval(1800),
                                                 calendars: nil)
        // Joining up to 10 minutes early or 5 minutes after the end still counts. An event with other people beats a
        // block on the calendar, then the one starting closest to when the recording did.
        let candidates = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.startDate <= date.addingTimeInterval(600) && $0.endDate >= date.addingTimeInterval(-300)
        }
        func rank(_ event: EKEvent) -> (Int, TimeInterval) {
            (event.hasAttendees ? 0 : 1, abs(event.startDate.timeIntervalSince(date)))
        }
        guard let event = candidates.min(by: { rank($0) < rank($1) }), let title = event.title, !title.isEmpty else { return nil }
        let attendees = (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { person -> String? in
            if let name = person.name, !name.isEmpty { return name }
            let address = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return address.isEmpty ? nil : address
        }
        return Event(title: title, attendees: attendees)
    }
}
