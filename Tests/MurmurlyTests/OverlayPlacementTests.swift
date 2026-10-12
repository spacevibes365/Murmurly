import CoreGraphics
import XCTest
@testable import Murmurly

final class OverlayPlacementTests: XCTestCase {
    private let negativeScreen = IndicatorScreenGeometry(
        displayID: 10,
        visibleFrame: CGRect(x: -1_920, y: -120, width: 1_920, height: 1_050)
    )

    func testAllFourEdgesRoundTripOnNegativeOriginScreen() throws {
        let panelSize = CGSize(width: 240, height: 40)
        let placements = [
            OverlayPlacement(displayID: 10, fractionX: 0, fractionY: 0),
            OverlayPlacement(displayID: 10, fractionX: 1, fractionY: 0),
            OverlayPlacement(displayID: 10, fractionX: 0, fractionY: 1),
            OverlayPlacement(displayID: 10, fractionX: 1, fractionY: 1),
        ]

        for placement in placements {
            let frame = try XCTUnwrap(OverlayGeometry.frame(
                for: placement,
                panelSize: panelSize,
                screens: [negativeScreen],
                mainDisplayID: negativeScreen.displayID
            ))
            XCTAssertEqual(
                OverlayGeometry.placement(of: frame, on: negativeScreen),
                placement
            )
            XCTAssertTrue(negativeScreen.visibleFrame.contains(frame))
        }
    }

    func testChangingPanelWidthPreservesFractionAndKeepsFrameVisible() throws {
        let placement = OverlayPlacement(displayID: 10, fractionX: 0.72, fractionY: 0.35)
        let narrow = try XCTUnwrap(OverlayGeometry.frame(
            for: placement,
            panelSize: CGSize(width: 90, height: 40),
            screens: [negativeScreen],
            mainDisplayID: 10
        ))
        let wide = try XCTUnwrap(OverlayGeometry.frame(
            for: placement,
            panelSize: CGSize(width: 600, height: 40),
            screens: [negativeScreen],
            mainDisplayID: 10
        ))

        XCTAssertEqual(
            OverlayGeometry.placement(of: narrow, on: negativeScreen).fractionX,
            placement.fractionX,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            OverlayGeometry.placement(of: wide, on: negativeScreen).fractionX,
            placement.fractionX,
            accuracy: 0.000_001
        )
        XCTAssertTrue(negativeScreen.visibleFrame.contains(wide))
    }

    func testCorruptStoredFractionsClampToAvailableTravel() throws {
        let frame = try XCTUnwrap(OverlayGeometry.frame(
            for: OverlayPlacement(displayID: 10, fractionX: -4, fractionY: 8),
            panelSize: CGSize(width: 200, height: 40),
            screens: [negativeScreen],
            mainDisplayID: 10
        ))

        XCTAssertEqual(frame.minX, negativeScreen.visibleFrame.minX)
        XCTAssertEqual(frame.minY, negativeScreen.visibleFrame.minY)
    }

    func testMissingDisplayFallsBackToPassedMainDisplay() throws {
        let main = IndicatorScreenGeometry(
            displayID: 20,
            visibleFrame: CGRect(x: 0, y: 25, width: 1_440, height: 875)
        )
        let frame = try XCTUnwrap(OverlayGeometry.frame(
            for: OverlayPlacement(displayID: 999, fractionX: 0.5, fractionY: 0.5),
            panelSize: CGSize(width: 200, height: 40),
            screens: [negativeScreen, main],
            mainDisplayID: main.displayID
        ))

        XCTAssertTrue(main.visibleFrame.contains(frame))
        XCTAssertFalse(negativeScreen.visibleFrame.intersects(frame))
    }

    func testZeroAndNegativeTravelHaveStableOrigin() throws {
        let exact = try XCTUnwrap(OverlayGeometry.frame(
            for: OverlayPlacement(displayID: 10, fractionX: 0.8, fractionY: 0.3),
            panelSize: negativeScreen.visibleFrame.size,
            screens: [negativeScreen],
            mainDisplayID: 10
        ))
        XCTAssertEqual(exact, negativeScreen.visibleFrame)

        let oversized = try XCTUnwrap(OverlayGeometry.frame(
            for: OverlayPlacement(displayID: 10, fractionX: 1, fractionY: 1),
            panelSize: CGSize(width: 2_000, height: 1_200),
            screens: [negativeScreen],
            mainDisplayID: 10
        ))
        XCTAssertEqual(oversized.origin, negativeScreen.visibleFrame.origin)
    }

    func testTopLeftOffsetUsesVisibleFrameCoordinates() {
        let frame = CGRect(x: -1_620, y: 698, width: 200, height: 40)

        XCTAssertEqual(
            OverlayGeometry.topLeftOffset(of: frame, in: negativeScreen.visibleFrame),
            CGPoint(x: 300, y: 192)
        )
    }
}
