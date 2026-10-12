import AppKit
import XCTest
@testable import Murmurly

@MainActor
final class TextInjectorTests: XCTestCase {
    func testAutoPasteRoundTripsMultipleItemsAndTypesWithAsymmetricOptions() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let original = try seedMultipleItems(on: pasteboard)
        let prepareRecorder = PrepareRecorder()
        var pastedText: String?

        let didPostPaste = await TextInjector.inject(
            "надиктованный текст",
            pasteboard: pasteboard,
            prepare: { prepareRecorder.call($0, $1) },
            writeText: liveWriteText,
            postPaste: {
                pastedText = pasteboard.string(forType: .string)
                return true
            },
            pause: {}
        )

        XCTAssertTrue(didPostPaste)
        XCTAssertEqual(pastedText, "надиктованный текст")
        XCTAssertEqual(prepareRecorder.options, [.currentHostOnly, []])
        XCTAssertEqual(materializedItems(from: pasteboard), original)
    }

    func testForeignCopyDuringPauseVetoesRestore() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.prepareForNewContents(with: [])
        XCTAssertTrue(pasteboard.writeObjects(["старое" as NSString]))
        let prepareRecorder = PrepareRecorder()

        let didPostPaste = await TextInjector.inject(
            "диктовка",
            pasteboard: pasteboard,
            prepare: { prepareRecorder.call($0, $1) },
            writeText: liveWriteText,
            postPaste: { true },
            pause: {
                _ = pasteboard.prepareForNewContents(with: [])
                XCTAssertTrue(pasteboard.writeObjects(["чужая новая копия" as NSString]))
            }
        )

        XCTAssertTrue(didPostPaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "чужая новая копия")
        XCTAssertEqual(prepareRecorder.options, [.currentHostOnly])
    }

    func testEmptyPasteboardIsRestoredToEmpty() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.prepareForNewContents(with: [])
        let prepareRecorder = PrepareRecorder()

        let didPostPaste = await TextInjector.inject(
            "диктовка",
            pasteboard: pasteboard,
            prepare: { prepareRecorder.call($0, $1) },
            writeText: liveWriteText,
            postPaste: { true },
            pause: {}
        )

        XCTAssertTrue(didPostPaste)
        XCTAssertEqual(prepareRecorder.options, [.currentHostOnly, []])
        XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)
    }

    func testFailedWriteRestoresImmediatelyAndDoesNotPostPaste() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.prepareForNewContents(with: [])
        XCTAssertTrue(pasteboard.writeObjects(["важное старое" as NSString]))
        let prepareRecorder = PrepareRecorder()
        var postPasteCalled = false
        var pauseCalled = false

        let didPostPaste = await TextInjector.inject(
            "диктовка",
            pasteboard: pasteboard,
            prepare: { prepareRecorder.call($0, $1) },
            writeText: { _, _ in false },
            postPaste: {
                postPasteCalled = true
                return true
            },
            pause: {
                pauseCalled = true
            }
        )

        XCTAssertFalse(didPostPaste)
        XCTAssertFalse(postPasteCalled)
        XCTAssertFalse(pauseCalled)
        XCTAssertEqual(prepareRecorder.options, [.currentHostOnly, []])
        XCTAssertEqual(pasteboard.string(forType: .string), "важное старое")
    }

    func testManualFallbackIsLocalAndDoesNotRestore() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = pasteboard.prepareForNewContents(with: [])
        XCTAssertTrue(pasteboard.writeObjects(["старое" as NSString]))
        let prepareRecorder = PrepareRecorder()

        let written = TextInjector.placeLocally(
            "ручная диктовка",
            pasteboard: pasteboard,
            prepare: { prepareRecorder.call($0, $1) },
            writeText: liveWriteText
        )

        XCTAssertTrue(written)
        XCTAssertEqual(prepareRecorder.options, [.currentHostOnly])
        XCTAssertEqual(pasteboard.string(forType: .string), "ручная диктовка")
    }

    func testHistoryCopyUsesOrdinaryPasteboardSemantics() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let prepareRecorder = PrepareRecorder()

        let written = TextInjector.place(
            "осознанная копия",
            pasteboard: pasteboard,
            prepare: { prepareRecorder.call($0, $1) },
            writeText: liveWriteText
        )

        XCTAssertTrue(written)
        XCTAssertEqual(prepareRecorder.options, [NSPasteboard.ContentsOptions()])
        XCTAssertEqual(pasteboard.string(forType: .string), "осознанная копия")
    }

    private var liveWriteText: TextInjector.PasteboardWriteText {
        { pasteboard, text in
            pasteboard.writeObjects([text as NSString])
        }
    }

    @MainActor
    private final class PrepareRecorder {
        private(set) var options: [NSPasteboard.ContentsOptions] = []

        func call(
            _ pasteboard: NSPasteboard,
            _ option: NSPasteboard.ContentsOptions
        ) -> Int {
            options.append(option)
            return pasteboard.prepareForNewContents(with: option)
        }
    }

    private func seedMultipleItems(
        on pasteboard: NSPasteboard
    ) throws -> [[String: Data]] {
        let first = NSPasteboardItem()
        XCTAssertTrue(first.setString("plain text", forType: .string))
        XCTAssertTrue(
            first.setData(
                Data([0x00, 0x01, 0xFE, 0xFF]),
                forType: .init("io.github.spacevibes365.murmurly-test.binary")
            )
        )
        let second = NSPasteboardItem()
        XCTAssertTrue(
            second.setData(
                try JSONSerialization.data(withJSONObject: ["answer": 42]),
                forType: .init("io.github.spacevibes365.murmurly-test.json")
            )
        )
        XCTAssertTrue(second.setString("second item", forType: .init("public.utf8-plain-text")))

        _ = pasteboard.prepareForNewContents(with: [])
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        return materializedItems(from: pasteboard)
    }

    private func materializedItems(from pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
    }
}
