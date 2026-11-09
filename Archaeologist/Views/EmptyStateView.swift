import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct EmptyStateView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @State private var isTargetedForDrop: Bool = false
    @State private var sampleError: String?

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 24) {
            // App Icon / Logo
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 88, height: 88)

                Image(systemName: "timeline.selection")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(.accentColor)
            }

            VStack(spacing: 8) {
                Text("Commit Timeline & Revision Viewer")
                    .font(.system(size: 20, weight: .bold))

                Text("Inspect file history, scrub across Git and Mercurial revisions, view blame annotations, and inspect text or image changes.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            // Actions Box
            VStack(spacing: 12) {
                Button(action: { viewModel.showOpenFileDialog() }) {
                    Label("Choose Repository or File...", systemImage: "folder.badge.plus")
                        .frame(minWidth: 220)
                        .frame(height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("or drag and drop any file or repository folder here")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)

            Divider()
                .frame(maxWidth: 360)

            // Sample Repositories for quick test
            VStack(spacing: 8) {
                Text("Quick Demo Repositories:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button(action: { loadSampleGit() }) {
                        Label("Load Git Sample", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)

                    Button(action: { loadSampleHg() }) {
                        Label("Load Mercurial Sample", systemImage: "cube.transparent")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                }

                if let err = sampleError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(.top, 4)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargetedForDrop ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(16)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in
                        viewModel.openItem(at: url)
                    }
                }
            }
            return true
        }
    }

    private func loadSampleGit() {
        do {
            let (_, sampleFiles) = try SampleRepoService.shared.setupSampleGitRepo()
            if let first = sampleFiles.first {
                viewModel.openFile(url: first, preferredVCS: .git)
            }
        } catch {
            sampleError = "Failed to create sample Git repo: \(error.localizedDescription)"
        }
    }

    private func loadSampleHg() {
        do {
            let (_, sampleFiles) = try SampleRepoService.shared.setupSampleHgRepo()
            if let first = sampleFiles.first {
                viewModel.openFile(url: first, preferredVCS: .hg)
            }
        } catch {
            sampleError = "Failed to create sample Mercurial repo: \(error.localizedDescription)"
        }
    }
}
