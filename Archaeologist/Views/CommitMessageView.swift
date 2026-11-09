import SwiftUI
import AppKit

public struct CommitMessageView: View {
    @ObservedObject var viewModel: HistoryViewModel

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                if let commit = viewModel.selectedCommit, commit.isUncommitted {
                    Label("Working Directory Changes", systemImage: "pencil.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.orange)
                } else {
                    Label("Commit Details", systemImage: "text.bubble")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let commit = viewModel.selectedCommit {
                    HStack(spacing: 8) {
                        // Author with full name and email
                        HStack(spacing: 4) {
                            Image(systemName: commit.isUncommitted ? "folder.badge.gearshape" : "person.circle.fill")
                                .foregroundColor(commit.isUncommitted ? .orange : .secondary)
                            Text(commit.fullAuthor)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Text("•")
                            .foregroundColor(.secondary)

                        // Files in this commit dropdown at the end of the line
                        filesDropdownMenu
                            .fixedSize()
                    }
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            // Message Body
            if let commit = viewModel.selectedCommit {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Subject / Summary line
                        Text(commit.summary)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(commit.isUncommitted ? .orange : .primary)
                            .textSelection(.enabled)

                        // Body description (if more lines exist beyond summary)
                        let bodyText = commitBodyText(fullMessage: commit.fullMessage, summary: commit.summary)
                        if !bodyText.isEmpty {
                            Text(bodyText)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .lineSpacing(3)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack {
                    Text("Select a commit on the timeline to view its message")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Files Dropdown Menu (End of Commit Details Header Line)
    private var filesDropdownMenu: some View {
        Group {
            if viewModel.isLoadingFilesInCommit && viewModel.filesInCurrentCommit.isEmpty {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Files...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else {
                Menu {
                    ForEach(displayedFiles, id: \.self) { file in
                        Button(action: {
                            viewModel.selectFileInCurrentCommit(relativePath: file)
                        }) {
                            HStack {
                                if file == viewModel.relativePath {
                                    Image(systemName: "checkmark")
                                }
                                Text(file)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))

                        Text("Files (\(displayedFiles.count))")
                            .font(.system(size: 11, weight: .medium))

                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.separatorColor).opacity(0.18))
                    .foregroundColor(.primary)
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Files changed in this commit. Select one to view it at this commit.")
            }
        }
    }

    private var displayedFiles: [String] {
        if viewModel.filesInCurrentCommit.isEmpty {
            return viewModel.relativePath.isEmpty ? [] : [viewModel.relativePath]
        }
        return viewModel.filesInCurrentCommit
    }

    private func commitBodyText(fullMessage: String, summary: String) -> String {
        let trimmedFull = fullMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedFull == trimmedSummary {
            return ""
        }

        // If the full message begins with summary, strip it
        if trimmedFull.hasPrefix(trimmedSummary) {
            let remainder = trimmedFull.dropFirst(trimmedSummary.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder
        }

        return trimmedFull
    }
}
