import AppKit

struct OverlayPlacement: Codable, Equatable, Sendable {
    var displayID: UInt32
    var fractionX: Double
    var fractionY: Double
}

struct IndicatorScreenGeometry: Equatable, Sendable {
    var displayID: UInt32
    var visibleFrame: CGRect
}

enum OverlayGeometry {
    static func placement(
        of panelFrame: CGRect,
        on screen: IndicatorScreenGeometry
    ) -> OverlayPlacement {
        let travelX = screen.visibleFrame.width - panelFrame.width
        let travelY = screen.visibleFrame.height - panelFrame.height
        let fractionX = travelX > 0
            ? (panelFrame.minX - screen.visibleFrame.minX) / travelX
            : 0
        let fractionY = travelY > 0
            ? (screen.visibleFrame.maxY - panelFrame.maxY) / travelY
            : 0
        return OverlayPlacement(
            displayID: screen.displayID,
            fractionX: clampedFraction(fractionX),
            fractionY: clampedFraction(fractionY)
        )
    }

    static func frame(
        for placement: OverlayPlacement,
        panelSize: CGSize,
        screens: [IndicatorScreenGeometry],
        mainDisplayID: UInt32?
    ) -> CGRect? {
        guard let screen = screens.first(where: { $0.displayID == placement.displayID })
                ?? mainDisplayID.flatMap({ mainID in
                    screens.first(where: { $0.displayID == mainID })
                })
                ?? screens.first else { return nil }
        let visible = screen.visibleFrame
        let travelX = max(visible.width - panelSize.width, 0)
        let travelY = max(visible.height - panelSize.height, 0)
        let frame = CGRect(
            x: visible.minX + travelX * clampedFraction(placement.fractionX),
            y: visible.maxY - panelSize.height
                - travelY * clampedFraction(placement.fractionY),
            width: panelSize.width,
            height: panelSize.height
        )
        return clamped(frame: frame, inside: visible)
    }

    static func defaultFrame(panelSize: CGSize, visibleFrame: CGRect) -> CGRect {
        clamped(
            frame: CGRect(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.minY + visibleFrame.height * 0.18,
                width: panelSize.width,
                height: panelSize.height
            ),
            inside: visibleFrame
        )
    }

    static func topLeftOffset(of panelFrame: CGRect, in visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: panelFrame.minX - visibleFrame.minX,
            y: visibleFrame.maxY - panelFrame.maxY
        )
    }

    static func screen(
        containing panelFrame: CGRect,
        screens: [IndicatorScreenGeometry]
    ) -> IndicatorScreenGeometry? {
        screens.max {
            $0.visibleFrame.intersection(panelFrame).area
                < $1.visibleFrame.intersection(panelFrame).area
        }
    }

    private static func clamped(frame: CGRect, inside visible: CGRect) -> CGRect {
        let x = frame.width <= visible.width
            ? min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            : visible.minX
        let y = frame.height <= visible.height
            ? min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            : visible.minY
        return CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
    }

    private static func clampedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

extension NSScreen {
    var indicatorGeometry: IndicatorScreenGeometry? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber else { return nil }
        return IndicatorScreenGeometry(
            displayID: number.uint32Value,
            visibleFrame: visibleFrame
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return width * height
    }
}
