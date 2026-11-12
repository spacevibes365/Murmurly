import XCTest
@testable import Murmurly

/// `MeetingNote` and `murmurly.json`'s `notes` key: reading, a crooked
/// element or a crooked key, and writing by `id` in place. Every text here
/// is made up, no owner data.
final class MeetingNotesTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String = "2026-10-15 10-00-00 Meeting") throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ json: String, to folder: URL) throws {
        try Data(json.utf8).write(to: folder.appendingPathComponent(MeetingMarks.fileName))
    }

    // MARK: - Reading

    func testNotesAreReadFromTheMarks() throws {
        let folder = try folder()
        let momentID = UUID()
        let noteID = UUID()
        try write(
            """
            {"version":1,"starred":true,"notes":[
                {"id":"\(momentID.uuidString)","t":12.5,"kind":"moment","text":"Проверить меню"},
                {"id":"\(noteID.uuidString)","kind":"note","text":"Обсудить сроки"}
            ]}
            """,
            to: folder
        )

        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("file did not read") }
        XCTAssertTrue(marks.starred)
        XCTAssertEqual(marks.notes.count, 2)
        XCTAssertEqual(marks.notes[0], MeetingNote(id: momentID, t: 12.5, kind: .moment, text: "Проверить меню"))
        XCTAssertEqual(marks.notes[1], MeetingNote(id: noteID, t: nil, kind: .note, text: "Обсудить сроки"))
    }

    func testACrookedNoteIsSkippedAndTheRestIsRead() throws {
        let folder = try folder()
        let goodID = UUID()
        let dupedID = UUID()
        let farID = UUID()
        try write(
            """
            {"version":1,"starred":true,"speakers":{"microphone":"Денис"},"notes":[
                7,
                {"kind":"note","text":"нет id"},
                {"id":"\(UUID().uuidString)","kind":"sketch","text":"неизвестный вид"},
                {"id":"\(UUID().uuidString)","kind":"note","text":5},
                {"id":"\(UUID().uuidString)","kind":"note","text":"t строкой","t":"x"},
                {"id":"\(UUID().uuidString)","kind":"note","text":"t булево","t":true},
                {"id":"\(UUID().uuidString)","kind":"note","text":"t отрицательное","t":-1},
                {"id":"\(farID.uuidString)","kind":"note","text":"t past any recording","t":1e20},
                {"id":"\(dupedID.uuidString)","kind":"note","text":"первый из дубля"},
                {"id":"\(dupedID.uuidString)","kind":"note","text":"второй из дубля"},
                {"id":"\(goodID.uuidString)","kind":"moment","text":"Созвон по релизу","t":3}
            ]}
            """,
            to: folder
        )

        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("file did not read") }
        XCTAssertTrue(marks.starred)
        XCTAssertEqual(marks.speakers, [.microphone: "Денис"])
        XCTAssertEqual(marks.notes, [
            MeetingNote(id: farID, t: nil, kind: .note, text: "t past any recording"),
            MeetingNote(id: dupedID, t: nil, kind: .note, text: "первый из дубля"),
            MeetingNote(id: goodID, t: 3, kind: .moment, text: "Созвон по релизу"),
        ])
    }

    func testNotesThatAreNotAnArrayDoNotHideTheStarOrNames() throws {
        let folder = try folder()
        try write(
            """
            {"version":1,"starred":true,"speakers":{"microphone":"Денис"},"notes":{"a":1}}
            """,
            to: folder
        )

        guard case .read(let marks) = MeetingMarks.read(in: folder) else { return XCTFail("file did not read") }
        XCTAssertTrue(marks.starred)
        XCTAssertEqual(marks.speakers, [.microphone: "Денис"])
        XCTAssertEqual(marks.notes, [])

        let identity = FolderIdentity.of(folder)
        try MeetingMarks.write(MeetingMarks.Change(starred: false), in: folder, expecting: identity)
        let afterStarWrite = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(MeetingMarks.fileName))) as? [String: Any]
        )
        XCTAssertEqual(afterStarWrite["notes"] as? [String: Int], ["a": 1], "the crooked key survives a star write")

        let note = MeetingNote(id: UUID(), t: nil, kind: .note, text: "Новая заметка")
        XCTAssertThrowsError(try MeetingMarks.write(MeetingMarks.Change(notes: [.add(note)]), in: folder, expecting: identity))
        let unchanged = try Data(contentsOf: folder.appendingPathComponent(MeetingMarks.fileName))
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: unchanged) as? [String: Any])["notes"] as? [String: Int],
            ["a": 1],
            "a refused note write leaves the file byte for byte"
        )
    }

    // MARK: - Writing

    func testAddEditAndDeleteChangeTheArrayInPlaceById() throws {
        let folder = try folder()
        let crookedID = UUID()
        let keptID = UUID()
        try write(
            """
            {"version":1,"future":{"x":1},"notes":[
                {"id":"\(crookedID.uuidString)","kind":"unknown","text":"из будущей версии"},
                {"id":"\(keptID.uuidString)","kind":"note","text":"старая","color":"red"}
            ]}
            """,
            to: folder
        )
        let identity = FolderIdentity.of(folder)
        let addedID = UUID()

        try MeetingMarks.write(
            MeetingMarks.Change(notes: [.add(MeetingNote(id: addedID, t: 5, kind: .moment, text: "Новая отметка"))]),
            in: folder, expecting: identity
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(MeetingMarks.fileName))) as? [String: Any]
        )
        var items = try XCTUnwrap(object["notes"] as? [[String: Any]])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(object["future"] as? [String: Int], ["x": 1])

        // A repeated add of the same id does not duplicate it.
        try MeetingMarks.write(
            MeetingMarks.Change(notes: [.add(MeetingNote(id: addedID, t: 5, kind: .moment, text: "Новая отметка"))]),
            in: folder, expecting: identity
        )
        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(MeetingMarks.fileName))) as? [String: Any]
        )
        items = try XCTUnwrap(object["notes"] as? [[String: Any]])
        XCTAssertEqual(items.count, 3, "a repeated add must not duplicate the note")

        try MeetingMarks.write(MeetingMarks.Change(notes: [.edit(id: keptID, text: "новая")]), in: folder, expecting: identity)
        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(MeetingMarks.fileName))) as? [String: Any]
        )
        items = try XCTUnwrap(object["notes"] as? [[String: Any]])
        let edited = try XCTUnwrap(items.first { $0["id"] as? String == keptID.uuidString.lowercased() || $0["id"] as? String == keptID.uuidString })
        XCTAssertEqual(edited["text"] as? String, "новая")
        XCTAssertEqual(edited["color"] as? String, "red", "a foreign field of the note stays")

        try MeetingMarks.write(MeetingMarks.Change(notes: [.delete(id: addedID)]), in: folder, expecting: identity)
        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(MeetingMarks.fileName))) as? [String: Any]
        )
        items = try XCTUnwrap(object["notes"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2, "the deleted note is gone")
        XCTAssertFalse(items.contains { $0["id"] as? String == addedID.uuidString }, "the deleted id is gone")
        XCTAssertTrue(items.contains { $0["id"] as? String == crookedID.uuidString }, "the unknown-kind element survives")
        XCTAssertEqual(object["future"] as? [String: Int], ["x": 1])
    }

    func testDeletingTheLastNoteRemovesTheKey() throws {
        let folder = try folder()
        let id = UUID()
        try write(#"{"version":1,"notes":[{"id":"\#(id.uuidString)","kind":"note","text":"единственная"}]}"#, to: folder)
        let identity = FolderIdentity.of(folder)

        try MeetingMarks.write(MeetingMarks.Change(notes: [.delete(id: id)]), in: folder, expecting: identity)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(MeetingMarks.fileName))) as? [String: Any]
        )
        XCTAssertNil(object["notes"], "an empty notes array is removed like an empty speakers dictionary")
    }

    func testAFileWithoutNotesIsWrittenAsBefore() throws {
        let folder = try folder()
        let identity = FolderIdentity.of(folder)

        let written = try MeetingMarks.write(MeetingMarks.Change(starred: true), in: folder, expecting: identity)
        XCTAssertEqual(written, MeetingMarks(starred: true))

        let data = try Data(contentsOf: folder.appendingPathComponent(MeetingMarks.fileName))
        let expected = try JSONSerialization.data(
            withJSONObject: ["version": 1, "starred": true], options: [.prettyPrinted, .sortedKeys]
        )
        XCTAssertEqual(data, expected)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["notes"])
    }

    // MARK: - `Change`

    func testChangeAppliesNoteOperationsInOrder() {
        let keptID = UUID()
        let addedID = UUID()
        let deletedID = UUID()
        var marks = MeetingMarks(notes: [MeetingNote(id: keptID, t: nil, kind: .note, text: "старая")])

        var change = MeetingMarks.Change()
        change.add(MeetingMarks.Change(notes: [.add(MeetingNote(id: addedID, t: 1, kind: .moment, text: "первая"))]))
        change.add(MeetingMarks.Change(notes: [.edit(id: keptID, text: "правленая")]))
        change.add(MeetingMarks.Change(notes: [.delete(id: deletedID)]))

        let once = change.applied(to: marks)
        XCTAssertEqual(once.notes, [
            MeetingNote(id: keptID, t: nil, kind: .note, text: "правленая"),
            MeetingNote(id: addedID, t: 1, kind: .moment, text: "первая"),
        ])

        // The same `Change` applied again (as `finishMarks` does when a
        // write did not take every edit) gives the same result.
        marks = once
        let twice = change.applied(to: marks)
        XCTAssertEqual(twice.notes, once.notes)
    }

    func testARepeatedAddReplacesTheNoteInPlaceKeepingForeignFields() throws {
        let folder = try folder()
        let changedID = UUID()
        let otherID = UUID()
        try write(
            """
            {"version":1,"notes":[
                {"id":"\(changedID.uuidString)","kind":"note","text":"старый текст","t":3,"color":"red"},
                {"id":"\(otherID.uuidString)","kind":"note","text":"вторая"}
            ]}
            """,
            to: folder
        )
        let identity = FolderIdentity.of(folder)

        try MeetingMarks.write(
            MeetingMarks.Change(notes: [.add(MeetingNote(id: changedID, t: 7, kind: .moment, text: "новый текст"))]),
            in: folder, expecting: identity
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(MeetingMarks.fileName))) as? [String: Any]
        )
        let items = try XCTUnwrap(object["notes"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2, "no duplicate is appended")
        XCTAssertEqual(items.map { $0["id"] as? String }, [changedID.uuidString, otherID.uuidString], "the order is unchanged")
        let changed = try XCTUnwrap(items.first { $0["id"] as? String == changedID.uuidString })
        XCTAssertEqual(changed["text"] as? String, "новый текст")
        XCTAssertEqual(changed["t"] as? Double, 7)
        XCTAssertEqual(changed["kind"] as? String, "moment")
        XCTAssertEqual(changed["color"] as? String, "red", "a foreign field of the note stays")
    }

    func testChangeAppliesARepeatedAddAsAReplacement() {
        let id = UUID()
        let marks = MeetingMarks(notes: [MeetingNote(id: id, t: nil, kind: .note, text: "старый текст")])
        let change = MeetingMarks.Change(notes: [.add(MeetingNote(id: id, t: 2, kind: .note, text: "новый текст"))])

        let once = change.applied(to: marks)
        XCTAssertEqual(once.notes, [MeetingNote(id: id, t: 2, kind: .note, text: "новый текст")])

        let twice = change.applied(to: once)
        XCTAssertEqual(twice.notes, once.notes)
    }
}
