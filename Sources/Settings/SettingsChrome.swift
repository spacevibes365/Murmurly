import SwiftUI

enum SettingsChrome {
    static let windowWidth: CGFloat = 880
    static let windowHeight: CGFloat = 660
    static let sidebarWidth: CGFloat = 214
    static let headerHeight: CGFloat = 46
    static let sidebarHorizontalPadding: CGFloat = 12
    static let sidebarTopInset: CGFloat = 46
    static let sidebarSearchBottomPadding: CGFloat = 10
    static let sidebarItemHorizontalPadding: CGFloat = 8
    static let sidebarItemVerticalPadding: CGFloat = 6
    static let sidebarItemCornerRadius: CGFloat = 6
    static let sidebarItemSpacing: CGFloat = 1
    static let chipSize: CGFloat = 20
    static let chipCornerRadius: CGFloat = 5
    static let stepBadgeSize: CGFloat = 16
    static let chipSymbolSize: CGFloat = 12
    static let statusDotSize: CGFloat = 8
    static let permissionAttentionSize: CGFloat = 7
    static let contentTopPadding: CGFloat = 20
    static let headerHorizontalPadding: CGFloat = 20
    static let contentHorizontalPadding: CGFloat = 22
    static let contentBottomPadding: CGFloat = 26
    static let groupSpacing: CGFloat = 18
    static let groupTitleLeadingPadding: CGFloat = 2
    static let groupTitleBottomPadding: CGFloat = 6
    static let cardCornerRadius: CGFloat = 7
    static let cardBorderWidth: CGFloat = 0.5
    static let rowHorizontalPadding: CGFloat = 13
    static let rowVerticalPadding: CGFloat = 11
    static let rowContentSpacing: CGFloat = 4
    static let dividerLeadingPadding: CGFloat = 13
    static let disabledOpacity: Double = 0.42
    static let controlMinWidth: CGFloat = 120
    static let popupMinWidth: CGFloat = 190
    static let hotkeyModifierPopupMinWidth: CGFloat = 132
    static let permissionSymbolSize: CGFloat = 17
    static let badgeHorizontalPadding: CGFloat = 6
    static let badgeVerticalPadding: CGFloat = 3
    static let badgeCornerRadius: CGFloat = 4
    static let nestedControlIndent: CGFloat = 26
    static let footerHorizontalPadding: CGFloat = 14
    static let footerVerticalPadding: CGFloat = 12
    static let compactSpacing: CGFloat = 8
    static let tableHeaderVerticalPadding: CGFloat = 7
    static let meetingLastSeenWidth: CGFloat = 150
    static let meetingToggleWidth: CGFloat = 88
    static let historyToolbarVerticalPadding: CGFloat = 12
    static let historyHorizontalPadding: CGFloat = 12
    static let historyBottomPadding: CGFloat = 18
    static let historyDayTopPadding: CGFloat = 12
    static let historyDayHorizontalPadding: CGFloat = 10
    static let historyDayBottomPadding: CGFloat = 6
    static let historyRowHorizontalPadding: CGFloat = 10
    static let historyRowVerticalPadding: CGFloat = 8
    static let historyRowSpacing: CGFloat = 11
    static let historyTimeWidth: CGFloat = 52
    static let historyLanguageWidth: CGFloat = 28
    static let historyLanguageFontSize: CGFloat = 9
    static let historyActionSize: CGFloat = 24
    static let storageSummarySpacing: CGFloat = 13
    static let storageTotalFontSize: CGFloat = 26
    static let storageBarHeight: CGFloat = 8
    static let storageLegendMarkerSize: CGFloat = 8
    static let storageLegendCornerRadius: CGFloat = 2
    static let storageBarSegmentSpacing: CGFloat = 2
}

/// Titles are `LocalizedStringKey`, so a literal at the call site is looked
/// up in the string catalog; a plain `String` would be shown as is.
struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey?
    /// A Getting Started step: its number stands before the title.
    let step: Int?
    /// A check after the title, only where the app can tell for sure.
    let done: Bool
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringKey? = nil,
        step: Int? = nil,
        done: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.step = step
        self.done = done
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                header(title)
                    .padding(.leading, SettingsChrome.groupTitleLeadingPadding)
                    .padding(.bottom, SettingsChrome.groupTitleBottomPadding)
            }
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cardCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsChrome.cardCornerRadius)
                        .stroke(
                            Color(nsColor: .separatorColor),
                            lineWidth: SettingsChrome.cardBorderWidth
                        )
                }
        }
    }

    @ViewBuilder private func header(_ title: LocalizedStringKey) -> some View {
        let text = Text(title)
            .textCase(.uppercase)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        if let step {
            HStack(spacing: SettingsChrome.compactSpacing) {
                Text(step, format: .number)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: SettingsChrome.stepBadgeSize, height: SettingsChrome.stepBadgeSize)
                    .background(Circle().fill(Color.accentColor))
                    .accessibilityLabel(Text("Step \(step)", comment: "Spoken before a Getting Started step's title"))
                text
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Done", comment: "Spoken after a Getting Started step that is done"))
                }
            }
            // Read as one line: "Step 1, Recognition model, Done".
            .accessibilityElement(children: .combine)
        } else {
            text
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @ViewBuilder let control: Control

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top) {
            VStack(alignment: .leading, spacing: SettingsChrome.rowContentSpacing) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            control
        }
        .padding(.horizontal, SettingsChrome.rowHorizontalPadding)
        .padding(.vertical, SettingsChrome.rowVerticalPadding)
    }
}

struct SettingsStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: SettingsChrome.statusDotSize, height: SettingsChrome.statusDotSize)
    }
}
