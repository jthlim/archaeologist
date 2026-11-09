import SwiftUI

public struct TimelineBarView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @State private var hoveredCommit: CommitInfo?
    @State private var dragStartState: NavigationState?
    @State private var isDraggingSlider: Bool = false

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    /// Calculate vertical delta line length based on a log2 scale:
    /// - 0 lines -> 0 pt (no line)
    /// - 1 line -> 1 pt
    /// - Up to 256 lines -> 8 pt (log2(256) = 8)
    /// - Capped at 20 pt
    public static func deltaLineLength(for count: Int) -> CGFloat {
        ArchaeologistViewModel.deltaLineLength(for: count)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: controls & info
            headerControls

            // The Timeline Bar & Scrubber (clean dots only, no overlapping text)
            timelineTrack
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Header Controls
    private var headerControls: some View {
        HStack(spacing: 12) {
            // Commit Stepper Controls (Start, Back, Forward, End)
            HStack(spacing: 6) {
                Button(action: { viewModel.firstCommit() }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedCommitIndex <= 0)
                .help("First commit (Cmd+Option+Left Arrow)")

                Button(action: { viewModel.previousCommit() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedCommitIndex <= 0)
                .help("Previous commit (Cmd+Left Arrow)")

                Button(action: { viewModel.nextCommit() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedCommitIndex >= viewModel.commits.count - 1)
                .help("Next commit (Cmd+Right Arrow)")

                Button(action: { viewModel.lastCommit() }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedCommitIndex >= viewModel.commits.count - 1)
                .help("Latest commit (Cmd+Option+Right Arrow)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            // Commit counter & Preload Status
            if !viewModel.commits.isEmpty {
                HStack(spacing: 8) {
                    if let commit = viewModel.selectedCommit, commit.isUncommitted {
                        Text("Uncommitted changes (\(viewModel.selectedCommitIndex + 1) of \(viewModel.commits.count))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    } else {
                        Text("Commit \(viewModel.selectedCommitIndex + 1) of \(viewModel.commits.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if viewModel.isPreloading {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 12, height: 12)
                            Text("Caching \(viewModel.preloadedCount)/\(viewModel.commits.count)...")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .help("Preloading all revisions in background for instant scrubbing")
                    } else if viewModel.commits.count > 1 && viewModel.preloadedCount >= viewModel.commits.count {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.yellow)
                            Text("Cached")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .help("All \(viewModel.commits.count) revisions cached. Scrubbing is instantaneous.")
                    }
                }
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Active commit revision tag & date
            if let commit = viewModel.selectedCommit {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text(commit.displayRevision)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                        if !commit.isUncommitted {
                            Button(action: { viewModel.copyCommitHash() }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .help("Copy full revision")
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(commit.isUncommitted ? Color.orange.opacity(0.18) : Color.accentColor.opacity(0.12))
                    .foregroundColor(commit.isUncommitted ? .orange : .accentColor)
                    .cornerRadius(4)
                    .fixedSize()

                    // Delta counts in header
                    let delta = viewModel.deltaCounts(for: commit)
                    if delta.added > 0 || delta.removed > 0 {
                        HStack(spacing: 4) {
                            if delta.added > 0 {
                                Text("+\(delta.added)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Color(NSColor.systemGreen))
                            }
                            if delta.removed > 0 {
                                Text("-\(delta.removed)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Color(NSColor.systemRed))
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .fixedSize()
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(commit.dateFormatted)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .fixedSize()
                }
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Timeline Track & Scrubber (Dots only, no text labels)
    private var timelineTrack: some View {
        GeometryReader { geo in
            let totalCommits = viewModel.commits.count
            let width = geo.size.width
            let step = totalCommits > 1 ? width / CGFloat(totalCommits - 1) : width
            let centerY: CGFloat = geo.size.height / 2
            let lineWidth: CGFloat = totalCommits > 150 ? 1.5 : 2.0

            ZStack(alignment: .leading) {
                // Background track line
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(NSColor.separatorColor).opacity(0.5))
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
                    .position(x: width / 2, y: centerY)

                // Elapsed progress bar
                if totalCommits > 1 {
                    let progressWidth = CGFloat(viewModel.selectedCommitIndex) * step
                    let isUncommittedSelected = viewModel.selectedCommit?.isUncommitted == true
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isUncommittedSelected ? Color.orange.opacity(0.8) : Color.accentColor.opacity(0.8))
                        .frame(width: max(0, progressWidth), height: 4)
                        .position(x: progressWidth / 2, y: centerY)
                }

                // Commit Dots & Delta Lines along the timeline
                ForEach(0..<totalCommits, id: \.self) { idx in
                    let commit = viewModel.commits[idx]
                    let xPos = totalCommits > 1 ? CGFloat(idx) * step : width / 2
                    let isSelected = idx == viewModel.selectedCommitIndex
                    let isUncommitted = commit.isUncommitted
                    let dotSize: CGFloat = isSelected ? 14 : (totalCommits > 100 ? 5 : (isUncommitted ? 8 : 7))
                    let dotRadius = dotSize / 2
                    let delta = viewModel.deltaCounts(for: commit)
                    let addedLen = Self.deltaLineLength(for: delta.added)
                    let removedLen = Self.deltaLineLength(for: delta.removed)

                    ZStack {
                        // Green line above node for additions
                        if addedLen > 0 {
                            RoundedRectangle(cornerRadius: min(1, addedLen / 2))
                                .fill(Color(NSColor.systemGreen))
                                .frame(width: lineWidth, height: addedLen)
                                .offset(y: -dotRadius - 2 - (addedLen / 2))
                        }

                        // Red line below node for removals
                        if removedLen > 0 {
                            RoundedRectangle(cornerRadius: min(1, removedLen / 2))
                                .fill(Color(NSColor.systemRed))
                                .frame(width: lineWidth, height: removedLen)
                                .offset(y: dotRadius + 2 + (removedLen / 2))
                        }

                        // Central node circle
                        if isUncommitted {
                            Circle()
                                .fill(isSelected ? Color.orange : Color(NSColor.controlBackgroundColor))
                                .frame(width: dotSize, height: dotSize)
                                .shadow(color: isSelected ? Color.orange.opacity(0.6) : Color.clear, radius: 4)

                            Circle()
                                .stroke(
                                    isSelected ? Color.white : Color.orange,
                                    style: StrokeStyle(lineWidth: isSelected ? 2 : 1.5, dash: isSelected ? [] : [3, 2])
                                )
                                .frame(width: dotSize, height: dotSize)
                        } else {
                            Circle()
                                .fill(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                                .frame(width: dotSize, height: dotSize)
                                .shadow(color: isSelected ? Color.accentColor.opacity(0.5) : Color.clear, radius: 4)

                            Circle()
                                .stroke(isSelected ? Color.white : Color(NSColor.separatorColor), lineWidth: isSelected ? 2 : 1)
                                .frame(width: dotSize, height: dotSize)
                        }
                    }
                    .position(x: xPos, y: centerY)
                    .contentShape(Rectangle().inset(by: -8))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            viewModel.goToCommit(at: idx)
                        }
                    }
                    .onHover { hovering in
                        if hovering {
                            hoveredCommit = commit
                        } else if hoveredCommit?.id == commit.id {
                            hoveredCommit = nil
                        }
                    }
                    .help({
                        let deltaStr = "+\(delta.added), -\(delta.removed)"
                        if isUncommitted {
                            return "Uncommitted changes (\(deltaStr))\nWorking Directory • \(commit.dateFormatted)"
                        } else {
                            return "\(commit.displayRevision) (\(deltaStr))\n\(commit.author) • \(commit.dateFormatted)\n\(commit.summary)"
                        }
                    }())
                }

                // Drag scrubbing gesture overlay
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard totalCommits > 0 else { return }
                                if !isDraggingSlider {
                                    isDraggingSlider = true
                                    dragStartState = viewModel.currentNavigationState
                                    viewModel.shouldRecordHistory = false
                                }
                                let clampedX = max(0, min(width, value.location.x))
                                let rawIndex = Int(round((clampedX / width) * CGFloat(totalCommits - 1)))
                                let newIndex = max(0, min(totalCommits - 1, rawIndex))
                                if newIndex != viewModel.selectedCommitIndex {
                                    viewModel.selectedCommitIndex = newIndex
                                }
                            }
                            .onEnded { _ in
                                if isDraggingSlider {
                                    isDraggingSlider = false
                                    viewModel.shouldRecordHistory = true
                                    if let start = dragStartState,
                                       let current = viewModel.currentNavigationState,
                                       start != current {
                                        viewModel.tabManager?.pushNavigationState(from: start)
                                    }
                                    dragStartState = nil
                                }
                            }
                    )
            }
        }
        .frame(height: 60)
    }
}
