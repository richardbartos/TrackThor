import SwiftUI

struct TimelineBar: View {
  let startedAt: Date
  let endedAt: Date
  let gaps: [Gap]

  var body: some View {
    GeometryReader { geo in
      Canvas { context, size in
        let total = max(1, endedAt.timeIntervalSince(startedAt))
        let height = size.height
        let radius: CGFloat = 5

        let segments = buildSegments()
        var x: CGFloat = 0
        for seg in segments {
          let w = CGFloat(seg.duration / total) * size.width
          let rect = CGRect(x: x, y: 0, width: w, height: height)
          let path = Path(roundedRect: rect, cornerRadius: radius)
          context.fill(path, with: .color(seg.kind == .active ? .green : .gray))
          x += w
        }
      }
    }
  }

  private enum Kind { case active, gap }
  private struct Segment {
    let kind: Kind
    let duration: TimeInterval
  }

  private func buildSegments() -> [Segment] {
    let clampedGaps = gaps
      .map { (max($0.startedAt, startedAt), min($0.endedAt, endedAt)) }
      .filter { $0.1 > $0.0 }
      .sorted { $0.0 < $1.0 }

    if clampedGaps.isEmpty {
      return [Segment(kind: .active, duration: endedAt.timeIntervalSince(startedAt))]
    }

    var segs: [Segment] = []
    var cursor = startedAt
    for (gs, ge) in clampedGaps {
      if gs > cursor {
        segs.append(Segment(kind: .active, duration: gs.timeIntervalSince(cursor)))
      }
      segs.append(Segment(kind: .gap, duration: ge.timeIntervalSince(gs)))
      cursor = ge
    }
    if cursor < endedAt {
      segs.append(Segment(kind: .active, duration: endedAt.timeIntervalSince(cursor)))
    }
    return segs
  }
}

