import SwiftUI
import AppIntents
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = image
        } else if let image = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = image
        }
    }
}

@main
struct ArchaeologistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            HistoryCommands()
            TextEditingCommands()
        }
    }
}

struct HistoryCommands: Commands {
    @FocusedObject var viewModel: HistoryViewModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open...") {
                TabManager.shared.showOpenFileDialog()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("New Tab") {
                TabManager.shared.openNewEmptyTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Close Tab") {
                if let id = TabManager.shared.activeTabId {
                    TabManager.shared.closeTab(id: id)
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("Refresh") {
                viewModel?.refresh()
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        CommandMenu("View") {
            Button(TabManager.shared.showSidebar ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    TabManager.shared.showSidebar.toggle()
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Divider()

            Button("Refresh Repository Files") {
                TabManager.shared.refreshRepositoryFiles()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu("Navigate") {
            Button("Back") {
                TabManager.shared.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!TabManager.shared.canGoBack)

            Button("Forward") {
                TabManager.shared.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!TabManager.shared.canGoForward)

            Divider()

            Button("Previous Revision") {
                viewModel?.previousCommit()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .disabled(viewModel?.commits.isEmpty ?? true || (viewModel?.selectedCommitIndex ?? 0) <= 0)

            Button("Next Revision") {
                viewModel?.nextCommit()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .disabled(viewModel?.commits.isEmpty ?? true || (viewModel?.selectedCommitIndex ?? 0) >= ((viewModel?.commits.count ?? 1) - 1))

            Divider()

            Button("First Revision") {
                viewModel?.firstCommit()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(viewModel?.commits.isEmpty ?? true || (viewModel?.selectedCommitIndex ?? 0) <= 0)

            Button("Latest Revision") {
                viewModel?.lastCommit()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(viewModel?.commits.isEmpty ?? true || (viewModel?.selectedCommitIndex ?? 0) >= ((viewModel?.commits.count ?? 1) - 1))

            Divider()

            Button("Swap to \(viewModel?.vcsType == .git ? "Mercurial" : "Git")") {
                viewModel?.swapVCS()
            }
            .disabled(viewModel?.canSwapVCS != true)
        }
    }
}
