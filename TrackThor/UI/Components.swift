import SwiftUI

/// Rounded content card using system colors (works in light and dark mode).
struct Card<Content: View>: View {
  let title: String
  var subtitle: String?
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(.headline)
        if let subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground()
  }
}

extension View {
  func cardBackground(cornerRadius: CGFloat = 12) -> some View {
    background(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}

/// Big number tile: icon + caption, value, small detail line.
struct StatTile: View {
  let title: String
  let value: String
  var detail: String?
  let systemImage: String
  var tint: Color = .accentColor

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(tint)
      Text(value)
        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(detail ?? " ")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardBackground()
  }
}

struct LegendDot: View {
  let color: Color
  let label: String

  var body: some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(color)
        .frame(width: 10, height: 10)
      Text(label)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

/// Hour labels under a timeline spanning `span`.
struct TimelineAxis: View {
  let span: DateInterval

  var body: some View {
    GeometryReader { geometry in
      let marks = hourMarks()
      ZStack(alignment: .topLeading) {
        ForEach(marks, id: \.self) { mark in
          let fraction = mark.timeIntervalSince(span.start) / max(1, span.duration)
          Text(DateFormatting.timeFormatter.string(from: mark))
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .position(x: CGFloat(fraction) * geometry.size.width, y: 6)
        }
      }
    }
  }

  /// Full hours inside the span; every 2 hours on long days. Marks too close to the edges are dropped.
  private func hourMarks() -> [Date] {
    let calendar = Calendar.current
    guard span.duration >= 3600,
          var hour = calendar.dateInterval(of: .hour, for: span.start)?.end
    else { return [] }

    let step = span.duration > 10 * 3600 ? 2 : 1
    if step == 2, calendar.component(.hour, from: hour) % 2 == 1 {
      hour = hour.addingTimeInterval(3600)
    }
    let margin = span.duration * 0.04

    var marks: [Date] = []
    while hour < span.end {
      if hour.timeIntervalSince(span.start) > margin && span.end.timeIntervalSince(hour) > margin {
        marks.append(hour)
      }
      hour = hour.addingTimeInterval(TimeInterval(step * 3600))
    }
    return marks
  }
}
