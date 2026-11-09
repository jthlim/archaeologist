import SwiftUI

public struct TabBarView: View {
    @ObservedObject var tabManager: TabManager

    public init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Scrollable tabs strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(tabManager.tabs) { tab in
                        TabBarItemView(
                            tab: tab,
                            isSelected: tab.id == tabManager.activeTabId,
                            onSelect: { tabManager.selectTab(id: tab.id) },
                            onClose: { tabManager.closeTab(id: tab.id) }
                        )
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 8)
        }
        .frame(height: 34)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

}

struct TabBarItemView: View {
    @ObservedObject var tab: TabItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if tab.isCommitPrompt {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.accentColor)
            } else if tab.isCommitHistory {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.accentColor)
            } else if let vcs = tab.vcsType {
                Image(systemName: vcs.iconName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(vcs == .git ? .orange : .blue)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Text(tab.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(isSelected ? .primary : .secondary)

            // Close button (x)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close tab (Cmd+W)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            isSelected
                ? Color(NSColor.controlBackgroundColor)
                : Color.clear
        )
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color(NSColor.separatorColor) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
