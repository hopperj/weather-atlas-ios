import SwiftUI
import UIKit

struct GolfRoundEditorRoute: Identifiable {
  let id = UUID()
  var round: GolfRound?
  var chooseCourse = false
  var startWithPin = false
}

struct GolfRoundEditor: View {
  @ObservedObject var settings: GolfSettingsStore
  let route: GolfRoundEditorRoute
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: AppStore
  @State private var course: GolfCourse?
  @State private var localDate: String
  @State private var hour: Int
  @State private var minute: Int
  @State private var choosingCourse = false
  @State private var choosingDate = false
  @State private var confirmingDelete = false
  @State private var opened = false
  @State private var saveError = false

  init(settings: GolfSettingsStore, route: GolfRoundEditorRoute) {
    self.settings = settings
    self.route = route
    let prefs = settings.value
    let zone = route.round?.course.zone ?? TimeZone(identifier: prefs.timeZone) ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    _course = State(initialValue: route.round?.course)
    _localDate = State(
      initialValue: route.round?.localDate ?? GolfRound.dateString(tomorrow, zone: zone))
    _hour = State(initialValue: route.round?.teeHour ?? prefs.teeHour)
    _minute = State(initialValue: route.round?.teeMinute ?? prefs.teeMinute)
  }
  private var zone: TimeZone {
    course?.zone ?? TimeZone(identifier: settings.value.timeZone) ?? .current
  }
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }
  private var candidate: GolfRound? {
    course.map {
      GolfRound(
        id: route.round?.id ?? route.id, course: $0,
        localDate: localDate, teeHour: hour, teeMinute: minute)
    }
  }
  private var day: Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: localDate + " 12:00") ?? Date()
  }
  private var timeBinding: Binding<Date> {
    Binding(
      get: {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
      },
      set: {
        hour = calendar.component(.hour, from: $0)
        minute = calendar.component(.minute, from: $0)
      })
  }

  var body: some View {
    let frequent = settings.frequentCourses
    NavigationStack {
      Form {
        Section("Course or pin") {
          if let course {
            Label {
              VStack(alignment: .leading, spacing: 4) {
                Text(course.name).font(.headline)
                Text(course.locality).font(.caption).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: course.kind == .pin ? "mappin.and.ellipse" : "flag.fill")
            }
            if course.kind == .pin {
              TextField(
                "Pin name",
                text: Binding(
                  get: { self.course?.name ?? "" },
                  set: { self.course?.name = String($0.prefix(120)) })
              )
              .accessibilityIdentifier("golfPinName")
            }
          }
          Button {
            choosingCourse = true
          } label: {
            Label(
              course == nil ? "Find a Canadian course or drop a pin" : "Change course or pin",
              systemImage: "magnifyingglass")
          }.accessibilityIdentifier("golfChooseCourse")
          if !frequent.isEmpty {
            Text("Your usual courses")
              .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(frequent) { saved in
              Button {
                course = saved
                saveError = false
              } label: {
                HStack(spacing: 10) {
                  Image(systemName: saved.kind == .pin ? "mappin.and.ellipse" : "flag.fill")
                  VStack(alignment: .leading, spacing: 3) {
                    Text(saved.name).font(.subheadline.weight(.semibold))
                    Text(saved.locality).font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 0)
                  if course?.bookingKey == saved.bookingKey {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading)
              }
              .accessibilityLabel("Use \(saved.name), \(saved.locality)")
              .accessibilityValue(course?.bookingKey == saved.bookingKey ? "Selected" : "")
              .accessibilityIdentifier("golfQuickCourse-\(saved.name)")
            }
            Text("Up to five most-used courses from your saved tee times.")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
        Section {
          Button {
            choosingDate = true
          } label: {
            HStack {
              Text("Date").foregroundStyle(.primary)
              Spacer()
              Text(golfDate(day, zone: zone, pattern: "MMM d, yyyy"))
            }
          }
          .accessibilityLabel("Date")
          .accessibilityValue(golfDate(day, zone: zone, pattern: "EEEE, MMMM d, yyyy"))
          .accessibilityIdentifier("golfRoundDate")
          .popover(isPresented: $choosingDate) {
            GolfRoundCalendar(
              date: day,
              minimumDate: min(calendar.startOfDay(for: Date()), calendar.startOfDay(for: day)),
              calendar: calendar
            ) { selected in
              localDate = GolfRound.dateString(selected, zone: zone)
              choosingDate = false
            }
            .frame(width: 320).fixedSize(horizontal: false, vertical: true).padding(8)
            .presentationCompactAdaptation(.popover)
          }
          DatePicker("Tee time", selection: timeBinding, displayedComponents: .hourAndMinute)
            .accessibilityIdentifier("golfTeeTime")
          if let course {
            LabeledContent("Course time zone", value: course.timeZone).font(.caption)
          }
        } header: {
          Text("One round, one tee time")
        } footer: {
          Text(
            "The date and time are local to the selected course, even when you're travelling. Each round lasts four hours, with weather checked two hours before and one hour after."
          )
        }
        if let candidate {
          if !candidate.isValid {
            Text(
              "Check the pin name and tee time. A time skipped by a daylight-saving clock change cannot be saved."
            )
            .font(.caption).foregroundStyle(.red)
          } else if candidate.availability() == .pending {
            Label("Forecast pending", systemImage: "clock")
            Text(
              "You can save this round now. The weather will be checked when the date is within six days; missing forecast coverage is never guessed."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section {
          Text(
            "Tee times are saved on this device and stay here when you change tabs or reopen the app. This does not book a tee time with the course."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        if route.round != nil {
          Section {
            Button("Delete tee time", role: .destructive) { confirmingDelete = true }
              .accessibilityIdentifier("golfDeleteRound")
          }
        }
        if saveError {
          Text("Couldn't save this round. Check the course, date and time.").foregroundStyle(.red)
        }
      }
      .environment(\.timeZone, zone)
      .navigationTitle(route.round == nil ? "Add tee time" : "Edit tee time")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            guard let candidate, settings.saveRound(candidate) else {
              saveError = true
              return
            }
            // Retain convenient defaults without coupling the saved rounds to one another.
            var prefs = settings.value
            prefs.teeHour = hour
            prefs.teeMinute = minute
            prefs.timeZone = zone.identifier
            settings.save(prefs)
            dismiss()
          }.disabled(candidate?.isValid != true).accessibilityIdentifier("golfSaveRound")
        }
      }
      .sheet(isPresented: $choosingCourse) {
        GolfCoursePicker(
          initial: course, focus: store.forecastMapFocus,
          focusSearch: !route.startWithPin
        ) { course = $0 }
      }
      .confirmationDialog(
        "Delete this tee time?", isPresented: $confirmingDelete, titleVisibility: .visible
      ) {
        Button("Delete tee time", role: .destructive) {
          if let round = route.round { settings.deleteRound(round.id) }
          dismiss()
        }.accessibilityIdentifier("golfConfirmDeleteRound")
      } message: {
        Text("Other tee times and your weather limits will not change.")
      }
      .onAppear {
        guard !opened else { return }
        opened = true
        choosingCourse = route.chooseCourse
      }
    }
  }
}

/// A selection event closes the popover, including a tap on the already selected day.
struct GolfRoundCalendar: UIViewRepresentable {
  let date: Date
  let minimumDate: Date
  let calendar: Calendar
  let onChoose: (Date) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UICalendarView {
    context.coordinator.updatingSelection = true
    let view = UICalendarView()
    view.calendar = calendar
    view.timeZone = calendar.timeZone
    view.locale = context.environment.locale
    view.availableDateRange = DateInterval(start: minimumDate, end: .distantFuture)
    view.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
    view.accessibilityIdentifier = "golfRoundCalendar"
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    (view.selectionBehavior as? UICalendarSelectionSingleDate)?.setSelected(parts, animated: false)
    view.setVisibleDateComponents(parts, animated: false)
    context.coordinator.updatingSelection = false
    return view
  }
  func updateUIView(_ view: UICalendarView, context: Context) {
    context.coordinator.parent = self
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context)
    -> CGSize?
  {
    let width = proposal.width ?? 320
    let size = uiView.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    return CGSize(width: width, height: max(size.height, 320))
  }
  final class Coordinator: NSObject, UICalendarSelectionSingleDateDelegate {
    var parent: GolfRoundCalendar
    var updatingSelection = false
    init(_ parent: GolfRoundCalendar) { self.parent = parent }
    private func selectedDate(_ parts: DateComponents) -> Date? {
      guard let year = parts.year, let month = parts.month, let number = parts.day else {
        return nil
      }
      var day = parts
      day.calendar = parent.calendar
      day.timeZone = parent.calendar.timeZone
      day.hour = 12  // Avoid midnight daylight-saving transitions.
      guard let date = parent.calendar.date(from: day) else { return nil }
      let checked = parent.calendar.dateComponents([.year, .month, .day], from: date)
      return checked.year == year && checked.month == month && checked.day == number ? date : nil
    }
    func dateSelection(
      _ selection: UICalendarSelectionSingleDate, canSelectDate parts: DateComponents?
    ) -> Bool {
      guard let parts else { return true }  // Re-tapping the selected day accepts it too.
      guard let date = selectedDate(parts) else { return false }
      return date >= parent.minimumDate && date <= .distantFuture
    }
    func dateSelection(
      _ selection: UICalendarSelectionSingleDate, didSelectDate parts: DateComponents?
    ) {
      guard !updatingSelection else { return }
      guard let parts else {
        parent.onChoose(parent.date)
        return
      }
      guard let date = selectedDate(parts), date >= parent.minimumDate, date <= .distantFuture
      else { return }
      parent.onChoose(date)
    }
  }
}
