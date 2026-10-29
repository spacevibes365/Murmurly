/// Settings' tabs: settings only. Dictations, the dictionary and files are
/// sections of the main window; a stored tab of theirs reads as the default.
enum SettingsTab: String, CaseIterable, Sendable {
    case gettingStarted
    case dictation
    case meetings
    case storage
    case agents
    case permissions
}
