import SwiftUI
import AppKit

public struct CommitHistoryTabView: View {
    @ObservedObject var viewModel: CommitHistoryViewModel

    @State private var topHistoryHeight: CGFloat = 280
    @State private var historyDragStartHeight: CGFloat? = nil

    public init(viewModel: CommitHistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            let totalHeight = max(240, geometry.size.height)
            let clampedTopHeight = max(120, min(totalHeight - 120, topHistoryHeight))

            VStack(spacing: 0) {
                // TOP: Commit History View
                CommitHistoryListView(viewModel: viewModel)
                    .frame(height: clampedTopHeight)
                    .frame(maxWidth: .infinity)

                // Draggable divider between Commit History View and Commit Information View
                verticalResizeHandle(totalHeight: totalHeight, currentHeight: clampedTopHeight)

                // BOTTOM: Commit Information View
                CommitInformationView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onAppear {
            viewModel.startWatching()
        }
        .onDisappear {
            viewModel.stopWatching()
        }
    }

    private func verticalResizeHandle(totalHeight: CGFloat, currentHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(height: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { gesture in
                                if historyDragStartHeight == nil {
                                    historyDragStartHeight = currentHeight
                                }
                                let newHeight = (historyDragStartHeight ?? currentHeight) + gesture.translation.height
                                topHistoryHeight = max(120, min(totalHeight - 120, newHeight))
                            }
                            .onEnded { _ in
                                historyDragStartHeight = nil
                            }
                    )
            )
            .onHover { isHovered in
                if isHovered {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .zIndex(10)
    }
}

// MARK: - Top: Commit History View
public struct CommitHistoryListView: View {
    @ObservedObject var viewModel: CommitHistoryViewModel

    public static let rowHeight: CGFloat = 22

    @State private var graphDragStartWidth: CGFloat? = nil
    @State private var descAuthorDragStartWidth: CGFloat? = nil
    @State private var authorDragStartWidth: CGFloat? = nil
    @State private var dateDragStartWidth: CGFloat? = nil
    @State private var revisionDragStartWidth: CGFloat? = nil
    @State private var scrollerWidth: CGFloat = 0

    public init(viewModel: CommitHistoryViewModel) {
        self.viewModel = viewModel
    }

    private var graphColumnWidth: CGFloat {
        viewModel.effectiveGraphColumnWidth
    }

    private var authorColumnWidth: CGFloat {
        max(60, min(360, viewModel.authorColumnWidth))
    }

    private var dateColumnWidth: CGFloat {
        max(70, min(360, viewModel.dateColumnWidth))
    }

    private var revisionColumnWidth: CGFloat {
        max(55, min(260, viewModel.revisionColumnWidth))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Branch filter bar (matches top bar in screenshot)
            branchFilterBar

            Divider()

            // Table column headers with draggable column dividers
            columnHeadersBar

            Divider()

            // Commit rows list
            if viewModel.isLoading && viewModel.rows.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Loading commit history...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage, viewModel.rows.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.rows.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    if !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("No commits matching filter")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "clock")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("No commits found in repository")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CommitHistoryTableViewRepresentable(
                    rows: viewModel.rows,
                    selectedCommitId: viewModel.selectedCommitId,
                    comparisonCommitId: viewModel.comparisonCommitId,
                    vcsType: viewModel.repoContext.vcsType,
                    graphColumnWidth: graphColumnWidth,
                    authorColumnWidth: authorColumnWidth,
                    dateColumnWidth: dateColumnWidth,
                    revisionColumnWidth: revisionColumnWidth,
                    rowHeight: Self.rowHeight,
                    onScrollerWidthChange: { width in
                        if abs(scrollerWidth - width) > 0.5 {
                            scrollerWidth = width
                        }
                    },
                    onSelectCommit: { commitId in
                        viewModel.selectCommit(commitId)
                    },
                    onSelectCommitRange: { earliest, latest in
                        viewModel.compareRange(earliest: earliest, latest: latest)
                    },
                    canCheckout: { commit in
                        viewModel.canCheckoutRevision(commit)
                    },
                    onCheckout: { commit in
                        viewModel.checkoutRevision(commit)
                    },
                    canCompareWithSelected: { commit in
                        viewModel.canCompareWithSelected(commit)
                    },
                    onCompareWithSelected: { commit in
                        viewModel.compareWithSelected(commit)
                    }
                )
                .id(viewModel.selectedBranch)
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var branchFilterBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $viewModel.selectedBranch) {
                Text(CommitHistoryViewModel.allBranchesOption)
                    .tag(CommitHistoryViewModel.allBranchesOption)

                if !viewModel.branches.isEmpty {
                    Divider()
                    ForEach(viewModel.branches, id: \.self) { branch in
                        Text(branch).tag(branch)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(minWidth: 130, maxWidth: 220, alignment: .leading)
            .fixedSize()

            // Filter commits search bar
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField("Filter commits...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !viewModel.searchText.isEmpty {
                    Button(action: { viewModel.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
            .frame(minWidth: 140, maxWidth: 260)

            if let filePath = viewModel.filteredFilePath {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.isFilteredPathADirectory ? "folder" : "doc")
                        .font(.system(size: 10))
                    Text(filePath)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12))
                .foregroundColor(.accentColor)
                .cornerRadius(4)
            }

            Spacer()

            Text(viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(viewModel.rows.count) commits"
                : "\(viewModel.rows.count) of \(viewModel.allRows.count) commits"
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var columnHeadersBar: some View {
        HStack(spacing: 0) {
            // Graph column header
            HStack(spacing: 0) {
                Text("Graph")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .padding(.leading, 8)
                Spacer(minLength: 2)
                columnResizeHandle(
                    onChanged: { dx in
                        if graphDragStartWidth == nil {
                            graphDragStartWidth = graphColumnWidth
                        }
                        let newWidth = (graphDragStartWidth ?? graphColumnWidth) + dx
                        viewModel.customGraphColumnWidth = max(36, min(300, newWidth))
                    },
                    onEnded: {
                        graphDragStartWidth = nil
                    }
                )
            }
            .frame(width: graphColumnWidth, height: 22)

            // Description column header
            HStack(spacing: 0) {
                Text("Description")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .padding(.leading, 8)
                Spacer(minLength: 2)
                columnResizeHandle(
                    onChanged: { dx in
                        if descAuthorDragStartWidth == nil {
                            descAuthorDragStartWidth = authorColumnWidth
                        }
                        let newAuthorWidth = (descAuthorDragStartWidth ?? authorColumnWidth) - dx
                        viewModel.authorColumnWidth = max(60, min(360, newAuthorWidth))
                    },
                    onEnded: {
                        descAuthorDragStartWidth = nil
                    }
                )
            }
            .frame(minWidth: 100, maxWidth: .infinity, minHeight: 22, maxHeight: 22)

            // Author column header
            HStack(spacing: 0) {
                Text("Author")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .padding(.leading, 8)
                Spacer(minLength: 2)
                columnResizeHandle(
                    onChanged: { dx in
                        if authorDragStartWidth == nil {
                            authorDragStartWidth = authorColumnWidth
                            dateDragStartWidth = dateColumnWidth
                        }
                        let startAuthor = authorDragStartWidth ?? authorColumnWidth
                        let startDate = dateDragStartWidth ?? dateColumnWidth
                        let clampedDx = max(60 - startAuthor, min(startDate - 70, dx))
                        viewModel.authorColumnWidth = max(60, min(360, startAuthor + clampedDx))
                        viewModel.dateColumnWidth = max(70, min(360, startDate - clampedDx))
                    },
                    onEnded: {
                        authorDragStartWidth = nil
                        dateDragStartWidth = nil
                    }
                )
            }
            .frame(width: authorColumnWidth, height: 22)

            // Date column header
            HStack(spacing: 0) {
                Text("Date")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .padding(.leading, 8)
                Spacer(minLength: 2)
                columnResizeHandle(
                    onChanged: { dx in
                        if dateDragStartWidth == nil {
                            dateDragStartWidth = dateColumnWidth
                            revisionDragStartWidth = revisionColumnWidth
                        }
                        let startDate = dateDragStartWidth ?? dateColumnWidth
                        let startRev = revisionDragStartWidth ?? revisionColumnWidth
                        let clampedDx = max(70 - startDate, min(startRev - 55, dx))
                        viewModel.dateColumnWidth = max(70, min(360, startDate + clampedDx))
                        viewModel.revisionColumnWidth = max(55, min(260, startRev - clampedDx))
                    },
                    onEnded: {
                        dateDragStartWidth = nil
                        revisionDragStartWidth = nil
                    }
                )
            }
            .frame(width: dateColumnWidth, height: 22)

            // Revision column header
            HStack(spacing: 0) {
                Text("Revision")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .padding(.leading, 8)
                Spacer(minLength: 4)
            }
            .frame(width: revisionColumnWidth, height: 22)

            if scrollerWidth > 0 {
                Color.clear
                    .frame(width: scrollerWidth, height: 22)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
    }

    private func columnResizeHandle(
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1, height: 14)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9, height: 22)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { gesture in
                                onChanged(gesture.translation.width)
                            }
                            .onEnded { _ in
                                onEnded()
                            }
                    )
            )
            .onHover { isHovered in
                if isHovered {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .zIndex(5)
    }
}

// MARK: - AppKit NSTableView Infrastructure for High Performance Scrolling

final class CommitHistoryScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayout?()
    }
}

final class CommitBadgeNSView: NSView {
    private let iconView = NSImageView()
    private let textLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 4

        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        textLabel.isBordered = false
        textLabel.drawsBackground = false
        textLabel.isEditable = false
        textLabel.isSelectable = false
        textLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        textLabel.lineBreakMode = .byTruncatingTail
        addSubview(textLabel)
    }

    func configure(text: String, systemImage: String, color: NSColor) {
        layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        layer?.borderColor = color.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 1

        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        iconView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        iconView.contentTintColor = color

        textLabel.stringValue = text
        textLabel.textColor = color
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let padLeft: CGFloat = 5
        let iconSize: CGFloat = 10
        let spacing: CGFloat = 3
        let padRight: CGFloat = 5

        iconView.frame = NSRect(x: padLeft, y: (h - iconSize) / 2, width: iconSize, height: iconSize)

        let labelX = padLeft + iconSize + spacing
        let labelW = max(0, bounds.width - labelX - padRight)
        textLabel.frame = NSRect(x: labelX, y: (h - 14) / 2, width: labelW, height: 14)
    }

    private func calculatedLabelWidth() -> CGFloat {
        if let cell = textLabel.cell {
            return ceil(cell.cellSize.width) + 4
        }
        let text = textLabel.stringValue as NSString
        let font = textLabel.font ?? NSFont.systemFont(ofSize: 10, weight: .semibold)
        return ceil(text.size(withAttributes: [.font: font]).width) + 4
    }

    override var intrinsicContentSize: NSSize {
        let labelW = calculatedLabelWidth()
        return NSSize(width: labelW + 5 + 10 + 3 + 5, height: 16)
    }
}

final class CommitRevisionPillView: NSView {
    let revisionLabel = NSTextField()
    let copyButton = NSButton()
    var onCopy: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 4

        revisionLabel.isBordered = false
        revisionLabel.drawsBackground = false
        revisionLabel.isEditable = false
        revisionLabel.isSelectable = false
        revisionLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        revisionLabel.lineBreakMode = .byTruncatingTail
        addSubview(revisionLabel)

        copyButton.isBordered = false
        copyButton.setButtonType(.momentaryChange)
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy full revision")?.withSymbolConfiguration(config)
        copyButton.toolTip = "Copy full revision"
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        addSubview(copyButton)
    }

    @objc private func copyClicked() {
        onCopy?()
    }

    func configure(revisionText: String, isUncommitted: Bool, fullRevision: String) {
        revisionLabel.stringValue = revisionText
        if isUncommitted {
            layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
            revisionLabel.textColor = .systemOrange
            copyButton.isHidden = true
        } else {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            revisionLabel.textColor = .controlAccentColor
            copyButton.contentTintColor = .controlAccentColor
            copyButton.isHidden = false
        }
        onCopy = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fullRevision, forType: .string)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let padLeft: CGFloat = 6
        let padRight: CGFloat = 6
        let btnSize: CGFloat = 12
        let spacing: CGFloat = 4
        let labelH: CGFloat = 15
        let labelY: CGFloat = (h - labelH) / 2

        if copyButton.isHidden {
            revisionLabel.frame = NSRect(x: padLeft, y: labelY, width: max(0, bounds.width - padLeft - padRight), height: labelH)
        } else {
            let labelW = max(0, bounds.width - padLeft - spacing - btnSize - padRight)
            revisionLabel.frame = NSRect(x: padLeft, y: labelY, width: labelW, height: labelH)
            copyButton.frame = NSRect(x: padLeft + labelW + spacing, y: (h - btnSize) / 2, width: btnSize, height: btnSize)
        }
    }

    private func calculatedLabelWidth() -> CGFloat {
        if let cell = revisionLabel.cell {
            return ceil(cell.cellSize.width) + 4
        }
        guard let font = revisionLabel.font else { return 50 }
        let text = revisionLabel.stringValue as NSString
        return ceil(text.size(withAttributes: [.font: font]).width) + 4
    }

    override var intrinsicContentSize: NSSize {
        let labelW = calculatedLabelWidth()
        let buttonW: CGFloat = copyButton.isHidden ? 0 : (4 + 12)
        return NSSize(width: labelW + 6 + buttonW + 6, height: 18)
    }
}

final class CommitGraphNSView: NSView {
    var row: CommitGraphRow?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row = row else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.clip(to: bounds)
        defer { context.restoreGState() }

        let midY = bounds.height / 2.0
        let maxWidth = bounds.width + CommitGraphCellView.laneSpacing

        context.setLineWidth(CommitGraphCellView.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Incoming segments (y: 0 -> midY)
        for seg in row.incomingSegments {
            let fromX = CommitGraphCellView.laneX(seg.fromLane)
            let toX = CommitGraphCellView.laneX(seg.toLane)
            guard min(fromX, toX) <= maxWidth else { continue }

            let color = CommitGraphCellView.nsColor(for: seg.colorIndex)
            context.setStrokeColor(color.cgColor)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: fromX, y: 0))
            if seg.fromLane == seg.toLane {
                path.addLine(to: CGPoint(x: toX, y: midY))
            } else {
                let spanY = midY
                let c1 = CGPoint(x: fromX, y: spanY * 0.6)
                let c2 = CGPoint(x: toX, y: spanY * 0.4)
                path.addCurve(to: CGPoint(x: toX, y: midY), control1: c1, control2: c2)
            }
            context.addPath(path)
            context.strokePath()
        }

        // Outgoing segments (y: midY -> bounds.height)
        for seg in row.outgoingSegments {
            let fromX = CommitGraphCellView.laneX(seg.fromLane)
            let toX = CommitGraphCellView.laneX(seg.toLane)
            guard min(fromX, toX) <= maxWidth else { continue }

            let color = CommitGraphCellView.nsColor(for: seg.colorIndex)
            context.setStrokeColor(color.cgColor)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: fromX, y: midY))
            if seg.fromLane == seg.toLane {
                path.addLine(to: CGPoint(x: toX, y: bounds.height))
            } else {
                let spanY = bounds.height - midY
                let c1 = CGPoint(x: fromX, y: midY + spanY * 0.6)
                let c2 = CGPoint(x: toX, y: midY + spanY * 0.4)
                path.addCurve(to: CGPoint(x: toX, y: bounds.height), control1: c1, control2: c2)
            }
            context.addPath(path)
            context.strokePath()
        }

        // Commit circle node
        let nodeX = CommitGraphCellView.laneX(row.nodeLane)
        if nodeX <= maxWidth {
            let r = CommitGraphCellView.nodeRadius
            let circleRect = CGRect(x: nodeX - r, y: midY - r, width: r * 2, height: r * 2)
            let nodeColor = CommitGraphCellView.nsColor(for: row.nodeColorIndex)
            context.setFillColor(nodeColor.cgColor)
            context.fillEllipse(in: circleRect)
        }
    }
}

// MARK: - Dedicated Column Cell Views

final class CommitGraphTableCellView: NSTableCellView {
    let graphView = CommitGraphNSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(graphView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(graphView)
    }

    func configure(row: CommitGraphRow) {
        graphView.row = row
        graphView.needsDisplay = true
    }

    override func layout() {
        super.layout()
        graphView.frame = bounds
        graphView.needsDisplay = true
    }
}

final class CommitDescriptionTableCellView: NSTableCellView {
    let summaryLabel = NSTextField()
    let badgesContainer = NSView()
    private var badgeViews: [CommitBadgeNSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        summaryLabel.isEditable = false
        summaryLabel.isSelectable = false
        summaryLabel.isBordered = false
        summaryLabel.drawsBackground = false
        summaryLabel.font = NSFont.systemFont(ofSize: 12)
        summaryLabel.lineBreakMode = .byTruncatingTail
        addSubview(summaryLabel)

        badgesContainer.wantsLayer = true
        badgesContainer.layer?.masksToBounds = true
        addSubview(badgesContainer)
    }

    func configure(row: CommitGraphRow, isSelected: Bool) {
        summaryLabel.stringValue = row.commit.summary
        if row.commit.isUncommitted {
            summaryLabel.textColor = .systemOrange
        } else {
            summaryLabel.textColor = isSelected ? .labelColor : .labelColor.withAlphaComponent(0.92)
        }

        badgeViews.forEach { $0.removeFromSuperview() }
        badgeViews.removeAll()

        let hasBranches = !row.branches.isEmpty
        let hasTags = !row.tags.isEmpty
        if !hasBranches && !hasTags {
            badgesContainer.isHidden = true
        } else {
            badgesContainer.isHidden = false
            let nodeColor = CommitGraphCellView.nsColor(for: row.nodeColorIndex)
            for branch in row.branches {
                let badge = CommitBadgeNSView()
                badge.configure(text: branch, systemImage: "arrow.triangle.branch", color: nodeColor)
                badgesContainer.addSubview(badge)
                badgeViews.append(badge)
            }
            let yellowColor = NSColor(red: 0.85, green: 0.65, blue: 0.13, alpha: 1.0)
            for tag in row.tags {
                let badge = CommitBadgeNSView()
                badge.configure(text: tag, systemImage: "tag.fill", color: yellowColor)
                badgesContainer.addSubview(badge)
                badgeViews.append(badge)
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let pad: CGFloat = 8
        let availW = max(0, bounds.width - pad * 2)

        if badgesContainer.isHidden || badgeViews.isEmpty {
            summaryLabel.frame = NSRect(x: pad, y: (h - 16) / 2, width: availW, height: 16)
        } else {
            var badgesW: CGFloat = 0
            for (idx, b) in badgeViews.enumerated() {
                if idx > 0 { badgesW += 4 }
                badgesW += b.intrinsicContentSize.width
            }

            let intrinsicSummaryW: CGFloat
            if let cell = summaryLabel.cell {
                intrinsicSummaryW = ceil(cell.cellSize.width) + 4
            } else {
                let font = summaryLabel.font ?? NSFont.systemFont(ofSize: 12)
                intrinsicSummaryW = ceil((summaryLabel.stringValue as NSString).size(withAttributes: [.font: font]).width) + 4
            }
            let maxSummaryW = max(20, availW - badgesW - 6)
            let summaryW = min(maxSummaryW, intrinsicSummaryW)
            summaryLabel.frame = NSRect(x: pad, y: (h - 16) / 2, width: summaryW, height: 16)

            let badgeX = pad + summaryW + 6
            let badgeContainerW = min(badgesW, max(0, bounds.width - pad - badgeX))
            badgesContainer.frame = NSRect(x: badgeX, y: (h - 16) / 2, width: badgeContainerW, height: 16)

            var curX: CGFloat = 0
            for b in badgeViews {
                let bw = b.intrinsicContentSize.width
                b.frame = NSRect(x: curX, y: 0, width: bw, height: 16)
                curX += bw + 4
            }
        }
    }
}

final class CommitTextTableCellView: NSTableCellView {
    let label = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    func configure(text: String, isSelected: Bool) {
        label.stringValue = text
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        label.frame = NSRect(x: pad, y: (bounds.height - 16) / 2, width: max(0, bounds.width - pad * 2), height: 16)
    }
}

final class CommitRevisionTableCellView: NSTableCellView {
    let revisionPill = CommitRevisionPillView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(revisionPill)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(revisionPill)
    }

    func configure(revisionText: String, isUncommitted: Bool, fullRevision: String) {
        revisionPill.configure(
            revisionText: revisionText,
            isUncommitted: isUncommitted,
            fullRevision: fullRevision
        )
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        let pillIntrinsic = revisionPill.intrinsicContentSize
        let maxW = max(0, bounds.width - pad * 2)
        let pillW = min(maxW, max(32, pillIntrinsic.width))
        let pillH: CGFloat = 18
        revisionPill.frame = NSRect(
            x: pad,
            y: (bounds.height - pillH) / 2,
            width: pillW,
            height: pillH
        )
    }
}

final class CommitHistoryTableRowView: NSTableRowView {
    var isDark: Bool = false
    var isComparisonSelected: Bool = false {
        didSet {
            if isComparisonSelected != oldValue {
                needsDisplay = true
            }
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if isSelected {
            let selectionColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(isDark ? 0.35 : 0.24)
            selectionColor.setFill()
            dirtyRect.fill()
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isComparisonSelected && !isSelected {
            let selectionColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(isDark ? 0.35 : 0.24)
            selectionColor.setFill()
            dirtyRect.fill()
        }
    }
}

final class CommitHistoryTableView: NSTableView {
    weak var coordinator: CommitHistoryTableViewRepresentable.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0, let coordinator = coordinator, clickedRow < coordinator.rows.count else {
            return nil
        }

        let rowItem = coordinator.rows[clickedRow]
        let commit = rowItem.commit

        let menu = NSMenu(title: "Commit Context Menu")

        let checkoutItem = NSMenuItem(title: "Checkout Revision", action: #selector(handleCheckout), keyEquivalent: "")
        checkoutItem.target = self
        checkoutItem.representedObject = commit
        checkoutItem.isEnabled = coordinator.canCheckout(commit)
        menu.addItem(checkoutItem)

        let compareItem = NSMenuItem(title: "Compare with selected", action: #selector(handleCompareWithSelected), keyEquivalent: "")
        compareItem.target = self
        compareItem.representedObject = commit
        compareItem.isEnabled = coordinator.canCompareWithSelected(commit)
        menu.addItem(compareItem)

        return menu
    }

    @objc private func handleCheckout(_ sender: NSMenuItem) {
        guard let commit = sender.representedObject as? CommitInfo else { return }
        coordinator?.onCheckout(commit)
    }

    @objc private func handleCompareWithSelected(_ sender: NSMenuItem) {
        guard let commit = sender.representedObject as? CommitInfo else { return }
        coordinator?.onCompareWithSelected(commit)
    }
}

public struct CommitHistoryTableViewRepresentable: NSViewRepresentable {
    public let rows: [CommitGraphRow]
    public let selectedCommitId: String?
    public let comparisonCommitId: String?
    public let vcsType: VCSType
    public let graphColumnWidth: CGFloat
    public let authorColumnWidth: CGFloat
    public let dateColumnWidth: CGFloat
    public let revisionColumnWidth: CGFloat
    public let rowHeight: CGFloat
    public let onScrollerWidthChange: (CGFloat) -> Void
    public let onSelectCommit: (String) -> Void
    public let onSelectCommitRange: ((CommitInfo, CommitInfo) -> Void)?
    public let canCheckout: (CommitInfo) -> Bool
    public let onCheckout: (CommitInfo) -> Void
    public let canCompareWithSelected: (CommitInfo) -> Bool
    public let onCompareWithSelected: (CommitInfo) -> Void

    @Environment(\.colorScheme) private var colorScheme

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            rows: rows,
            selectedCommitId: selectedCommitId,
            comparisonCommitId: comparisonCommitId,
            vcsType: vcsType,
            graphColumnWidth: graphColumnWidth,
            authorColumnWidth: authorColumnWidth,
            dateColumnWidth: dateColumnWidth,
            revisionColumnWidth: revisionColumnWidth,
            isDark: colorScheme == .dark,
            onScrollerWidthChange: onScrollerWidthChange,
            onSelectCommit: onSelectCommit,
            onSelectCommitRange: onSelectCommitRange,
            canCheckout: canCheckout,
            onCheckout: onCheckout,
            canCompareWithSelected: canCompareWithSelected,
            onCompareWithSelected: onCompareWithSelected
        )
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = CommitHistoryScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        let tableView = CommitHistoryTableView()
        tableView.coordinator = context.coordinator
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = NSColor.textBackgroundColor
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = true
        tableView.focusRingType = .none

        // 1. Graph column
        let graphCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("graph"))
        graphCol.width = graphColumnWidth
        graphCol.minWidth = 36
        graphCol.maxWidth = 300
        graphCol.resizingMask = []
        tableView.addTableColumn(graphCol)

        // 2. Description column (flex width)
        let descCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("description"))
        let initTotalW = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : 800
        descCol.width = max(100, initTotalW - graphColumnWidth - authorColumnWidth - dateColumnWidth - revisionColumnWidth)
        descCol.minWidth = 100
        descCol.resizingMask = []
        tableView.addTableColumn(descCol)

        // 3. Author column
        let authorCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("author"))
        authorCol.width = authorColumnWidth
        authorCol.minWidth = 60
        authorCol.maxWidth = 360
        authorCol.resizingMask = []
        tableView.addTableColumn(authorCol)

        // 4. Date column
        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.width = dateColumnWidth
        dateCol.minWidth = 70
        dateCol.maxWidth = 360
        dateCol.resizingMask = []
        tableView.addTableColumn(dateCol)

        // 5. Revision column
        let revCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("revision"))
        revCol.width = revisionColumnWidth
        revCol.minWidth = 55
        revCol.maxWidth = 260
        revCol.resizingMask = []
        tableView.addTableColumn(revCol)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        context.coordinator.tableView = tableView
        context.coordinator.scrollView = scrollView

        scrollView.documentView = tableView
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.updateDimensionsAndLayout()
        }

        context.coordinator.updateDimensionsAndLayout()
        context.coordinator.syncSelection(forceScroll: true)
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(
            rows: rows,
            selectedCommitId: selectedCommitId,
            comparisonCommitId: comparisonCommitId,
            vcsType: vcsType,
            graphColumnWidth: graphColumnWidth,
            authorColumnWidth: authorColumnWidth,
            dateColumnWidth: dateColumnWidth,
            revisionColumnWidth: revisionColumnWidth,
            isDark: colorScheme == .dark,
            onScrollerWidthChange: onScrollerWidthChange,
            onSelectCommit: onSelectCommit,
            onSelectCommitRange: onSelectCommitRange,
            canCheckout: canCheckout,
            onCheckout: onCheckout,
            canCompareWithSelected: canCompareWithSelected,
            onCompareWithSelected: onCompareWithSelected
        )
    }

    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [CommitGraphRow]
        var selectedCommitId: String?
        var comparisonCommitId: String?
        var vcsType: VCSType
        var graphColumnWidth: CGFloat
        var authorColumnWidth: CGFloat
        var dateColumnWidth: CGFloat
        var revisionColumnWidth: CGFloat
        var isDark: Bool
        var onScrollerWidthChange: ((CGFloat) -> Void)?
        var onSelectCommit: (String) -> Void
        var onSelectCommitRange: ((CommitInfo, CommitInfo) -> Void)?
        var canCheckout: (CommitInfo) -> Bool
        var onCheckout: (CommitInfo) -> Void
        var canCompareWithSelected: (CommitInfo) -> Bool
        var onCompareWithSelected: (CommitInfo) -> Void

        weak var tableView: CommitHistoryTableView?
        weak var scrollView: NSScrollView?
        private var isProgrammaticSelection = false
        private var isUpdatingLayout = false
        private var lastScrollerWidth: CGFloat = -1

        init(
            rows: [CommitGraphRow],
            selectedCommitId: String?,
            comparisonCommitId: String?,
            vcsType: VCSType,
            graphColumnWidth: CGFloat,
            authorColumnWidth: CGFloat,
            dateColumnWidth: CGFloat,
            revisionColumnWidth: CGFloat,
            isDark: Bool,
            onScrollerWidthChange: @escaping (CGFloat) -> Void,
            onSelectCommit: @escaping (String) -> Void,
            onSelectCommitRange: ((CommitInfo, CommitInfo) -> Void)? = nil,
            canCheckout: @escaping (CommitInfo) -> Bool,
            onCheckout: @escaping (CommitInfo) -> Void,
            canCompareWithSelected: @escaping (CommitInfo) -> Bool,
            onCompareWithSelected: @escaping (CommitInfo) -> Void
        ) {
            self.rows = rows
            self.selectedCommitId = selectedCommitId
            self.comparisonCommitId = comparisonCommitId
            self.vcsType = vcsType
            self.graphColumnWidth = graphColumnWidth
            self.authorColumnWidth = authorColumnWidth
            self.dateColumnWidth = dateColumnWidth
            self.revisionColumnWidth = revisionColumnWidth
            self.isDark = isDark
            self.onScrollerWidthChange = onScrollerWidthChange
            self.onSelectCommit = onSelectCommit
            self.onSelectCommitRange = onSelectCommitRange
            self.canCheckout = canCheckout
            self.onCheckout = onCheckout
            self.canCompareWithSelected = canCompareWithSelected
            self.onCompareWithSelected = onCompareWithSelected
            super.init()
        }

        func update(
            rows: [CommitGraphRow],
            selectedCommitId: String?,
            comparisonCommitId: String?,
            vcsType: VCSType,
            graphColumnWidth: CGFloat,
            authorColumnWidth: CGFloat,
            dateColumnWidth: CGFloat,
            revisionColumnWidth: CGFloat,
            isDark: Bool,
            onScrollerWidthChange: @escaping (CGFloat) -> Void,
            onSelectCommit: @escaping (String) -> Void,
            onSelectCommitRange: ((CommitInfo, CommitInfo) -> Void)? = nil,
            canCheckout: @escaping (CommitInfo) -> Bool,
            onCheckout: @escaping (CommitInfo) -> Void,
            canCompareWithSelected: @escaping (CommitInfo) -> Bool,
            onCompareWithSelected: @escaping (CommitInfo) -> Void
        ) {
            let rowsChanged = (self.rows != rows)
            let widthsChanged = (self.graphColumnWidth != graphColumnWidth) ||
                                (self.authorColumnWidth != authorColumnWidth) ||
                                (self.dateColumnWidth != dateColumnWidth) ||
                                (self.revisionColumnWidth != revisionColumnWidth)
            let themeChanged = (self.isDark != isDark)
            let comparisonChanged = (self.comparisonCommitId != comparisonCommitId)
            let selectionChanged = (self.selectedCommitId != selectedCommitId)

            self.rows = rows
            self.selectedCommitId = selectedCommitId
            self.comparisonCommitId = comparisonCommitId
            self.vcsType = vcsType
            self.graphColumnWidth = graphColumnWidth
            self.authorColumnWidth = authorColumnWidth
            self.dateColumnWidth = dateColumnWidth
            self.revisionColumnWidth = revisionColumnWidth
            self.isDark = isDark
            self.onScrollerWidthChange = onScrollerWidthChange
            self.onSelectCommit = onSelectCommit
            self.onSelectCommitRange = onSelectCommitRange
            self.canCheckout = canCheckout
            self.onCheckout = onCheckout
            self.canCompareWithSelected = canCompareWithSelected
            self.onCompareWithSelected = onCompareWithSelected

            guard let tableView = tableView else { return }

            if widthsChanged {
                updateDimensionsAndLayout()
            }

            if rowsChanged || widthsChanged || themeChanged {
                updateDimensionsAndLayout()
                tableView.reloadData()
                syncSelection(forceScroll: false)
            } else if comparisonChanged || selectionChanged {
                tableView.reloadData()
                syncSelection(forceScroll: false)
            }
        }

        public func updateDimensionsAndLayout() {
            guard !isUpdatingLayout, let scrollView = scrollView, let tableView = tableView else { return }
            isUpdatingLayout = true
            defer { isUpdatingLayout = false }

            let totalW = scrollView.contentSize.width
            let sW = max(0, scrollView.bounds.width - scrollView.contentSize.width)
            if abs(sW - lastScrollerWidth) > 0.5 {
                lastScrollerWidth = sW
                DispatchQueue.main.async { [weak self] in
                    self?.onScrollerWidthChange?(sW)
                }
            }

            guard totalW > 0 else { return }

            let gW = graphColumnWidth
            let aW = authorColumnWidth
            let dW = dateColumnWidth
            let rW = revisionColumnWidth
            let descW = max(100, totalW - gW - aW - dW - rW)

            if let col0 = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("graph")), col0.width != gW {
                col0.width = gW
            }
            if let col1 = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("description")), col1.width != descW {
                col1.width = descW
            }
            if let col2 = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("author")), col2.width != aW {
                col2.width = aW
            }
            if let col3 = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("date")), col3.width != dW {
                col3.width = dW
            }
            if let col4 = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("revision")), col4.width != rW {
                col4.width = rW
            }
        }

        func isRowInComparisonRange(_ row: Int) -> Bool {
            guard let selId = selectedCommitId,
                  let compId = comparisonCommitId,
                  let idx1 = rows.firstIndex(where: { $0.id == selId }),
                  let idx2 = rows.firstIndex(where: { $0.id == compId }) else {
                return false
            }
            let minIdx = min(idx1, idx2)
            let maxIdx = max(idx1, idx2)
            return row >= minIdx && row <= maxIdx
        }

        func syncSelection(forceScroll: Bool) {
            guard let tableView = tableView else { return }
            guard let selectedId = selectedCommitId else {
                if tableView.selectedRow >= 0 {
                    isProgrammaticSelection = true
                    tableView.deselectAll(nil)
                    isProgrammaticSelection = false
                }
                return
            }

            guard let idx = rows.firstIndex(where: { $0.id == selectedId }) else {
                if tableView.selectedRow >= 0 {
                    isProgrammaticSelection = true
                    tableView.deselectAll(nil)
                    isProgrammaticSelection = false
                }
                return
            }

            let targetIndexes: IndexSet
            if let compId = comparisonCommitId,
               let compIdx = rows.firstIndex(where: { $0.id == compId }) {
                let minIdx = min(idx, compIdx)
                let maxIdx = max(idx, compIdx)
                targetIndexes = IndexSet(integersIn: minIdx...maxIdx)
            } else {
                targetIndexes = IndexSet(integer: idx)
            }

            if tableView.selectedRowIndexes != targetIndexes {
                isProgrammaticSelection = true
                tableView.selectRowIndexes(targetIndexes, byExtendingSelection: false)
                if forceScroll {
                    tableView.scrollRowToVisible(idx)
                }
                isProgrammaticSelection = false
            }
        }

        // MARK: - NSTableViewDataSource
        public func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        // MARK: - NSTableViewDelegate
        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < rows.count else { return nil }
            let rowItem = rows[row]
            let isSelected = (rowItem.id == selectedCommitId) || isRowInComparisonRange(row)
            guard let columnId = tableColumn?.identifier.rawValue else { return nil }

            switch columnId {
            case "graph":
                let identifier = NSUserInterfaceItemIdentifier("CommitGraphTableCellView")
                var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? CommitGraphTableCellView
                if cellView == nil {
                    cellView = CommitGraphTableCellView()
                    cellView?.identifier = identifier
                }
                cellView?.configure(row: rowItem)
                return cellView

            case "description":
                let identifier = NSUserInterfaceItemIdentifier("CommitDescriptionTableCellView")
                var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? CommitDescriptionTableCellView
                if cellView == nil {
                    cellView = CommitDescriptionTableCellView()
                    cellView?.identifier = identifier
                }
                cellView?.configure(row: rowItem, isSelected: isSelected)
                return cellView

            case "author":
                let identifier = NSUserInterfaceItemIdentifier("CommitAuthorTableCellView")
                var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? CommitTextTableCellView
                if cellView == nil {
                    cellView = CommitTextTableCellView()
                    cellView?.identifier = identifier
                }
                cellView?.configure(text: rowItem.commit.author, isSelected: isSelected)
                return cellView

            case "date":
                let identifier = NSUserInterfaceItemIdentifier("CommitDateTableCellView")
                var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? CommitTextTableCellView
                if cellView == nil {
                    cellView = CommitTextTableCellView()
                    cellView?.identifier = identifier
                }
                cellView?.configure(text: rowItem.commit.dateFormatted, isSelected: isSelected)
                return cellView

            case "revision":
                let identifier = NSUserInterfaceItemIdentifier("CommitRevisionTableCellView")
                var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? CommitRevisionTableCellView
                if cellView == nil {
                    cellView = CommitRevisionTableCellView()
                    cellView?.identifier = identifier
                }
                let revText: String
                if rowItem.commit.isUncommitted {
                    revText = rowItem.commit.displayRevision
                } else if vcsType == .hg {
                    if let colonIdx = rowItem.commit.displayRevision.firstIndex(of: ":") {
                        revText = String(rowItem.commit.displayRevision[..<colonIdx])
                    } else {
                        revText = rowItem.commit.displayRevision
                    }
                } else {
                    revText = rowItem.commit.displayRevision
                }
                cellView?.configure(
                    revisionText: revText,
                    isUncommitted: rowItem.commit.isUncommitted,
                    fullRevision: rowItem.commit.fullRevision
                )
                return cellView

            default:
                return nil
            }
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("CommitHistoryTableRowView")
            var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? CommitHistoryTableRowView
            if rowView == nil {
                rowView = CommitHistoryTableRowView()
                rowView?.identifier = identifier
            }
            rowView?.isDark = isDark
            rowView?.isComparisonSelected = isRowInComparisonRange(row)
            return rowView
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isProgrammaticSelection, let tableView = tableView else { return }
            let selectedIndexes = tableView.selectedRowIndexes
            if selectedIndexes.count == 1 {
                let selectedRow = selectedIndexes.first!
                guard selectedRow >= 0, selectedRow < rows.count else { return }
                let rowItem = rows[selectedRow]
                if rowItem.id != selectedCommitId || comparisonCommitId != nil {
                    onSelectCommit(rowItem.id)
                }
            } else if selectedIndexes.count > 1 {
                let minIdx = selectedIndexes.min()!
                let maxIdx = selectedIndexes.max()!
                guard minIdx >= 0, maxIdx < rows.count else { return }
                let latestCommit = rows[minIdx].commit
                let earliestCommit = rows[maxIdx].commit
                if selectedCommitId != latestCommit.id || comparisonCommitId != earliestCommit.id {
                    onSelectCommitRange?(earliestCommit, latestCommit)
                }
            }
        }
    }
}

// MARK: - Single Row in Commit History View
public struct CommitHistoryRowView: View, Equatable {
    public let row: CommitGraphRow
    public let graphColumnWidth: CGFloat
    public let authorColumnWidth: CGFloat
    public let dateColumnWidth: CGFloat
    public let revisionColumnWidth: CGFloat
    public let rowHeight: CGFloat
    public let isSelected: Bool
    public let isComparisonSelected: Bool
    public let canCheckout: Bool
    public let canCompareWithSelected: Bool
    public let vcsType: VCSType
    public let onSelect: () -> Void
    public let onCheckout: () -> Void
    public let onCompareWithSelected: () -> Void

    public static func == (lhs: CommitHistoryRowView, rhs: CommitHistoryRowView) -> Bool {
        lhs.row == rhs.row &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isComparisonSelected == rhs.isComparisonSelected &&
        lhs.canCheckout == rhs.canCheckout &&
        lhs.canCompareWithSelected == rhs.canCompareWithSelected &&
        lhs.graphColumnWidth == rhs.graphColumnWidth &&
        lhs.authorColumnWidth == rhs.authorColumnWidth &&
        lhs.dateColumnWidth == rhs.dateColumnWidth &&
        lhs.revisionColumnWidth == rhs.revisionColumnWidth &&
        lhs.rowHeight == rhs.rowHeight &&
        lhs.vcsType == rhs.vcsType
    }

    public var descriptionTextColor: Color {
        if row.commit.isUncommitted {
            return .orange
        }
        return isSelected ? .primary : .primary.opacity(0.92)
    }

    public var revisionText: String {
        if row.commit.isUncommitted {
            return row.commit.displayRevision
        }
        if vcsType == .hg {
            if let colonIdx = row.commit.displayRevision.firstIndex(of: ":") {
                return String(row.commit.displayRevision[..<colonIdx])
            }
            return row.commit.displayRevision
        }
        return row.commit.displayRevision
    }

    public init(
        row: CommitGraphRow,
        graphColumnWidth: CGFloat,
        authorColumnWidth: CGFloat,
        dateColumnWidth: CGFloat,
        revisionColumnWidth: CGFloat,
        rowHeight: CGFloat = 22,
        isSelected: Bool = false,
        isComparisonSelected: Bool = false,
        canCheckout: Bool = false,
        canCompareWithSelected: Bool = false,
        vcsType: VCSType = .git,
        onSelect: @escaping () -> Void = {},
        onCheckout: @escaping () -> Void = {},
        onCompareWithSelected: @escaping () -> Void = {}
    ) {
        self.row = row
        self.graphColumnWidth = graphColumnWidth
        self.authorColumnWidth = authorColumnWidth
        self.dateColumnWidth = dateColumnWidth
        self.revisionColumnWidth = revisionColumnWidth
        self.rowHeight = rowHeight
        self.isSelected = isSelected
        self.isComparisonSelected = isComparisonSelected
        self.canCheckout = canCheckout
        self.canCompareWithSelected = canCompareWithSelected
        self.vcsType = vcsType
        self.onSelect = onSelect
        self.onCheckout = onCheckout
        self.onCompareWithSelected = onCompareWithSelected
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Graph cell on the left side connecting revisions
            CommitGraphCellView(row: row, rowHeight: rowHeight)
                .frame(width: graphColumnWidth, height: rowHeight)
                .clipped()

            // Description (commit summary + ref tags)
            HStack(spacing: 6) {
                Text(row.commit.summary)
                    .font(.system(size: 12))
                    .foregroundColor(descriptionTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !row.branches.isEmpty || !row.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(row.branches, id: \.self) { branch in
                            branchBadge(branch, color: CommitGraphCellView.color(for: row.nodeColorIndex))
                        }
                        ForEach(row.tags, id: \.self) { tag in
                            tagBadge(tag)
                        }
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 100, maxWidth: .infinity, maxHeight: rowHeight, alignment: .leading)

            // Author
            Text(row.commit.author)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .frame(width: authorColumnWidth, height: rowHeight, alignment: .leading)

            // Date
            Text(row.commit.dateFormatted)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .frame(width: dateColumnWidth, height: rowHeight, alignment: .leading)

            // Revision
            HStack(spacing: 4) {
                Text(revisionText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                if !row.commit.isUncommitted {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.commit.fullRevision, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Copy full revision")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(row.commit.isUncommitted ? Color.orange.opacity(0.18) : Color.accentColor.opacity(0.12))
            .foregroundColor(row.commit.isUncommitted ? .orange : .accentColor)
            .cornerRadius(4)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(width: revisionColumnWidth, height: rowHeight, alignment: .leading)
        }
        .frame(height: rowHeight)
        .background(
            (isSelected || isComparisonSelected)
                ? Color.accentColor.opacity(0.24)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button("Checkout Revision") {
                onCheckout()
            }
            .disabled(!canCheckout)

            Button("Compare with selected") {
                onCompareWithSelected()
            }
            .disabled(!canCompareWithSelected)
        }
    }

    private func branchBadge(_ name: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8, weight: .bold))
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(color.opacity(0.18))
        .foregroundColor(color)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }

    private func tagBadge(_ name: String) -> some View {
        let tagColor = Color.adaptiveYellow
        return HStack(spacing: 3) {
            Image(systemName: "tag.fill")
                .font(.system(size: 8, weight: .bold))
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tagColor.opacity(0.18))
        .foregroundColor(tagColor)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(tagColor.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Commit Graph Cell View (Canvas Drawing)
public struct CommitGraphCellView: View, Equatable {
    public let row: CommitGraphRow
    public let rowHeight: CGFloat

    public static func == (lhs: CommitGraphCellView, rhs: CommitGraphCellView) -> Bool {
        lhs.row == rhs.row &&
        lhs.rowHeight == rhs.rowHeight
    }

    public static let leftPadding: CGFloat = 8
    public static let laneSpacing: CGFloat = 8
    public static let lineWidth: CGFloat = 1
    public static let nodeRadius: CGFloat = 3

    public static let palette: [Color] = [
        Color(red: 0.16, green: 0.49, blue: 0.96), // Blue (primary lane 0, matches screenshot)
        Color(red: 0.92, green: 0.36, blue: 0.08), // Orange (branch lane 1, matches screenshot)
        Color(red: 0.20, green: 0.78, blue: 0.35), // Green
        Color(red: 0.69, green: 0.32, blue: 0.87), // Purple
        Color(red: 0.95, green: 0.27, blue: 0.40), // Pink/Red
        Color(red: 0.19, green: 0.69, blue: 0.78), // Cyan/Teal
        Color(red: 0.96, green: 0.74, blue: 0.15), // Yellow
        Color(red: 0.35, green: 0.34, blue: 0.84)  // Indigo
    ]

    public static let nsPalette: [NSColor] = [
        NSColor(red: 0.16, green: 0.49, blue: 0.96, alpha: 1.0),
        NSColor(red: 0.92, green: 0.36, blue: 0.08, alpha: 1.0),
        NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0),
        NSColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1.0),
        NSColor(red: 0.95, green: 0.27, blue: 0.40, alpha: 1.0),
        NSColor(red: 0.19, green: 0.69, blue: 0.78, alpha: 1.0),
        NSColor(red: 0.96, green: 0.74, blue: 0.15, alpha: 1.0),
        NSColor(red: 0.35, green: 0.34, blue: 0.84, alpha: 1.0)
    ]

    public static func color(for index: Int) -> Color {
        palette[abs(index) % palette.count]
    }

    public static func nsColor(for index: Int) -> NSColor {
        nsPalette[abs(index) % nsPalette.count]
    }

    public static func laneX(_ lane: Int) -> CGFloat {
        leftPadding + CGFloat(lane) * laneSpacing
    }

    public static func appendSegment(
        to path: inout Path,
        fromX: CGFloat,
        toX: CGFloat,
        fromLane: Int,
        toLane: Int,
        startY: CGFloat,
        endY: CGFloat
    ) {
        path.move(to: CGPoint(x: fromX, y: startY))
        if fromLane == toLane {
            path.addLine(to: CGPoint(x: toX, y: endY))
        } else {
            let spanY = endY - startY
            let control1 = CGPoint(x: fromX, y: startY + spanY * 0.6)
            let control2 = CGPoint(x: toX, y: startY + spanY * 0.4)
            path.addCurve(
                to: CGPoint(x: toX, y: endY),
                control1: control1,
                control2: control2
            )
        }
    }

    public static func segmentPath(
        fromLane: Int,
        toLane: Int,
        startY: CGFloat,
        endY: CGFloat
    ) -> Path {
        var path = Path()
        appendSegment(
            to: &path,
            fromX: laneX(fromLane),
            toX: laneX(toLane),
            fromLane: fromLane,
            toLane: toLane,
            startY: startY,
            endY: endY
        )
        return path
    }

    public init(row: CommitGraphRow, rowHeight: CGFloat = 22) {
        self.row = row
        self.rowHeight = rowHeight
    }

    public var body: some View {
        Canvas { context, size in
            let midY = size.height / 2.0
            let maxWidth = size.width + Self.laneSpacing

            // Group paths by color to batch draw calls across lanes
            var pathsByColor: [Int: Path] = [:]

            // 1. Incoming segments (from y = 0 to y = midY)
            for seg in row.incomingSegments {
                let fromX = Self.laneX(seg.fromLane)
                let toX = Self.laneX(seg.toLane)
                guard min(fromX, toX) <= maxWidth else { continue }

                if pathsByColor[seg.colorIndex] == nil {
                    pathsByColor[seg.colorIndex] = Path()
                }
                Self.appendSegment(
                    to: &pathsByColor[seg.colorIndex]!,
                    fromX: fromX,
                    toX: toX,
                    fromLane: seg.fromLane,
                    toLane: seg.toLane,
                    startY: 0,
                    endY: midY
                )
            }

            // 2. Outgoing segments (from y = midY to y = size.height)
            for seg in row.outgoingSegments {
                let fromX = Self.laneX(seg.fromLane)
                let toX = Self.laneX(seg.toLane)
                guard min(fromX, toX) <= maxWidth else { continue }

                if pathsByColor[seg.colorIndex] == nil {
                    pathsByColor[seg.colorIndex] = Path()
                }
                Self.appendSegment(
                    to: &pathsByColor[seg.colorIndex]!,
                    fromX: fromX,
                    toX: toX,
                    fromLane: seg.fromLane,
                    toLane: seg.toLane,
                    startY: midY,
                    endY: size.height
                )
            }

            // Stroke batched paths (at most 8 draw calls total)
            let strokeStyle = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
            for (colorIdx, path) in pathsByColor {
                context.stroke(
                    path,
                    with: .color(Self.color(for: colorIdx)),
                    style: strokeStyle
                )
            }

            // 3. Draw commit circle node at (nodeLane, midY)
            let nodeX = Self.laneX(row.nodeLane)
            if nodeX <= maxWidth {
                let r = Self.nodeRadius
                let circleRect = CGRect(x: nodeX - r, y: midY - r, width: r * 2, height: r * 2)
                context.fill(
                    Path(ellipseIn: circleRect),
                    with: .color(Self.color(for: row.nodeColorIndex))
                )
            }
        }
    }
}

// MARK: - Bottom: Commit Information View
public struct CommitInformationView: View {
    @ObservedObject var viewModel: CommitHistoryViewModel

    @State private var detailsWidth: CGFloat = 310
    @State private var detailsDragStartWidth: CGFloat? = nil

    public init(viewModel: CommitHistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 0) {
            // LEFT: Commit Details View
            CommitDetailsView(viewModel: viewModel)
                .frame(width: max(200, min(560, detailsWidth)))
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)

            // Draggable horizontal divider between Commit Details View and DiffView
            horizontalResizeHandle
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)

            // RIGHT: DiffView (already exists)
            rightDiffPane
                .layoutPriority(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var horizontalResizeHandle: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { gesture in
                                if detailsDragStartWidth == nil {
                                    detailsDragStartWidth = detailsWidth
                                }
                                let newWidth = (detailsDragStartWidth ?? detailsWidth) + gesture.translation.width
                                detailsWidth = max(200, min(560, newWidth))
                            }
                            .onEnded { _ in
                                detailsDragStartWidth = nil
                            }
                    )
            )
            .onHover { isHovered in
                if isHovered {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .zIndex(10)
    }

    private var rightDiffPane: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)

            if (viewModel.selectedCommit != nil || viewModel.isComparingCommits) && viewModel.selectedFilePath != nil {
                DiffView(viewModel: viewModel.diffViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.selectedCommit != nil || viewModel.isComparingCommits {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("Select a file to preview changes")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Left of Commit Information View: Commit Details View
public struct CommitDetailsView: View {
    @ObservedObject var viewModel: CommitHistoryViewModel

    /// Default height for the bottom commit message section (~5 lines height + Description header)
    public static let defaultCommitMessageHeight: CGFloat = 120
    public static let filesHeaderIconName = "doc.text"
    public static let descriptionHeaderTitle = "Description"
    public static let descriptionHeaderIconName = "text.bubble"
    public static let viewAsListIconName = "list.bullet"
    public static let viewAsTreeIconName = "list.bullet.indent"
    public static let viewAsListHelp = "View as list"
    public static let viewAsTreeHelp = "View as tree"

    @State private var commitMessageHeight: CGFloat = CommitDetailsView.defaultCommitMessageHeight
    @State private var messageDragStartHeight: CGFloat? = nil
    @State private var collapsedNodes: Set<String> = []
    @State private var treeNodes: [FileTreeNode] = []
    @State private var visibleFlatTreeItems: [FlatFileTreeItem] = []

    public init(viewModel: CommitHistoryViewModel) {
        self.viewModel = viewModel
    }

    public var isShowingWorkingSetCommitButton: Bool {
        !viewModel.isComparingCommits && viewModel.selectedCommit?.isUncommitted == true
    }

    public var isShowingCommitMessage: Bool {
        guard viewModel.selectedCommit?.isUncommitted != true,
              !viewModel.isComparingCommits,
              let commit = viewModel.selectedCommit else {
            return false
        }
        let message = !commit.fullMessage.isEmpty ? commit.fullMessage : commit.summary
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.components(separatedBy: .newlines).count > 1
    }

    public var filesHeaderTitle: String {
        if viewModel.isComparingCommits {
            return "Changed Files"
        }
        return viewModel.selectedCommit?.isUncommitted == true ? "Pending Files" : "Files in Commit"
    }

    public var body: some View {
        Group {
            if viewModel.selectedCommit != nil || viewModel.isComparingCommits {
                if viewModel.selectedCommit?.isUncommitted == true {
                    VStack(spacing: 0) {
                        // TOP: Files in the working set
                        filesInCommitPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if isShowingWorkingSetCommitButton {
                            Divider()

                            // BOTTOM: "Commit" button when working set is selected
                            workingSetCommitButtonBar
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isShowingCommitMessage {
                    GeometryReader { geometry in
                        let totalHeight = max(150, geometry.size.height)
                        let clampedMessageHeight = max(50, min(totalHeight - 60, commitMessageHeight))

                        VStack(spacing: 0) {
                            // TOP: Files in commit
                            filesInCommitPane
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            // Draggable divider between file list and commit message
                            messageResizeHandle(totalHeight: totalHeight, currentHeight: clampedMessageHeight)

                            // BOTTOM: Full commit message pane
                            commitMessagePane
                                .frame(height: clampedMessageHeight)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    filesInCommitPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Shows nothing until a row in the Commit History View is selected
                Color(NSColor.windowBackgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var commitMessagePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: Self.descriptionHeaderIconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(Self.descriptionHeaderTitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .overlay(Divider(), alignment: .bottom)

            if let commit = viewModel.selectedCommit {
                ScrollView(.vertical) {
                    Text(commit.fullMessage.isEmpty ? commit.summary : commit.fullMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }

    private func messageResizeHandle(totalHeight: CGFloat, currentHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(height: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { gesture in
                                if messageDragStartHeight == nil {
                                    messageDragStartHeight = currentHeight
                                }
                                let newHeight = (messageDragStartHeight ?? currentHeight) - gesture.translation.height
                                commitMessageHeight = max(50, min(totalHeight - 60, newHeight))
                            }
                            .onEnded { _ in
                                messageDragStartHeight = nil
                            }
                    )
            )
            .onHover { isHovered in
                if isHovered {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .zIndex(10)
    }

    private var workingSetCommitButtonBar: some View {
        HStack {
            Spacer()
            Button(action: {
                viewModel.openCommitPrompt()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Commit")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(minHeight: 24)
                .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isWorkingSetLoading)
            .help(viewModel.isWorkingSetLoading ? "Loading working directory changes..." : "Commit working directory changes")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
    }

    private var filesInCommitPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: Self.filesHeaderIconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(filesHeaderTitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(viewModel.changedFiles.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                HStack(spacing: 2) {
                    Button(action: {
                        viewModel.fileViewMode = .list
                    }) {
                        Image(systemName: Self.viewAsListIconName)
                            .font(.system(size: 10, weight: viewModel.fileViewMode == .list ? .bold : .regular))
                            .foregroundColor(viewModel.fileViewMode == .list ? .accentColor : .secondary)
                            .frame(width: 18, height: 18)
                            .background(viewModel.fileViewMode == .list ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help(Self.viewAsListHelp)

                    Button(action: {
                        viewModel.fileViewMode = .tree
                    }) {
                        Image(systemName: Self.viewAsTreeIconName)
                            .font(.system(size: 10, weight: viewModel.fileViewMode == .tree ? .bold : .regular))
                            .foregroundColor(viewModel.fileViewMode == .tree ? .accentColor : .secondary)
                            .frame(width: 18, height: 18)
                            .background(viewModel.fileViewMode == .tree ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help(Self.viewAsTreeHelp)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .overlay(Divider(), alignment: .bottom)

            if (viewModel.isLoadingFiles || viewModel.isWorkingSetLoading) && viewModel.changedFiles.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.75)
                    Text("Loading files...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.changedFiles.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text(viewModel.isComparingCommits ? "No file changes between commits" : "No file changes in this commit")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.fileViewMode == .tree {
                treeFilesListView
            } else {
                flatFilesListView
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .onAppear {
            rebuildTree()
        }
        .onChange(of: viewModel.changedFiles) {
            rebuildTree()
        }
        .onChange(of: viewModel.selectedFilePath) {
            if let sel = viewModel.selectedFilePath {
                expandAncestors(for: sel)
                updateFlatTreeItems()
            }
        }
    }

    private var flatFilesListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.changedFiles) { change in
                    let isSelected = viewModel.selectedFilePath == change.relativePath

                    HStack(spacing: 8) {
                        statusBadge(change.status)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: change.relativePath).lastPathComponent)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(change.status.textColor)

                            if change.relativePath.contains("/") {
                                Text(change.relativePath)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        isSelected
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        viewModel.openFileInTab(change.relativePath)
                    }
                    .onTapGesture(count: 1) {
                        viewModel.selectFile(change.relativePath)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var displayFlatTreeItems: [FlatFileTreeItem] {
        if visibleFlatTreeItems.isEmpty && !viewModel.changedFiles.isEmpty {
            var statusMap: [String: FileWorkingStatus] = [:]
            for change in viewModel.changedFiles {
                statusMap[change.relativePath] = change.status
            }
            let nodes = FileTreeNode.buildTree(from: statusMap, repoRoot: viewModel.repoContext.repoRoot)
            let defaultCollapsed = collapsedNodes.isEmpty ? nodes.defaultCollapsedUntrackedNodeIds() : collapsedNodes
            var items: [FlatFileTreeItem] = []
            func collect(nodes: [FileTreeNode], level: Int) {
                for node in nodes {
                    items.append(FlatFileTreeItem(node: node, level: level))
                    if node.isDirectory {
                        let isExpanded = !defaultCollapsed.contains(node.id)
                        if isExpanded, let children = node.children {
                            collect(nodes: children, level: level + 1)
                        }
                    }
                }
            }
            collect(nodes: nodes, level: 0)
            return items
        }
        return visibleFlatTreeItems
    }

    private var treeFilesListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(displayFlatTreeItems) { item in
                    let isExpanded = !collapsedNodes.contains(item.node.id)
                    let isSelected = !item.node.isDirectory && viewModel.selectedFilePath == item.node.id

                    CommitFileTreeRow(
                        node: item.node,
                        level: item.level,
                        isExpanded: isExpanded,
                        isSelected: isSelected,
                        onToggleExpand: {
                            toggleExpand(item.node)
                        },
                        onSelect: {
                            viewModel.selectFile(item.node.id)
                        },
                        onOpenInTab: {
                            viewModel.openFileInTab(item.node.id)
                        }
                    )
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
    }

    private func rebuildTree() {
        var statusMap: [String: FileWorkingStatus] = [:]
        for change in viewModel.changedFiles {
            statusMap[change.relativePath] = change.status
        }
        self.treeNodes = FileTreeNode.buildTree(from: statusMap, repoRoot: viewModel.repoContext.repoRoot)
        self.collapsedNodes = self.treeNodes.defaultCollapsedUntrackedNodeIds()
        if let sel = viewModel.selectedFilePath {
            expandAncestors(for: sel)
        }
        updateFlatTreeItems()
    }

    private func updateFlatTreeItems() {
        var items: [FlatFileTreeItem] = []

        func collect(nodes: [FileTreeNode], level: Int) {
            for node in nodes {
                items.append(FlatFileTreeItem(node: node, level: level))
                if node.isDirectory {
                    let isExpanded = !collapsedNodes.contains(node.id)
                    if isExpanded, let children = node.children {
                        collect(nodes: children, level: level + 1)
                    }
                }
            }
        }

        collect(nodes: treeNodes, level: 0)
        self.visibleFlatTreeItems = items
    }

    private func toggleExpand(_ node: FileTreeNode) {
        if collapsedNodes.contains(node.id) {
            collapsedNodes.remove(node.id)
        } else {
            collapsedNodes.insert(node.id)
        }
        updateFlatTreeItems()
    }

    private func expandAncestors(for relativePath: String) {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return }
        var current = ""
        for i in 0..<(parts.count - 1) {
            current = current.isEmpty ? parts[i] : "\(current)/\(parts[i])"
            if let node = treeNodes.findNode(withRelativePath: current), node.containsOnlyUntrackedFiles() {
                continue
            }
            collapsedNodes.remove(current)
        }
    }

    private func statusBadge(_ status: FileWorkingStatus) -> some View {
        Text(status.badgeLabel)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(status.textColor)
            .frame(width: 16, height: 16)
            .background(status.textColor.opacity(0.15))
            .cornerRadius(4)
    }
}

// MARK: - Commit File Tree Row
struct CommitFileTreeRow: View {
    let node: FileTreeNode
    let level: Int
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleExpand: () -> Void
    let onSelect: () -> Void
    let onOpenInTab: () -> Void

    private var itemTextColor: Color {
        if let statusColor = node.statusTextColor {
            return statusColor
        }
        return isSelected ? .accentColor : .primary
    }

    private var iconColor: Color {
        if node.isDirectory {
            if let statusColor = node.statusTextColor {
                return statusColor
            }
            return Color(NSColor.systemBlue)
        }
        if let statusColor = node.statusTextColor {
            return statusColor
        }
        return node.iconColor
    }

    private func statusBadge(_ status: FileWorkingStatus) -> some View {
        Text(status.badgeLabel)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(status.textColor)
            .frame(width: 16, height: 16)
            .background(status.textColor.opacity(0.15))
            .cornerRadius(4)
    }

    var body: some View {
        HStack(spacing: 4) {
            // Indentation
            if level > 0 {
                Spacer()
                    .frame(width: CGFloat(level * 12))
            }

            if node.isDirectory {
                // Disclosure chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(node.statusTextColor ?? .secondary)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onToggleExpand()
                    }

                // Directory Icon (colored similar to RepositorySidebarView.swift)
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 11))
                    .foregroundColor(iconColor)
                    .frame(width: 14, height: 14)

                // Name
                Text(node.name)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(itemTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            } else {
                Spacer()
                    .frame(width: 12)

                // File Icon
                Image(systemName: node.iconName)
                    .font(.system(size: 11))
                    .foregroundColor(iconColor)
                    .frame(width: 14, height: 14)

                // Name
                Text(node.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(itemTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                // Status Badge
                statusBadge(node.status)
            }
        }
        .frame(height: 20)
        .padding(.horizontal, 4)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear
        )
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if node.isDirectory {
                onToggleExpand()
            } else {
                onOpenInTab()
            }
        }
        .onTapGesture(count: 1) {
            if node.isDirectory {
                onToggleExpand()
            } else {
                onSelect()
            }
        }
        .contextMenu {
            if !node.isDirectory {
                Button("Open in Tab") {
                    onOpenInTab()
                }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.fullURL])
                }
            } else {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.fullURL])
                }
            }
        }
    }
}
