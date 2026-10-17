import AppKit
import SwiftUI

/// What the main window's sidebar offers, each a layer of its own; Starred
/// filters the meetings' list.
enum MainSection: String, Hashable, CaseIterable {
    case meetings
    /// The starred meetings: the same list, filtered.
    case starred
    case dictations
    case dictionary
    case files
}

/// The Murmurly window: the sidebar, and the chosen section beside it. Every
/// section is built with the window and only hidden, as Settings' tabs are,
/// so each keeps its state, and a sheet up over one survives a change of
/// section.
/// A plain stack, not `NavigationSplitView`: AppKit keeps a split view's
/// widths and folding in the app's own preferences, the owner's on their Mac
/// even for a test copy, and no hook on it was sure to come before the first
/// write. The sidebar folds by its own button and keeps its width.
struct MainWindow: View {
    static let sidebarWidth: CGFloat = 200
    /// The sidebar, its divider and the meetings at their least. Folding the
    /// sidebar leaves it so, and no section's layer is wider.
    static var minWidth: CGFloat { sidebarWidth + 1 + MeetingsView.minWidth }
    /// The dictionary's controls read at about Settings' width, from the left.
    static let dictionaryWidth: CGFloat = 720

    @EnvironmentObject private var library: MeetingLibrary
    @EnvironmentObject private var dictation: DictationCoordinator
    @Environment(\.openWindow) private var openWindow
    /// In memory only: a window opened anew shows its sidebar.
    @State private var sidebarShown = true

    var body: some View {
        HStack(spacing: 0) {
            if sidebarShown {
                sidebar
                Divider()
            }
            // What ended while its meeting was out of sight, over every section.
            VStack(spacing: 0) {
                MeetingNotices()
                ZStack {
                    // One list for both: Starred filters it, the card and the
                    // selection stay.
                    layer([.meetings, .starred], "meetings") { MeetingsView(onlyStarred: library.section == .starred) }
                    layer([.dictations], "dictations") {
                        DictationHistoryView(
                            dictation: dictation,
                            isShown: library.section == .dictations,
                            openDictionary: { library.section = .dictionary }
                        )
                    }
                    layer([.dictionary], "dictionary") {
                        SettingsChrome.scrolling(trigger: library.section) {
                            DictionarySettingsView(section: library.section)
                                .frame(maxWidth: Self.dictionaryWidth)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    layer([.files], "files") { ContentView() }
                }
            }
        }
        .frame(minWidth: Self.minWidth, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarShown.toggle()
                } label: {
                    Label(sidebarShown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .help(sidebarShown ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityIdentifier("mainSidebarToggle")
            }
            ToolbarItem {
                Button {
                    library.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                // The meetings' own: elsewhere it reads nothing.
                .disabled(!library.isCardShown)
                .help("Read the meetings folders again")
                .accessibilityIdentifier("mainRefresh")
            }
        }
        .onAppear {
            AppWindowController.enterRegular()
            library.windowOpened()
        }
        .onDisappear {
            library.windowClosed()
            AppWindowController.windowDidClose()
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { library.section }, set: { if let section = $0 { library.section = section } })) {
            Label("Meetings", systemImage: "waveform.and.mic")
                .badge(library.meetings.count)
                .tag(MainSection.meetings)
                .accessibilityIdentifier("mainSection.meetings")
            Label("Starred", systemImage: "star")
                .badge(library.starredMeetings.count)
                .tag(MainSection.starred)
                .accessibilityIdentifier("mainSection.starred")
            Label("Dictations", systemImage: "clock.arrow.circlepath")
                .tag(MainSection.dictations)
                .accessibilityIdentifier("mainSection.dictations")
            Label("Dictionary", systemImage: "character.book.closed")
                .tag(MainSection.dictionary)
                .accessibilityIdentifier("mainSection.dictionary")
            Label("Files", systemImage: "waveform.badge.magnifyingglass")
                .tag(MainSection.files)
                .accessibilityIdentifier("mainSection.files")
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                AppWindowController.show("settings", with: openWindow)
            } label: {
                Label("Settings…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityIdentifier("mainSidebarSettings")
        }
        .frame(width: Self.sidebarWidth)
    }

    /// A section built with the window and only hidden: it keeps its state,
    /// and a sheet or a panel up over it stays through a change of section.
    private func layer<Content: View>(
        _ shown: Set<MainSection>, _ name: String, @ViewBuilder content: () -> Content
    ) -> some View {
        let selected = shown.contains(library.section)
        return content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mainContent.\(name)")
            .accessibilityHidden(!selected)
            .zIndex(selected ? 1 : 0)
    }
}
