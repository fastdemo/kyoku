import SwiftUI

/// Activity: chronological automation feed (sync runs, downloads,
/// failures). Read-only; details inline. Not a dashboard.
struct ActivityView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity")
                .font(.largeTitle).fontWeight(.bold)
                .padding(20)
            Divider()
            let events = container.readyAutomation.recentActivity
            if events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("No activity yet")
                        .font(.headline)
                    Text("Sync runs will appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(grouped(events), id: \.day) { group in
                    Section(group.day) {
                        ForEach(group.events, id: \.id) { event in
                            HStack(spacing: 12) {
                                Text(event.createdAt.formatted(date: .omitted, time: .shortened))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.title)
                                        .lineLimit(2)
                                    if !event.detail.isEmpty {
                                        Text(event.detail)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Activity")
    }

    private struct DayGroup {
        var day: String
        var events: [ActivityEvent]
    }

    private func grouped(_ events: [ActivityEvent]) -> [DayGroup] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [ActivityEvent]] = [:]
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        for event in events {
            let key: String
            if calendar.isDateInToday(event.createdAt) {
                key = "Today"
            } else if calendar.isDateInYesterday(event.createdAt) {
                key = "Yesterday"
            } else {
                key = formatter.string(from: event.createdAt)
            }
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]!.append(event)
        }
        return order.map { DayGroup(day: $0, events: buckets[$0]!) }
    }
}
