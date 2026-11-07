import SwiftUI

struct MonthCalendar: View {
    @Binding var selected: Date
    let marked: Set<Date>
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.firstWeekday = 2
        return value
    }

    private var monthStart: Date {
        calendar.dateInterval(of: .month, for: selected)?.start ?? selected
    }

    private var days: [Date?] {
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
        return Array(repeating: nil, count: leading)
            + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: monthStart) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                monthButton(offset: -1, icon: "chevron.left", label: "上个月")
                Spacer()
                Text(monthStart, format: .dateTime.year().month(.defaultDigits).locale(chineseLocale))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                monthButton(offset: 1, icon: "chevron.right", label: "下个月")
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdays, id: \.self) { day in
                    Text(day)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayButton(date)
                    } else {
                        Color.clear.frame(height: 44).accessibilityHidden(true)
                    }
                }
            }
            .padding(8)
            .background(Palette.mint, in: RoundedRectangle(cornerRadius: 18))
            if !calendar.isDateInToday(selected) {
                Button("回到今天") { selected = calendar.startOfDay(for: .now) }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
        }
        .foregroundStyle(Palette.ink)
    }

    private func monthButton(offset: Int, icon: String, label: String) -> some View {
        Button {
            if let month = calendar.date(byAdding: .month, value: offset, to: monthStart) {
                selected = month
            }
        } label: {
            Image(systemName: icon).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dayButton(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selected)
        let hasTask = marked.contains(date)
        let isToday = calendar.isDateInToday(date)
        return Button { selected = date } label: {
            VStack(spacing: 3) {
                Text(calendar.component(.day, from: date), format: .number)
                    .font(.subheadline.monospacedDigit().weight(isToday || isSelected ? .bold : .regular))
                Circle()
                    .fill(hasTask ? (isSelected ? Palette.canvas : Palette.jade) : .clear)
                    .frame(width: 5, height: 5)
            }
            .foregroundStyle(isSelected ? Palette.canvas : (isToday ? Palette.jade : Palette.ink))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? Palette.jade : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayLabel(date) + (hasTask ? "，有待办" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
