import CoreGraphics

/// Active display bounds in global CoreGraphics points (top-left origin of the main display; negative origins allowed).
public enum DisplayGeometry {
    public static func activeBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Clamps a pointer position onto the display arrangement, which lets it cross displays.
    /// With `confinedTo` set (the display that held the pointer before the move), it stays on that display.
    public static func clamp(_ point: CGPoint, confinedTo display: CGRect? = nil, bounds: [CGRect] = activeBounds()) -> CGPoint {
        if let display {
            return nearest(point, in: [display])
        }
        guard !bounds.isEmpty else { return point }
        return nearest(point, in: bounds)
    }

    /// Returns `point` inside the closest rectangle. Points inside a rectangle are returned unchanged.
    static func nearest(_ point: CGPoint, in rects: [CGRect]) -> CGPoint {
        var best = point
        var bestDistance = Double.infinity
        for rect in rects {
            let candidate = CGPoint(
                x: min(max(point.x, rect.minX), rect.maxX - 0.5),
                y: min(max(point.y, rect.minY), rect.maxY - 0.5)
            )
            let dx = candidate.x - point.x
            let dy = candidate.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }
}

/// The single definition of where a Click-mode target is clicked. The label's tail tip is drawn at this
/// exact point, so what the person sees is where a pointer action lands.
public enum ClickPoint {
    /// Height of a label callout plus its arrow at regular size.
    static let calloutClearance: CGFloat = 19

    /// A point just inside the bottom edge of the control, centred horizontally; the label hangs below it with
    /// its arrow touching this point. At the bottom of a display (the Dock) the point rises into the control
    /// so the label stays on screen, as Homerow's do.
    public static func of(_ frame: CGRect, displays: [CGRect] = DisplayGeometry.activeBounds(), scale: CGFloat = 1) -> (point: CGPoint, labelAbove: Bool) {
        let inset = min(frame.height * 0.2, 3 * scale)
        let display = displays.first { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? displays.first
        var y = frame.maxY - inset
        if let display {
            y = max(min(y, display.maxY - calloutClearance * scale), frame.minY + inset)
        }
        return (CGPoint(x: frame.midX, y: y), false)
    }
}
