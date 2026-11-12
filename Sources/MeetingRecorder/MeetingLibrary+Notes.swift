import Foundation

/// Adding, editing and deleting a meeting's notepad notes, through
/// `MeetingLibrary.changeNotes`: the same writer as the star and the names,
/// entered by the meeting's `identity` and address rather than a row the
/// window read, since the window may never have been open.
extension MeetingLibrary {
    @discardableResult
    func addNote(_ note: MeetingNote, identity: FolderIdentity?, folder: URL) -> String? {
        changeNotes(MeetingMarks.Change(notes: [.add(note)]), identity: identity, folder: folder)
    }

    @discardableResult
    func editNote(id: UUID, text: String, identity: FolderIdentity?, folder: URL) -> String? {
        changeNotes(MeetingMarks.Change(notes: [.edit(id: id, text: text)]), identity: identity, folder: folder)
    }

    @discardableResult
    func deleteNote(id: UUID, identity: FolderIdentity?, folder: URL) -> String? {
        changeNotes(MeetingMarks.Change(notes: [.delete(id: id)]), identity: identity, folder: folder)
    }
}
