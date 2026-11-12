import SwiftUI

/// The notepad's root view: the header, the feed and the note input, laid
/// out around slots, each filled in by a view that lives in its own file
/// (`NotepadStatusView`/`NotepadWindowControls` in `NotepadWindow.swift`,
/// `CopyLiveTextButton` in `LiveLinesView.swift`, `MarkMomentButton`/
/// `NotesInputView` in `NotesInputView.swift`, `NotepadSearchBar` in
/// `NotepadSearchBar.swift`): an empty slot's own padding, if any, is theirs
/// to add inside their own file, never here, so changing a slot's body
/// never needs a change here.
struct LiveTranscriptContentView: View {
    @ObservedObject var notepad: NotepadModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            // A separate background layer carries the drag gesture: the panel
            // has no title bar to drag by (`.titleVisibility(.hidden)`), and
            // `isMovableByWindowBackground` does not reliably see through a
            // SwiftUI hosting view, so dragging needs its own gesture here —
            // never on the foreground content, or it would swallow the ✕
            // button's own click (`WindowDragGesture` is a macOS 15 API).
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .gesture(WindowDragGesture())

            // Three siblings, `spacing: 6`, as before the search bar and the
            // note input existed: each sibling is itself a zero-spacing
            // group, so an empty slot (`EmptyView`) inside a group costs
            // nothing and the outer rhythm never moves while a slot is empty.
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        NotepadStatusView(notepad: notepad)
                        Spacer()
                        CopyLiveTextButton(notepad: notepad)
                        MarkMomentButton(notepad: notepad)
                        NotepadWindowControls(notepad: notepad, onClose: onClose)
                    }
                    NotepadSearchBar(notepad: notepad)
                }
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    LiveLinesView(notepad: notepad)
                    NotesInputView(notepad: notepad)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .padding(12)
        }
        .frame(minWidth: LiveTranscriptPanel.minimumSize.width, maxWidth: .infinity, maxHeight: .infinity)
    }
}
