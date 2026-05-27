import SwiftUI

/// Compact, Calendar.app-style form for creating an event from the
/// planner's EventAction. Icon-prefixed rows instead of label-stacked
/// fields; title is inline at the top; buttons pinned to the bottom so
/// they never get clipped on a long notes block.
struct CalendarComposeView: View {
    @ObservedObject var viewModel: SearchViewModel
    let event: EventAction
    let sourceSnippet: String
    let sending: Bool

    @State private var attendeesText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    titleHeader
                    Divider().opacity(0.18)
                    dateRow
                    attendeesRow
                    locationRow
                    notesArea
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 360)
            buttonBar
        }
    }

    // MARK: - Header (editable title)

    private var titleHeader: some View {
        HStack(spacing: 12) {
            calendarBadge
            VStack(alignment: .leading, spacing: 2) {
                TextField("Event title", text: Binding(
                    get: { event.title },
                    set: { viewModel.updateEventTitle($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                Text("Create in Calendar")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var calendarBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.red, Color.red.opacity(0.78)],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: 34, height: 34)
            Image(systemName: "calendar")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Date + duration row

    private var dateRow: some View {
        IconRow(icon: "clock") {
            HStack(spacing: 8) {
                DatePicker("", selection: Binding(
                    get: { event.startDate },
                    set: { viewModel.updateEventStartDate($0) }
                ), displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()

                Text("·")
                    .foregroundStyle(.tertiary)

                Picker("", selection: Binding(
                    get: { event.durationMinutes },
                    set: { viewModel.updateEventDuration($0) }
                )) {
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("45 min").tag(45)
                    Text("1 hr").tag(60)
                    Text("1.5 hr").tag(90)
                    Text("2 hr").tag(120)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Attendees row

    private var attendeesRow: some View {
        IconRow(icon: "person.2") {
            TextField("Add attendees, comma-separated", text: $attendeesText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onAppear {
                    if attendeesText.isEmpty {
                        attendeesText = event.attendees.joined(separator: ", ")
                    }
                }
                .onChange(of: attendeesText) { _, new in
                    let parts = new.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    viewModel.updateEventAttendees(parts)
                }
        }
    }

    // MARK: - Location row

    private var locationRow: some View {
        IconRow(icon: "mappin") {
            TextField("Add location", text: Binding(
                get: { event.location },
                set: { viewModel.updateEventLocation($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
        }
    }

    // MARK: - Notes

    private var notesArea: some View {
        IconRow(icon: "text.alignleft", topAlign: true) {
            ZStack(alignment: .topLeading) {
                if event.notes.isEmpty {
                    Text("Add notes")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .padding(.leading, 4)
                }
                TextEditor(text: Binding(
                    get: { event.notes },
                    set: { viewModel.updateEventNotes($0) }
                ))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 110)
            }
        }
    }

    // MARK: - Button bar (pinned to bottom)

    private var buttonBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: { viewModel.cancelCompose() }) {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .disabled(sending)

            Button(action: { viewModel.confirmSend() }) {
                HStack(spacing: 6) {
                    if sending {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .tint(.white)
                        Text("Creating…")
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Create event")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(minWidth: 124)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(
                            colors: sending
                                ? [Color.red.opacity(0.55), Color.red.opacity(0.4)]
                                : [Color.red, Color.red.opacity(0.85)],
                            startPoint: .top, endPoint: .bottom
                        ))
                )
                .animation(.easeOut(duration: 0.18), value: sending)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(sending)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.02))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(.white.opacity(0.10)),
            alignment: .top
        )
    }
}

/// Icon-prefixed row used by every field. SF Symbol on the left at fixed
/// width keeps the form columns aligned without any explicit grid.
private struct IconRow<Content: View>: View {
    let icon: String
    var topAlign: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: topAlign ? .top : .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
                .padding(.top, topAlign ? 4 : 0)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
