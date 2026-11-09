import SwiftUI
import AppKit
import CoreText

public struct DiffView: View {
    @ObservedObject var viewModel: DiffViewModel
    @Environment(\.colorScheme) var colorScheme

    public init(viewModel: DiffViewModel) {
        self.viewModel = viewModel
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var addedBgColor: Color {
        Color.green.opacity(isDark ? 0.22 : 0.12)
    }

    private var addedTextColor: Color {
        isDark ? Color(red: 0.35, green: 0.85, blue: 0.45) : Color(red: 0.08, green: 0.52, blue: 0.18)
    }

    private var deletedBgColor: Color {
        Color.red.opacity(isDark ? 0.22 : 0.12)
    }

    private var deletedTextColor: Color {
        isDark ? Color(red: 0.95, green: 0.45, blue: 0.45) : Color(red: 0.82, green: 0.18, blue: 0.18)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header View
            headerToolbar

            // Revert Error Banner
            if let error = viewModel.revertErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer()
                    Button(action: {
                        viewModel.revertErrorMessage = nil
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.red.opacity(isDark ? 0.25 : 0.12))
                .overlay(Divider(), alignment: .bottom)
            }

            Divider()

            // MARK: - Main Content Area
            ZStack {
                Color(NSColor.textBackgroundColor)

                if viewModel.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("Loading diff...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("Diff Unavailable")
                            .font(.system(size: 14, weight: .semibold))
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.isBinary && !viewModel.isImage {
                    binaryFileMessageView
                } else if viewModel.isImage {
                    imageDiffView
                } else {
                    textDiffView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header Toolbar
    private var headerToolbar: some View {
        HStack(spacing: 12) {
            // Left metadata items
            HStack(spacing: 10) {
                // File type badge
                Text(viewModel.fileTypeLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.quaternaryLabelColor))
                    .cornerRadius(4)
                    .lineLimit(1)
                    .fixedSize()

                // Total lines (or dimensions / size for image/binary)
                if !viewModel.isImage && !viewModel.isBinary {
                    Text("\(viewModel.totalLines) lines")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                } else if viewModel.isImage {
                    let img = viewModel.newImage ?? viewModel.oldImage
                    if let img = img {
                        Text("\(Int(img.size.width)) × \(Int(img.size.height)) px")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else if viewModel.isBinary {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(viewModel.binaryDataSize), countStyle: .file)
                    Text(sizeStr)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }

                // Delta (+added / -removed)
                if !viewModel.isImage && !viewModel.isBinary {
                    if viewModel.addedCount > 0 || viewModel.removedCount > 0 {
                        HStack(spacing: 8) {
                            if viewModel.addedCount > 0 {
                                Text("+\(viewModel.addedCount)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(addedTextColor)
                            }
                            if viewModel.removedCount > 0 {
                                Text("-\(viewModel.removedCount)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(deletedTextColor)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Color(NSColor.separatorColor).opacity(0.12))
                        .cornerRadius(4)
                        .lineLimit(1)
                        .fixedSize()
                    }
                } else if let status = viewModel.fileChange?.status {
                    Text(status.badgeLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(status.textColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(status.textColor.opacity(0.15))
                        .cornerRadius(4)
                        .lineLimit(1)
                        .fixedSize()
                }

                // Filename (allows middle truncation when space is tight)
                Text(viewModel.displayedPath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.displayedPath)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            // Right controls container: strictly single line and preserved layout priority
            HStack(spacing: 12) {
                // Image Zoom Controls (if image)
                if viewModel.isImage {
                    HStack(spacing: 6) {
                        Button(action: {
                            viewModel.imageZoom = max(0.1, ((viewModel.imageZoom - 0.1) * 10).rounded() / 10)
                        }) {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .buttonStyle(.plain)

                        Text("\(Int((viewModel.imageZoom * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 44)

                        Button(action: {
                            viewModel.imageZoom = min(10.0, ((viewModel.imageZoom + 0.1) * 10).rounded() / 10)
                        }) {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .buttonStyle(.plain)

                        Button("Reset") {
                            viewModel.imageZoom = 1.0
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                    }
                    .lineLimit(1)
                    .fixedSize()
                }

                // Context prompt: strictly a single line
                if !viewModel.isImage && !viewModel.isBinary {
                    HStack(spacing: 4) {
                        Text("Context:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize()

                        Picker("", selection: $viewModel.contextOption) {
                            ForEach(DiffContextOption.allCases) { opt in
                                Text(opt.rawValue).tag(opt)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .lineLimit(1)
                        .fixedSize()
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                }

                // Diff Mode Picker (Unified / Side by Side)
                if !viewModel.isBinary {
                    Picker("", selection: $viewModel.diffMode) {
                        ForEach(DiffMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Binary File Message View
    private var binaryFileMessageView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 38))
                .foregroundColor(.secondary)

            Text("Binary File")
                .font(.system(size: 15, weight: .semibold))

            Text("Binary file changes cannot be previewed as text diffs.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Image Diff View
    private var imageDiffView: some View {
        GeometryReader { geometry in
            let availableSize = geometry.size

            if viewModel.diffMode == .sideBySide {
                HStack(spacing: 0) {
                    // Left: Previous Image (Old)
                    VStack(spacing: 0) {
                        HStack {
                            Text("Previous (Committed)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                            Spacer()
                            if let old = viewModel.oldImage, let data = viewModel.oldImageData {
                                Text("\(Int(old.size.width)) × \(Int(old.size.height)) px • \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
                        .overlay(Divider(), alignment: .bottom)

                        if let oldImage = viewModel.oldImage {
                            imageContainer(image: oldImage, availableSize: CGSize(width: availableSize.width / 2, height: availableSize.height - 30))
                        } else {
                            VStack(spacing: 6) {
                                Spacer()
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 28))
                                    .foregroundColor(.secondary)
                                Text("No previous version (Added)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    // Right: Current Image (New)
                    VStack(spacing: 0) {
                        HStack {
                            Text("Current (Working Copy)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                            Spacer()
                            if let new = viewModel.newImage, let data = viewModel.newImageData {
                                Text("\(Int(new.size.width)) × \(Int(new.size.height)) px • \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
                        .overlay(Divider(), alignment: .bottom)

                        if let newImage = viewModel.newImage {
                            imageContainer(image: newImage, availableSize: CGSize(width: availableSize.width / 2, height: availableSize.height - 30))
                        } else {
                            VStack(spacing: 6) {
                                Spacer()
                                Image(systemName: "trash")
                                    .font(.system(size: 28))
                                    .foregroundColor(.red.opacity(0.7))
                                Text("File deleted in working copy")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Unified Image Diff View: Shows current (or previous if deleted), with compare card if both exist
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 16) {
                        if let old = viewModel.oldImage, let new = viewModel.newImage {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Previous")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.secondary)
                                imageCard(image: old, size: old.size)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Current")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.secondary)
                                imageCard(image: new, size: new.size)
                            }
                        } else if let new = viewModel.newImage {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Added (New)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(addedTextColor)
                                imageCard(image: new, size: new.size)
                            }
                        } else if let old = viewModel.oldImage {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Deleted")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(deletedTextColor)
                                imageCard(image: old, size: old.size)
                            }
                        }
                    }
                    .padding(20)
                    .frame(minWidth: max(0, availableSize.width - 16), minHeight: availableSize.height, alignment: .center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func imageContainer(image: NSImage, availableSize: CGSize) -> some View {
        let zoom = viewModel.imageZoom
        let displayWidth = image.size.width * zoom
        let displayHeight = image.size.height * zoom
        let contentWidth = max(availableSize.width, displayWidth + 32)
        let contentHeight = max(availableSize.height, displayHeight + 32)

        return ScrollView([.horizontal, .vertical]) {
            ZStack {
                CheckerboardBackground()

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayWidth, height: displayHeight)
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            }
            .frame(width: contentWidth, height: contentHeight)
        }
    }

    private func imageCard(image: NSImage, size: CGSize) -> some View {
        let zoom = viewModel.imageZoom
        let displayWidth = size.width * zoom
        let displayHeight = size.height * zoom

        return ZStack {
            CheckerboardBackground()
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: displayWidth, height: displayHeight)
        }
        .frame(width: displayWidth + 24, height: displayHeight + 24)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
    }

    // MARK: - Text Diff View
    private var textDiffView: some View {
        Group {
            if viewModel.chunks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("No file changes to display")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffTextRepresentable(
                    viewModel: viewModel,
                    isDark: isDark
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - High-Performance Diff Text Representable
struct DiffTextRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: DiffViewModel
    let isDark: Bool

    func makeNSView(context: Context) -> DiffContainerView {
        let view = DiffContainerView()
        view.update(
            chunks: viewModel.chunks,
            diffMode: viewModel.diffMode,
            isDark: isDark,
            language: viewModel.language,
            fileKey: viewModel.displayedPath,
            revertStates: viewModel.revertStates,
            onRevertBlock: { [weak viewModel] keys, removedLines, addedLines, contextBefore, contextAfter in
                viewModel?.revertBlock(
                    keys: keys,
                    removedLines: removedLines,
                    addedLines: addedLines,
                    contextBefore: contextBefore,
                    contextAfter: contextAfter
                )
            }
        )
        return view
    }

    func updateNSView(_ nsView: DiffContainerView, context: Context) {
        nsView.update(
            chunks: viewModel.chunks,
            diffMode: viewModel.diffMode,
            isDark: isDark,
            language: viewModel.language,
            fileKey: viewModel.displayedPath,
            revertStates: viewModel.revertStates,
            onRevertBlock: { [weak viewModel] keys, removedLines, addedLines, contextBefore, contextAfter in
                viewModel?.revertBlock(
                    keys: keys,
                    removedLines: removedLines,
                    addedLines: addedLines,
                    contextBefore: contextBefore,
                    contextAfter: contextAfter
                )
            }
        )
    }
}

// MARK: - Diff Minimap View (Scrollbar with Changes Overview)
final class DiffMinimapView: NSView {
    weak var scrollView: NSScrollView?
    weak var canvasView: DiffCanvasView?

    var isDark: Bool = false

    private var isDraggingThumb: Bool = false
    private var dragStartY: CGFloat = 0
    private var dragStartScrollY: CGFloat = 0
    private var isHovered: Bool = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    var thumbMetrics: (rect: NSRect, maxScrollY: CGFloat, docHeight: CGFloat, viewportHeight: CGFloat) {
        let defaultMetrics = (rect: NSRect(x: 2, y: 0, width: max(0, bounds.width - 4), height: bounds.height),
                              maxScrollY: CGFloat(0),
                              docHeight: CGFloat(1),
                              viewportHeight: CGFloat(1))
        guard let scrollView = scrollView else { return defaultMetrics }

        let docH = max(canvasView?.bounds.height ?? scrollView.documentView?.bounds.height ?? 0, 1)
        let viewportH = max(scrollView.contentSize.height, 1)
        let maxScroll = max(0, docH - viewportH)
        let scrollY = scrollView.contentView.bounds.origin.y

        guard bounds.height > 0, bounds.width > 4 else { return defaultMetrics }

        if maxScroll <= 0 {
            let r = NSRect(x: 2, y: 0, width: bounds.width - 4, height: bounds.height)
            return (rect: r, maxScrollY: 0, docHeight: docH, viewportHeight: viewportH)
        }

        let scrollRatio = max(0, min(1.0, scrollY / maxScroll))
        let minThumbH: CGFloat = 26
        let rawThumbH = (viewportH / docH) * bounds.height
        let thumbH = max(minThumbH, min(bounds.height, rawThumbH))
        let availableTrack = bounds.height - thumbH
        let thumbY = availableTrack * scrollRatio

        let r = NSRect(x: 2, y: thumbY, width: bounds.width - 4, height: thumbH)
        return (rect: r, maxScrollY: maxScroll, docHeight: docH, viewportHeight: viewportH)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        toolTip = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.height > 0, let canvasView = canvasView, canvasView.totalHeight > 0 else {
            toolTip = nil
            return
        }

        let ratio = max(0, min(1.0, point.y / bounds.height))
        let targetDocY = ratio * canvasView.totalHeight
        guard let item = canvasView.item(at: targetDocY) else {
            toolTip = nil
            return
        }

        switch item {
        case .unifiedHeader(let text, _, _), .sideBySideHeader(let text, _, _):
            toolTip = text

        case .unifiedLine(let line, _, _, _):
            if line.type == .added {
                let num = line.newLineNumber.map { "line \($0)" } ?? "added"
                toolTip = "Added (\(num))"
            } else if line.type == .deleted {
                let num = line.oldLineNumber.map { "line \($0)" } ?? "deleted"
                toolTip = "Deleted (\(num))"
            } else if let num = line.newLineNumber ?? line.oldLineNumber {
                toolTip = "Line \(num)"
            } else {
                toolTip = nil
            }

        case .sideBySideRow(let row, _, _, _, _):
            let isDeleted = row.left?.type == .deleted
            let isAdded = row.right?.type == .added

            if isDeleted && isAdded {
                let oldStr = row.left?.oldLineNumber.map { "-\($0)" } ?? "-"
                let newStr = row.right?.newLineNumber.map { "+\($0)" } ?? "+"
                toolTip = "Modified (\(oldStr), \(newStr))"
            } else if isDeleted {
                let num = row.left?.oldLineNumber.map { "line \($0)" } ?? "deleted"
                toolTip = "Deleted (\(num))"
            } else if isAdded {
                let num = row.right?.newLineNumber.map { "line \($0)" } ?? "added"
                toolTip = "Added (\(num))"
            } else if let num = row.right?.newLineNumber ?? row.left?.oldLineNumber {
                toolTip = "Line \(num)"
            } else {
                toolTip = nil
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let metrics = thumbMetrics

        if metrics.rect.contains(point) {
            isDraggingThumb = true
            dragStartY = point.y
            dragStartScrollY = scrollView?.contentView.bounds.origin.y ?? 0
        } else {
            isDraggingThumb = true
            let targetScrollY = scrollYForMinimapY(point.y, metrics: metrics)
            scrollTo(y: targetScrollY)
            dragStartY = point.y
            dragStartScrollY = scrollView?.contentView.bounds.origin.y ?? 0
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingThumb else { return }
        let point = convert(event.locationInWindow, from: nil)
        let metrics = thumbMetrics
        guard metrics.maxScrollY > 0 else { return }

        let availableTrack = max(1, bounds.height - metrics.rect.height)
        let deltaY = point.y - dragStartY
        let scrollDelta = (deltaY / availableTrack) * metrics.maxScrollY
        let targetScrollY = dragStartScrollY + scrollDelta
        scrollTo(y: targetScrollY)
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingThumb = false
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        scrollView?.scrollWheel(with: event)
    }

    private func scrollYForMinimapY(_ minimapY: CGFloat, metrics: (rect: NSRect, maxScrollY: CGFloat, docHeight: CGFloat, viewportHeight: CGFloat)) -> CGFloat {
        guard bounds.height > 0, metrics.maxScrollY > 0 else { return 0 }
        let availableTrack = max(1, bounds.height - metrics.rect.height)
        let targetThumbY = minimapY - (metrics.rect.height / 2)
        let ratio = max(0, min(1.0, targetThumbY / availableTrack))
        return ratio * metrics.maxScrollY
    }

    private func scrollTo(y: CGFloat) {
        guard let scrollView = scrollView else { return }
        let docH = max(canvasView?.bounds.height ?? scrollView.documentView?.bounds.height ?? 0, 1)
        let viewH = scrollView.contentSize.height
        let maxScroll = max(0, docH - viewH)
        let clampedY = max(0, min(maxScroll, y))

        let clipView = scrollView.contentView
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: clampedY))
        scrollView.reflectScrolledClipView(clipView)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current != nil else { return }
        let clipRect = dirtyRect.intersection(bounds)
        guard !clipRect.isNull, bounds.width > 0, bounds.height > 0 else { return }

        // 1. Background
        let bgColor = isDark
            ? NSColor(white: 0.11, alpha: 0.95)
            : NSColor(white: 0.97, alpha: 0.95)
        bgColor.setFill()
        clipRect.fill()

        // 2. Left Divider Line
        let sepColor = isDark
            ? NSColor.separatorColor.withAlphaComponent(0.3)
            : NSColor.separatorColor.withAlphaComponent(0.25)
        sepColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        guard let canvasView = canvasView, !canvasView.items.isEmpty, canvasView.totalHeight > 0 else { return }

        let totalH = canvasView.totalHeight
        let h = bounds.height
        let w = bounds.width
        let trackW: CGFloat = 4.5
        let trackX = w - trackW - 1.0

        // 3. Draw Diff Markers & Micro-lines
        for item in canvasView.items {
            let y = (item.y / totalH) * h
            let rawItemH = (item.height / totalH) * h
            let markerH = max(2.5, rawItemH)

            if y + markerH < clipRect.minY || y > clipRect.maxY {
                continue
            }

            switch item {
            case .unifiedHeader, .sideBySideHeader:
                let headerColor = isDark
                    ? NSColor(red: 0.20, green: 0.35, blue: 0.55, alpha: 0.6)
                    : NSColor(red: 0.30, green: 0.50, blue: 0.80, alpha: 0.5)
                headerColor.setFill()
                NSRect(x: 1, y: y, width: w - 1, height: max(1.5, markerH * 0.7)).fill()

            case .unifiedLine(let line, _, _, _):
                if line.type == .deleted {
                    // Removed Line: Full-width red highlight band
                    NSColor.systemRed.withAlphaComponent(0.26).setFill()
                    NSRect(x: 1, y: y, width: w - 1, height: markerH).fill()

                    // Right change rail indicator
                    NSColor.systemRed.setFill()
                    NSRect(x: trackX, y: y, width: trackW, height: markerH).fill()

                    // Left accent tick
                    NSRect(x: 1, y: y, width: 2.5, height: markerH).fill()

                    // Red micro-line
                    drawMicroLine(content: line.text, y: y, h: markerH, color: NSColor.systemRed.withAlphaComponent(0.9))
                } else if line.type == .added {
                    // Added Line: Full-width green highlight band
                    NSColor.systemGreen.withAlphaComponent(0.22).setFill()
                    NSRect(x: 1, y: y, width: w - 1, height: markerH).fill()

                    // Right change rail indicator
                    NSColor.systemGreen.setFill()
                    NSRect(x: trackX, y: y, width: trackW, height: markerH).fill()

                    // Left accent tick
                    NSRect(x: 1, y: y, width: 2.5, height: markerH).fill()

                    // Green micro-line
                    drawMicroLine(content: line.text, y: y, h: markerH, color: NSColor.systemGreen.withAlphaComponent(0.95))
                } else {
                    // Normal code micro-line
                    let codeColor = isDark
                        ? NSColor(white: 0.50, alpha: 0.45)
                        : NSColor(white: 0.45, alpha: 0.40)
                    drawMicroLine(content: line.text, y: y, h: markerH, color: codeColor)
                }

            case .sideBySideRow(let row, _, _, _, _):
                let isDeleted = row.left?.type == .deleted
                let isAdded = row.right?.type == .added

                if isDeleted && isAdded {
                    let halfW = (w - 1) / 2
                    NSColor.systemRed.withAlphaComponent(0.24).setFill()
                    NSRect(x: 1, y: y, width: halfW, height: markerH).fill()

                    NSColor.systemGreen.withAlphaComponent(0.20).setFill()
                    NSRect(x: 1 + halfW, y: y, width: halfW, height: markerH).fill()

                    NSColor.systemRed.setFill()
                    NSRect(x: 1, y: y, width: 2.5, height: markerH).fill()

                    NSColor.systemGreen.setFill()
                    NSRect(x: trackX, y: y, width: trackW, height: markerH).fill()

                    let text = row.right?.text ?? row.left?.text ?? ""
                    drawMicroLine(content: text, y: y, h: markerH, color: NSColor.systemGreen.withAlphaComponent(0.95))
                } else if isDeleted {
                    NSColor.systemRed.withAlphaComponent(0.26).setFill()
                    NSRect(x: 1, y: y, width: w - 1, height: markerH).fill()

                    NSColor.systemRed.setFill()
                    NSRect(x: trackX, y: y, width: trackW, height: markerH).fill()
                    NSRect(x: 1, y: y, width: 2.5, height: markerH).fill()

                    let text = row.left?.text ?? ""
                    drawMicroLine(content: text, y: y, h: markerH, color: NSColor.systemRed.withAlphaComponent(0.9))
                } else if isAdded {
                    NSColor.systemGreen.withAlphaComponent(0.22).setFill()
                    NSRect(x: 1, y: y, width: w - 1, height: markerH).fill()

                    NSColor.systemGreen.setFill()
                    NSRect(x: trackX, y: y, width: trackW, height: markerH).fill()
                    NSRect(x: 1, y: y, width: 2.5, height: markerH).fill()

                    let text = row.right?.text ?? ""
                    drawMicroLine(content: text, y: y, h: markerH, color: NSColor.systemGreen.withAlphaComponent(0.95))
                } else {
                    let codeColor = isDark
                        ? NSColor(white: 0.50, alpha: 0.45)
                        : NSColor(white: 0.45, alpha: 0.40)
                    let text = row.right?.text ?? row.left?.text ?? ""
                    drawMicroLine(content: text, y: y, h: markerH, color: codeColor)
                }
            }
        }

        // 4. Draw Viewport Thumb
        let metrics = thumbMetrics
        let thumbR = metrics.rect

        let thumbFillColor: NSColor
        let thumbBorderColor: NSColor

        if isDraggingThumb {
            thumbFillColor = NSColor.controlAccentColor.withAlphaComponent(0.22)
            thumbBorderColor = NSColor.controlAccentColor.withAlphaComponent(0.55)
        } else if isHovered {
            thumbFillColor = isDark ? NSColor(white: 1.0, alpha: 0.16) : NSColor(white: 0.0, alpha: 0.13)
            thumbBorderColor = isDark ? NSColor(white: 1.0, alpha: 0.35) : NSColor(white: 0.0, alpha: 0.28)
        } else {
            thumbFillColor = isDark ? NSColor(white: 1.0, alpha: 0.10) : NSColor(white: 0.0, alpha: 0.08)
            thumbBorderColor = isDark ? NSColor(white: 1.0, alpha: 0.22) : NSColor(white: 0.0, alpha: 0.18)
        }

        let thumbPath = NSBezierPath(roundedRect: thumbR, xRadius: 4, yRadius: 4)
        thumbFillColor.setFill()
        thumbPath.fill()

        thumbBorderColor.setStroke()
        thumbPath.lineWidth = 1.0
        thumbPath.stroke()
    }

    private func drawMicroLine(content: String, y: CGFloat, h: CGFloat, color: NSColor) {
        guard !content.isEmpty else { return }

        var indentCount = 0
        for ch in content {
            if ch == " " {
                indentCount += 1
            } else if ch == "\t" {
                indentCount += 4
            } else {
                break
            }
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let startX: CGFloat = 6.0 + min(CGFloat(indentCount) * 1.4, bounds.width * 0.42)
        let maxAvailableW = max(2.0, (bounds.width - 12.0) - startX)
        let lineW = min(maxAvailableW, max(3.0, CGFloat(trimmed.count) * 0.55))
        let microH = min(1.2, h)
        let microY = y + max(0, (h - microH) / 2)

        color.setFill()
        NSRect(x: startX, y: microY, width: lineW, height: microH).fill()
    }
}

// MARK: - Diff Container View
final class DiffContainerView: NSView {
    let scrollView: NSScrollView
    let canvasView: DiffCanvasView
    let minimapView: DiffMinimapView
    let minimapWidth: CGFloat = 78

    private var currentMode: DiffMode = .sideBySide
    private var lastFileKey: String?
    private var chunks: [DiffChunk] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        return window?.makeFirstResponder(canvasView) ?? false
    }

    init() {
        self.scrollView = NSScrollView()
        self.canvasView = DiffCanvasView()
        self.minimapView = DiffMinimapView()

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        scrollView.wantsLayer = true
        canvasView.wantsLayer = true
        minimapView.wantsLayer = true
        minimapView.layer?.masksToBounds = true

        minimapView.scrollView = scrollView
        minimapView.canvasView = canvasView

        scrollView.documentView = canvasView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        addSubview(scrollView)
        addSubview(minimapView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onScrollViewDidScroll(_ notification: Notification) {
        if !minimapView.isHidden {
            minimapView.needsDisplay = true
        }
    }

    func checkRequiresScrollbar(availableHeight: CGFloat) -> Bool {
        guard availableHeight > 0, !chunks.isEmpty, canvasView.totalHeight > 0 else {
            return false
        }
        return canvasView.totalHeight > availableHeight
    }

    override func layout() {
        super.layout()
        let totalBounds = bounds
        guard totalBounds.width > 0, totalBounds.height > 0 else { return }

        let availableH = totalBounds.height

        // First pass: try layout without minimap scrollbar
        var scrollW = totalBounds.width
        var colW = (currentMode == .sideBySide) ? max(100, (scrollW - 1) / 2) : scrollW
        canvasView.columnWidth = colW
        canvasView.relayout(width: scrollW)

        let requiresScrollbar = checkRequiresScrollbar(availableHeight: availableH)
        if requiresScrollbar {
            scrollW = max(0, totalBounds.width - minimapWidth)
            colW = (currentMode == .sideBySide) ? max(100, (scrollW - 1) / 2) : scrollW
            canvasView.columnWidth = colW
            canvasView.relayout(width: scrollW)
        }

        scrollView.frame = NSRect(x: 0, y: 0, width: scrollW, height: availableH)

        if requiresScrollbar {
            minimapView.frame = NSRect(x: totalBounds.width - minimapWidth, y: 0, width: minimapWidth, height: totalBounds.height)
            minimapView.isHidden = false
        } else {
            minimapView.frame = NSRect(x: totalBounds.width, y: 0, width: 0, height: totalBounds.height)
            minimapView.isHidden = true
            if scrollView.contentView.bounds.origin.y > 0 {
                scrollView.contentView.setBoundsOrigin(NSPoint(x: scrollView.contentView.bounds.origin.x, y: 0))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        let canvasH = max(availableH, canvasView.totalHeight)
        let newFrame = NSRect(x: 0, y: 0, width: scrollW, height: canvasH)
        if abs(canvasView.frame.width - newFrame.width) > 0.5 || abs(canvasView.frame.height - newFrame.height) > 0.5 {
            canvasView.frame = newFrame
        }
        canvasView.needsDisplay = true

        if !minimapView.isHidden {
            minimapView.needsDisplay = true
        }
    }

    func update(
        chunks: [DiffChunk],
        diffMode: DiffMode,
        isDark: Bool,
        language: SyntaxLanguage = .plain,
        fileKey: String = "",
        revertStates: [String: BlockRevertState] = [:],
        onRevertBlock: (([String], [String], [String], [String], [String]) -> Void)? = nil
    ) {
        let savedScrollOrigin = scrollView.contentView.bounds.origin

        self.chunks = chunks
        self.currentMode = diffMode

        let app = NSAppearance(named: isDark ? .darkAqua : .aqua)
        self.appearance = app
        canvasView.appearance = app

        canvasView.revertStates = revertStates
        canvasView.onRevertBlock = onRevertBlock

        let initialW = bounds.width > 0 ? bounds.width : 800
        let colW = max(100, (initialW - 1) / 2)
        canvasView.columnWidth = colW
        canvasView.update(chunks: chunks, diffMode: diffMode, isDark: isDark, language: language, width: initialW)

        minimapView.appearance = app
        minimapView.isDark = isDark

        needsLayout = true
        layoutSubtreeIfNeeded()
        updateCanvasFrame()

        if fileKey != lastFileKey {
            lastFileKey = fileKey
            scrollView.contentView.setBoundsOrigin(.zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            let maxScrollY = max(0, canvasView.totalHeight - scrollView.contentView.bounds.height)
            let targetY = min(max(0, savedScrollOrigin.y), maxScrollY)
            let targetOrigin = NSPoint(x: savedScrollOrigin.x, y: targetY)
            if scrollView.contentView.bounds.origin != targetOrigin {
                scrollView.contentView.setBoundsOrigin(targetOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        if !minimapView.isHidden {
            minimapView.needsDisplay = true
        }
    }

    func updateCanvasFrame() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let availableH = bounds.height
        let requiresScrollbar = !minimapView.isHidden
        let scrollW = requiresScrollbar ? max(0, bounds.width - minimapWidth) : bounds.width
        let colW = (currentMode == .sideBySide) ? max(100, (scrollW - 1) / 2) : scrollW

        canvasView.columnWidth = colW
        canvasView.relayout(width: scrollW)

        let canvasH = max(availableH, canvasView.totalHeight)
        let newFrame = NSRect(x: 0, y: 0, width: scrollW, height: canvasH)
        if abs(canvasView.frame.width - newFrame.width) > 0.5 || abs(canvasView.frame.height - newFrame.height) > 0.5 {
            canvasView.frame = newFrame
        }
        canvasView.needsDisplay = true
    }
}

// MARK: - Flattened Row Model
enum DiffRowItem {
    case unifiedHeader(text: String, y: CGFloat, height: CGFloat)
    case unifiedLine(line: DiffLine, attributedText: NSAttributedString, y: CGFloat, height: CGFloat)
    case sideBySideHeader(text: String, y: CGFloat, height: CGFloat)
    case sideBySideRow(row: SideBySideRow, leftAttributedText: NSAttributedString?, rightAttributedText: NSAttributedString?, y: CGFloat, height: CGFloat)

    var y: CGFloat {
        switch self {
        case .unifiedHeader(_, let y, _): return y
        case .unifiedLine(_, _, let y, _): return y
        case .sideBySideHeader(_, let y, _): return y
        case .sideBySideRow(_, _, _, let y, _): return y
        }
    }

    var height: CGFloat {
        switch self {
        case .unifiedHeader(_, _, let h): return h
        case .unifiedLine(_, _, _, let h): return h
        case .sideBySideHeader(_, _, let h): return h
        case .sideBySideRow(_, _, _, _, let h): return h
        }
    }
}

// MARK: - Diff Text Selection Model
public enum DiffColumnSide: Equatable {
    case unified
    case left
    case right
}

public struct DiffTextPosition: Equatable, Comparable {
    public var itemIndex: Int
    public var side: DiffColumnSide
    public var charIndex: Int

    public init(itemIndex: Int, side: DiffColumnSide, charIndex: Int) {
        self.itemIndex = itemIndex
        self.side = side
        self.charIndex = charIndex
    }

    public static func < (lhs: DiffTextPosition, rhs: DiffTextPosition) -> Bool {
        if lhs.itemIndex != rhs.itemIndex {
            return lhs.itemIndex < rhs.itemIndex
        }
        return lhs.charIndex < rhs.charIndex
    }
}

// MARK: - Direct Hardware-Accelerated Diff Canvas View
final class DiffCanvasView: NSView, NSUserInterfaceValidations {
    static let lineHeight: CGFloat = 20.0
    static let headerHeight: CGFloat = 24.0

    var items: [DiffRowItem] = []
    var isDark: Bool = false
    var diffMode: DiffMode = .sideBySide
    var language: SyntaxLanguage = .plain
    var columnWidth: CGFloat = 200
    var totalHeight: CGFloat = 0
    var revertStates: [String: BlockRevertState] = [:]
    var onRevertBlock: (([String], [String], [String], [String], [String]) -> Void)?
    var hoveredBlockRange: Range<Int>?

    public var selectionAnchor: DiffTextPosition?
    public var selectionCurrent: DiffTextPosition?

    public var normalizedSelection: (start: DiffTextPosition, end: DiffTextPosition)? {
        guard let anchor = selectionAnchor, let current = selectionCurrent else { return nil }
        if anchor == current { return nil }
        if anchor <= current {
            return (anchor, current)
        } else {
            return (current, anchor)
        }
    }

    public var hasSelection: Bool {
        normalizedSelection != nil
    }

    private var isHoveringIcon: Bool = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func isChangeItem(at index: Int) -> Bool {
        guard index >= 0, index < items.count else { return false }
        switch items[index] {
        case .unifiedLine(let line, _, _, _):
            return line.type != .unchanged
        case .sideBySideRow(let row, _, _, _, _):
            return row.left?.type == .deleted || row.right?.type == .added
        default:
            return false
        }
    }

    func isFirstLineOfBlock(at index: Int) -> Bool {
        guard isChangeItem(at: index) else { return false }
        if index == 0 { return true }
        return !isChangeItem(at: index - 1)
    }

    func calculateBlockRange(at index: Int) -> Range<Int> {
        guard isChangeItem(at: index) else { return index..<index }
        var start = index
        while start > 0 && isChangeItem(at: start - 1) {
            start -= 1
        }
        var end = index + 1
        while end < items.count && isChangeItem(at: end) {
            end += 1
        }
        return start..<end
    }

    func extractBlockDetails(for range: Range<Int>) -> (keys: [String], removedLines: [String], addedLines: [String], contextBefore: [String], contextAfter: [String]) {
        var keys: [String] = []
        var removedLines: [String] = []
        var addedLines: [String] = []

        for k in range {
            switch items[k] {
            case .unifiedLine(let line, _, _, _):
                keys.append(line.id)
                if line.type == .deleted {
                    removedLines.append(line.text)
                } else if line.type == .added {
                    addedLines.append(line.text)
                }
            case .sideBySideRow(let row, _, _, _, _):
                keys.append(row.id)
                if let left = row.left {
                    keys.append(left.id)
                    if left.type == .deleted {
                        removedLines.append(left.text)
                    }
                }
                if let right = row.right {
                    keys.append(right.id)
                    if right.type == .added {
                        addedLines.append(right.text)
                    }
                }
            default:
                break
            }
        }

        var contextBefore: [String] = []
        var prevIdx = range.lowerBound - 1
        while prevIdx >= 0 && contextBefore.count < 5 {
            switch items[prevIdx] {
            case .unifiedLine(let line, _, _, _):
                if line.type == .unchanged {
                    contextBefore.insert(line.text, at: 0)
                } else {
                    prevIdx = -1
                }
            case .sideBySideRow(let row, _, _, _, _):
                if let text = row.right?.text ?? row.left?.text, row.left?.type == .unchanged {
                    contextBefore.insert(text, at: 0)
                } else {
                    prevIdx = -1
                }
            default:
                prevIdx = -1
            }
            prevIdx -= 1
        }

        var contextAfter: [String] = []
        var nextIdx = range.upperBound
        while nextIdx < items.count && contextAfter.count < 5 {
            switch items[nextIdx] {
            case .unifiedLine(let line, _, _, _):
                if line.type == .unchanged {
                    contextAfter.append(line.text)
                } else {
                    nextIdx = items.count
                }
            case .sideBySideRow(let row, _, _, _, _):
                if let text = row.right?.text ?? row.left?.text, row.left?.type == .unchanged {
                    contextAfter.append(text)
                } else {
                    nextIdx = items.count
                }
            default:
                nextIdx = items.count
            }
            nextIdx += 1
        }

        return (keys, removedLines, addedLines, contextBefore, contextAfter)
    }

    private func itemIndex(at y: CGFloat) -> Int? {
        guard !items.isEmpty, y >= 0 else { return nil }
        var low = 0
        var high = items.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let it = items[mid]
            if y < it.y {
                high = mid - 1
            } else if y >= it.y + it.height {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    private func isPointInIconArea(point: NSPoint, item: DiffRowItem) -> Bool {
        switch item {
        case .unifiedLine:
            return point.x >= 0 && point.x <= 20
        case .sideBySideRow(let row, _, _, _, _):
            let inLeftIcon = (row.left != nil) && (point.x >= 0 && point.x <= 20)
            let inRightIcon = (row.right != nil) && (point.x >= columnWidth + 1 && point.x <= columnWidth + 21)
            return inLeftIcon || inRightIcon
        default:
            return false
        }
    }

    private func revertState(for index: Int) -> BlockRevertState {
        guard index >= 0, index < items.count else { return .normal }
        switch items[index] {
        case .unifiedLine(let line, _, _, _):
            return revertStates[line.id] ?? .normal
        case .sideBySideRow(let row, _, _, _, _):
            return revertStates[row.id] ?? revertStates[row.left?.id ?? ""] ?? revertStates[row.right?.id ?? ""] ?? .normal
        default:
            return .normal
        }
    }

    private func drawRevertIcon(state: BlockRevertState, in rect: NSRect, isHovered: Bool, lineType: DiffLineType) {
        let symbolName: String
        let iconColor: NSColor
        switch state {
        case .success:
            symbolName = "checkmark.circle.fill"
            iconColor = .systemGreen
        case .error:
            symbolName = "exclamationmark.triangle.fill"
            iconColor = .systemRed
        case .normal:
            symbolName = "arrow.uturn.backward"
            if isHovered {
                iconColor = .controlAccentColor
            } else if lineType == .deleted {
                iconColor = NSColor.systemRed.withAlphaComponent(0.85)
            } else {
                iconColor = NSColor.systemGreen.withAlphaComponent(0.85)
            }
        }

        let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: iconColor))
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Revert")?.withSymbolConfiguration(config) {
            img.draw(in: rect)
        }
    }

    private func isPointInTextArea(point: NSPoint, item: DiffRowItem) -> Bool {
        switch item {
        case .unifiedLine:
            return point.x >= 120 && point.x <= bounds.width
        case .sideBySideRow(let row, _, _, _, _):
            let inLeftText = (row.left != nil) && (point.x >= 70 && point.x <= columnWidth)
            let inRightText = (row.right != nil) && (point.x >= columnWidth + 1 + 70 && point.x <= bounds.width)
            return inLeftText || inRightText
        default:
            return false
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let idx = itemIndex(at: point.y) else {
            clearHover()
            return
        }

        let it = items[idx]
        let inIcon = isPointInIconArea(point: point, item: it)
        let isFirst = isFirstLineOfBlock(at: idx)

        if inIcon && isFirst {
            isHoveringIcon = true
            let blockRange = calculateBlockRange(at: idx)
            if hoveredBlockRange != blockRange {
                hoveredBlockRange = blockRange
                needsDisplay = true
            }

            let state = revertState(for: idx)
            switch state {
            case .normal:
                toolTip = "Revert block against working directory"
            case .success:
                toolTip = "Block reverted successfully in working directory"
            case .error(let msg):
                toolTip = "Revert failed: \(msg)"
            }
            NSCursor.pointingHand.set()
        } else {
            clearHover()
            if isPointInTextArea(point: point, item: it) {
                NSCursor.iBeam.set()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    private func clearHover() {
        if hoveredBlockRange != nil || isHoveringIcon {
            hoveredBlockRange = nil
            isHoveringIcon = false
            needsDisplay = true
        }
        toolTip = nil
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let idx = itemIndex(at: point.y) {
            let it = items[idx]
            if isPointInIconArea(point: point, item: it) && isFirstLineOfBlock(at: idx) {
                let range = calculateBlockRange(at: idx)
                let details = extractBlockDetails(for: range)
                onRevertBlock?(details.keys, details.removedLines, details.addedLines, details.contextBefore, details.contextAfter)
                needsDisplay = true
                return
            }
        }

        window?.makeFirstResponder(self)

        guard let pos = textPosition(at: point) else {
            super.mouseDown(with: event)
            return
        }

        if event.clickCount == 2 {
            let (rawText, _, _) = textAndRect(for: pos.itemIndex, side: pos.side)
            selectionAnchor = DiffTextPosition(itemIndex: pos.itemIndex, side: pos.side, charIndex: 0)
            selectionCurrent = DiffTextPosition(itemIndex: pos.itemIndex, side: pos.side, charIndex: rawText.count)
            needsDisplay = true
            return
        } else if event.clickCount == 3 {
            selectAll(nil)
            return
        }

        selectionAnchor = pos
        selectionCurrent = pos
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let anchor = selectionAnchor, let pos = textPosition(at: point) {
            let constrainedPos = DiffTextPosition(itemIndex: pos.itemIndex, side: anchor.side, charIndex: pos.charIndex)
            selectionCurrent = constrainedPos
            autoscroll(with: event)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let anchor = selectionAnchor, let current = selectionCurrent, anchor == current {
            selectionAnchor = nil
            selectionCurrent = nil
            needsDisplay = true
        }
    }

    public func textAndRect(for index: Int, side: DiffColumnSide) -> (text: String, attr: NSAttributedString?, rect: NSRect) {
        guard index >= 0, index < items.count else {
            return ("", nil, .zero)
        }
        let totalW = bounds.width > 0 ? bounds.width : 800
        let colW = columnWidth > 0 ? columnWidth : max(100, (totalW - 1) / 2)

        switch items[index] {
        case .unifiedHeader(let text, let y, let h):
            let rect = NSRect(x: 12, y: y + 3.5, width: max(0, totalW - 24), height: max(16.0, h - 4.0))
            return (text, nil, rect)

        case .unifiedLine(let line, let attributedText, let y, let h):
            let rect = NSRect(x: 126, y: y + 2.5, width: max(0, totalW - 130), height: max(16.0, h - 4.0))
            return (line.text, attributedText, rect)

        case .sideBySideHeader(let text, let y, let h):
            let rect = NSRect(x: 12, y: y + 3.5, width: max(0, totalW - 24), height: max(16.0, h - 4.0))
            return (text, nil, rect)

        case .sideBySideRow(let row, let leftAttributedText, let rightAttributedText, let y, let h):
            if side == .left {
                let rect = NSRect(x: 78, y: y + 2.5, width: max(0, colW - 82), height: max(16.0, h - 4.0))
                if let left = row.left {
                    return (left.text, leftAttributedText, rect)
                } else {
                    return ("", nil, rect)
                }
            } else {
                let rx = colW + 1
                let rect = NSRect(x: rx + 78, y: y + 2.5, width: max(0, colW - 82), height: max(16.0, h - 4.0))
                if let right = row.right {
                    return (right.text, rightAttributedText, rect)
                } else {
                    return ("", nil, rect)
                }
            }
        }
    }

    public func textPosition(at point: NSPoint) -> DiffTextPosition? {
        guard !items.isEmpty else { return nil }

        let side: DiffColumnSide
        if diffMode == .unified {
            side = .unified
        } else {
            side = (point.x <= columnWidth) ? .left : .right
        }

        let itemIdx: Int
        if point.y < 0 {
            itemIdx = 0
        } else if point.y >= totalHeight {
            itemIdx = max(0, items.count - 1)
        } else {
            itemIdx = itemIndex(at: point.y) ?? 0
        }

        let (text, attr, rect) = textAndRect(for: itemIdx, side: side)
        let textLen = text.count
        if textLen == 0 {
            return DiffTextPosition(itemIndex: itemIdx, side: side, charIndex: 0)
        }

        if point.x <= rect.minX {
            return DiffTextPosition(itemIndex: itemIdx, side: side, charIndex: 0)
        }

        let charIndex: Int
        if let attr = attr, attr.length > 0 {
            let ctLine = CTLineCreateWithAttributedString(attr as CFAttributedString)
            let localX = point.x - rect.minX
            let idx = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localX, y: 0))
            charIndex = max(0, min(textLen, idx))
        } else {
            let charWidth: CGFloat = (" " as NSString).size(withAttributes: [.font: monoFont]).width
            let approx = Int(round((point.x - rect.minX) / charWidth))
            charIndex = max(0, min(textLen, approx))
        }

        return DiffTextPosition(itemIndex: itemIdx, side: side, charIndex: charIndex)
    }

    private func selectionRects(for index: Int, side: DiffColumnSide, charStart: Int, charEnd: Int) -> [NSRect] {
        guard charStart < charEnd else { return [] }
        let (rawText, attr, rect) = textAndRect(for: index, side: side)
        let textLen = rawText.count
        guard textLen > 0, rect.width > 0 else { return [] }

        let clampedStart = max(0, min(textLen, charStart))
        let clampedEnd = max(0, min(textLen, charEnd))
        guard clampedStart < clampedEnd else { return [] }

        let startOffset: CGFloat
        let endOffset: CGFloat

        if let attr = attr, attr.length > 0 {
            let ctLine = CTLineCreateWithAttributedString(attr as CFAttributedString)
            startOffset = CTLineGetOffsetForStringIndex(ctLine, clampedStart, nil)
            endOffset = CTLineGetOffsetForStringIndex(ctLine, clampedEnd, nil)
        } else {
            let charWidth: CGFloat = (" " as NSString).size(withAttributes: [.font: monoFont]).width
            startOffset = CGFloat(clampedStart) * charWidth
            endOffset = CGFloat(clampedEnd) * charWidth
        }

        let selX = rect.minX + min(startOffset, endOffset)
        let selW = max(2.0, abs(endOffset - startOffset))
        return [NSRect(x: selX, y: rect.minY, width: selW, height: rect.height)]
    }

    public func getSelectedText() -> String? {
        guard let (start, end) = normalizedSelection else { return nil }
        var resultLines: [String] = []

        for idx in start.itemIndex...end.itemIndex {
            guard idx < items.count else { continue }
            let (rawText, _, _) = textAndRect(for: idx, side: start.side)
            let len = rawText.count
            guard len > 0 else {
                if idx > start.itemIndex && idx < end.itemIndex {
                    resultLines.append("")
                }
                continue
            }

            let charStart: Int
            let charEnd: Int

            if idx == start.itemIndex && idx == end.itemIndex {
                charStart = max(0, min(len, start.charIndex))
                charEnd = max(0, min(len, end.charIndex))
            } else if idx == start.itemIndex {
                charStart = max(0, min(len, start.charIndex))
                charEnd = len
            } else if idx == end.itemIndex {
                charStart = 0
                charEnd = max(0, min(len, end.charIndex))
            } else {
                charStart = 0
                charEnd = len
            }

            if charStart < charEnd {
                let sIdx = rawText.index(rawText.startIndex, offsetBy: charStart)
                let eIdx = rawText.index(rawText.startIndex, offsetBy: charEnd)
                resultLines.append(String(rawText[sIdx..<eIdx]))
            } else if idx > start.itemIndex && idx < end.itemIndex {
                resultLines.append("")
            }
        }

        return resultLines.isEmpty ? nil : resultLines.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard let text = getSelectedText(), !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard !items.isEmpty else { return }
        let side: DiffColumnSide = (diffMode == .unified) ? .unified : .right
        let (lastText, _, _) = textAndRect(for: items.count - 1, side: side)
        selectionAnchor = DiffTextPosition(itemIndex: 0, side: side, charIndex: 0)
        selectionCurrent = DiffTextPosition(itemIndex: items.count - 1, side: side, charIndex: lastText.count)
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            if event.charactersIgnoringModifiers == "c" {
                copy(nil)
                return true
            }
            if event.charactersIgnoringModifiers == "a" {
                selectAll(nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return hasSelection
        }
        if item.action == #selector(selectAll(_:)) {
            return !items.isEmpty
        }
        return false
    }

    // Pre-allocated Fonts
    private let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let monoBoldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private let monoHeaderFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    // Pre-allocated ParagraphStyles
    private lazy var rightAlignStyle: NSMutableParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        return p
    }()

    private lazy var centerAlignStyle: NSMutableParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }()

    private lazy var wrappingStyle: NSMutableParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .left
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2.0
        return p
    }()

    private lazy var truncatingStyle: NSMutableParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .left
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    private lazy var clippingStyle: NSMutableParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .left
        p.lineBreakMode = .byClipping
        return p
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var addedBgColor: NSColor {
        isDark ? NSColor.systemGreen.withAlphaComponent(0.22) : NSColor.systemGreen.withAlphaComponent(0.12)
    }

    var addedTextColor: NSColor {
        isDark ? NSColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1.0) : NSColor(red: 0.08, green: 0.52, blue: 0.18, alpha: 1.0)
    }

    var deletedBgColor: NSColor {
        isDark ? NSColor.systemRed.withAlphaComponent(0.22) : NSColor.systemRed.withAlphaComponent(0.12)
    }

    var deletedTextColor: NSColor {
        isDark ? NSColor(red: 0.95, green: 0.45, blue: 0.45, alpha: 1.0) : NSColor(red: 0.82, green: 0.18, blue: 0.18, alpha: 1.0)
    }

    var separatorColor: NSColor {
        isDark ? NSColor.separatorColor.withAlphaComponent(0.4) : NSColor.separatorColor.withAlphaComponent(0.3)
    }

    var placeholderColor: NSColor {
        NSColor.separatorColor.withAlphaComponent(0.08)
    }

    var headerBgColor: NSColor {
        isDark
            ? NSColor(red: 0.13, green: 0.17, blue: 0.23, alpha: 1.0)
            : NSColor(red: 0.94, green: 0.96, blue: 0.99, alpha: 1.0)
    }

    var headerTextColor: NSColor {
        isDark
            ? NSColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1.0)
            : NSColor(red: 0.08, green: 0.40, blue: 0.84, alpha: 1.0)
    }

    var headerBorderColor: NSColor {
        isDark
            ? NSColor(red: 0.20, green: 0.26, blue: 0.35, alpha: 0.8)
            : NSColor(red: 0.82, green: 0.88, blue: 0.94, alpha: 0.9)
    }

    func calculateLineHeight(for attributedText: NSAttributedString?, availableWidth: CGFloat) -> CGFloat {
        guard let attr = attributedText, attr.length > 0 else {
            return Self.lineHeight
        }
        let w = max(20, availableWidth)
        if CGFloat(attr.length) * 6.5 <= w {
            return Self.lineHeight
        }
        let rect = attr.boundingRect(
            with: NSSize(width: w, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let measuredH = ceil(rect.height)
        if measuredH <= 16.0 {
            return Self.lineHeight
        }
        return max(Self.lineHeight, measuredH + 5.0)
    }

    private var lastLayoutWidth: CGFloat = -1

    func relayout(width: CGFloat) {
        guard width > 0 else { return }
        if abs(lastLayoutWidth - width) < 0.5 { return }
        lastLayoutWidth = width

        let totalW = width
        let colW = max(100, (totalW - 1) / 2)
        self.columnWidth = colW

        var currentY: CGFloat = 0
        var newItems: [DiffRowItem] = []
        newItems.reserveCapacity(items.count)

        for item in items {
            switch item {
            case .unifiedHeader(let text, _, _):
                newItems.append(.unifiedHeader(text: text, y: currentY, height: Self.headerHeight))
                currentY += Self.headerHeight

            case .unifiedLine(let line, let attr, _, _):
                let textW = max(20, totalW - 130)
                let h = calculateLineHeight(for: attr, availableWidth: textW)
                newItems.append(.unifiedLine(line: line, attributedText: attr, y: currentY, height: h))
                currentY += h

            case .sideBySideHeader(let text, _, _):
                newItems.append(.sideBySideHeader(text: text, y: currentY, height: Self.headerHeight))
                currentY += Self.headerHeight

            case .sideBySideRow(let row, let leftAttr, let rightAttr, _, _):
                let textW = max(20, colW - 82)
                let leftH = calculateLineHeight(for: leftAttr, availableWidth: textW)
                let rightH = calculateLineHeight(for: rightAttr, availableWidth: textW)
                let h = max(Self.lineHeight, leftH, rightH)
                newItems.append(.sideBySideRow(
                    row: row,
                    leftAttributedText: leftAttr,
                    rightAttributedText: rightAttr,
                    y: currentY,
                    height: h
                ))
                currentY += h
            }
        }

        self.items = newItems
        self.totalHeight = currentY
        needsDisplay = true
    }

    func update(chunks: [DiffChunk], diffMode: DiffMode, isDark: Bool, language: SyntaxLanguage = .plain, width: CGFloat? = nil) {
        self.selectionAnchor = nil
        self.selectionCurrent = nil
        self.diffMode = diffMode
        self.isDark = isDark
        self.language = language

        var rowItems: [DiffRowItem] = []

        if diffMode == .unified {
            for chunk in chunks {
                rowItems.append(.unifiedHeader(text: chunk.header, y: 0, height: Self.headerHeight))

                for line in chunk.lines {
                    let attr = highlightLine(
                        text: line.text,
                        type: line.type,
                        language: language,
                        isDark: isDark,
                        paragraphStyle: wrappingStyle
                    )
                    rowItems.append(.unifiedLine(line: line, attributedText: attr, y: 0, height: Self.lineHeight))
                }
            }
        } else {
            for chunk in chunks {
                rowItems.append(.sideBySideHeader(text: chunk.header, y: 0, height: Self.headerHeight))

                for row in chunk.sideBySideRows {
                    let leftAttr = row.left.map {
                        highlightLine(
                            text: $0.text,
                            type: $0.type,
                            language: language,
                            isDark: isDark,
                            paragraphStyle: wrappingStyle
                        )
                    }
                    let rightAttr = row.right.map {
                        highlightLine(
                            text: $0.text,
                            type: $0.type,
                            language: language,
                            isDark: isDark,
                            paragraphStyle: wrappingStyle
                        )
                    }
                    rowItems.append(.sideBySideRow(
                        row: row,
                        leftAttributedText: leftAttr,
                        rightAttributedText: rightAttr,
                        y: 0,
                        height: Self.lineHeight
                    ))
                }
            }
        }

        self.items = rowItems
        self.lastLayoutWidth = -1
        let effectiveW = width ?? (bounds.width > 0 ? bounds.width : 800)
        relayout(width: effectiveW)
    }

    private func highlightLine(
        text: String,
        type: DiffLineType,
        language: SyntaxLanguage,
        isDark: Bool,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        let clean = text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        let display = clean.isEmpty ? " " : clean

        let highlighted: NSAttributedString
        if language == .plain {
            let textColor: NSColor
            if type == .added {
                textColor = addedTextColor
            } else if type == .deleted {
                textColor = deletedTextColor
            } else {
                textColor = isDark ? NSColor.white : NSColor.labelColor
            }
            highlighted = NSAttributedString(
                string: display,
                attributes: [
                    .foregroundColor: textColor,
                    .font: monoFont
                ]
            )
        } else {
            highlighted = SyntaxHighlighter.shared.highlight(
                text: display,
                language: language,
                isDark: isDark,
                font: monoFont
            )
        }

        let mutable = NSMutableAttributedString(attributedString: highlighted)
        mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: mutable.length))
        return mutable
    }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current != nil else { return }
        let clipRect = dirtyRect.intersection(bounds)
        guard !clipRect.isNull, bounds.width > 0, bounds.height > 0 else { return }

        // Background
        let bgColor = isDark ? NSColor(white: 0.12, alpha: 1.0) : NSColor.textBackgroundColor
        bgColor.setFill()
        clipRect.fill()

        guard !items.isEmpty else { return }

        // Binary search for first visible item intersecting dirtyRect
        var low = 0
        var high = items.count - 1
        var startIndex = 0
        while low <= high {
            let mid = (low + high) / 2
            if items[mid].y + items[mid].height <= clipRect.minY {
                low = mid + 1
            } else {
                startIndex = mid
                high = mid - 1
            }
        }

        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.7),
            .paragraphStyle: rightAlignStyle
        ]
        let addSymbolAttrs: [NSAttributedString.Key: Any] = [
            .font: monoBoldFont,
            .foregroundColor: addedTextColor,
            .paragraphStyle: centerAlignStyle
        ]
        let delSymbolAttrs: [NSAttributedString.Key: Any] = [
            .font: monoBoldFont,
            .foregroundColor: deletedTextColor,
            .paragraphStyle: centerAlignStyle
        ]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: monoHeaderFont,
            .foregroundColor: headerTextColor
        ]

        let totalW = bounds.width
        let colW = columnWidth

        for i in startIndex..<items.count {
            let item = items[i]
            if item.y > clipRect.maxY { break }

            switch item {
            case .unifiedHeader(let text, let y, let h):
                let headerRect = NSRect(x: 0, y: y, width: totalW, height: h)
                if headerRect.intersects(clipRect) {
                    headerBgColor.setFill()
                    headerRect.fill()
                    headerBorderColor.setFill()
                    NSRect(x: 0, y: y, width: totalW, height: 1).fill()
                    NSRect(x: 0, y: y + h - 1, width: totalW, height: 1).fill()
                    if let (start, end) = normalizedSelection, i >= start.itemIndex && i <= end.itemIndex {
                        let len = text.count
                        let charStart = (i == start.itemIndex) ? start.charIndex : 0
                        let charEnd = (i == end.itemIndex) ? end.charIndex : len
                        for selRect in selectionRects(for: i, side: .unified, charStart: charStart, charEnd: charEnd) {
                            (isDark ? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45) : NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)).setFill()
                            selRect.fill()
                        }
                    }
                    (text as NSString).draw(at: NSPoint(x: 12, y: y + 3.5), withAttributes: headerAttrs)
                }

            case .unifiedLine(let line, let attributedText, let y, let h):
                let rowRect = NSRect(x: 0, y: y, width: totalW, height: h)
                guard rowRect.intersects(clipRect) else { continue }

                let isBlockHighlighted = hoveredBlockRange?.contains(i) == true

                if isBlockHighlighted {
                    (isDark ? NSColor.controlAccentColor.withAlphaComponent(0.24) : NSColor.controlAccentColor.withAlphaComponent(0.16)).setFill()
                    rowRect.fill()
                } else if line.type == .added {
                    addedBgColor.setFill()
                    rowRect.fill()
                } else if line.type == .deleted {
                    deletedBgColor.setFill()
                    rowRect.fill()
                }

                if isFirstLineOfBlock(at: i) {
                    let state = revertStates[line.id] ?? .normal
                    let iconRect = NSRect(x: 3.0, y: y + (h - 13.0) / 2.0, width: 13.0, height: 13.0)
                    let isThisIconHovered = (isBlockHighlighted && isHoveringIcon)
                    drawRevertIcon(state: state, in: iconRect, isHovered: isThisIconHovered, lineType: line.type)
                }

                if let old = line.oldLineNumber {
                    ("\(old)" as NSString).draw(in: NSRect(x: 20, y: y + 2.5, width: 40, height: 16), withAttributes: numAttrs)
                }
                if let new = line.newLineNumber {
                    ("\(new)" as NSString).draw(in: NSRect(x: 64, y: y + 2.5, width: 40, height: 16), withAttributes: numAttrs)
                }

                if line.type == .added {
                    ("+" as NSString).draw(in: NSRect(x: 108, y: y + 2.5, width: 14, height: 16), withAttributes: addSymbolAttrs)
                } else if line.type == .deleted {
                    ("-" as NSString).draw(in: NSRect(x: 108, y: y + 2.5, width: 14, height: 16), withAttributes: delSymbolAttrs)
                }

                if let (start, end) = normalizedSelection, i >= start.itemIndex && i <= end.itemIndex {
                    let len = line.text.count
                    let charStart = (i == start.itemIndex) ? start.charIndex : 0
                    let charEnd = (i == end.itemIndex) ? end.charIndex : len
                    for selRect in selectionRects(for: i, side: .unified, charStart: charStart, charEnd: charEnd) {
                        (isDark ? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45) : NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)).setFill()
                        selRect.fill()
                    }
                }

                attributedText.draw(
                    with: NSRect(x: 126, y: y + 2.5, width: max(0, totalW - 130), height: max(16.0, h - 4.0)),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )

            case .sideBySideHeader(let text, let y, let h):
                let headerRect = NSRect(x: 0, y: y, width: totalW, height: h)
                if headerRect.intersects(clipRect) {
                    headerBgColor.setFill()
                    headerRect.fill()
                    headerBorderColor.setFill()
                    NSRect(x: 0, y: y, width: totalW, height: 1).fill()
                    NSRect(x: 0, y: y + h - 1, width: totalW, height: 1).fill()
                    if let (start, end) = normalizedSelection, i >= start.itemIndex && i <= end.itemIndex {
                        let len = text.count
                        let charStart = (i == start.itemIndex) ? start.charIndex : 0
                        let charEnd = (i == end.itemIndex) ? end.charIndex : len
                        for selRect in selectionRects(for: i, side: start.side, charStart: charStart, charEnd: charEnd) {
                            (isDark ? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45) : NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)).setFill()
                            selRect.fill()
                        }
                    }
                    (text as NSString).draw(at: NSPoint(x: 12, y: y + 3.5), withAttributes: headerAttrs)
                }

            case .sideBySideRow(let row, let leftAttributedText, let rightAttributedText, let y, let h):
                let rowRect = NSRect(x: 0, y: y, width: totalW, height: h)
                guard rowRect.intersects(clipRect) else { continue }

                let isBlockHighlighted = hoveredBlockRange?.contains(i) == true

                if isBlockHighlighted {
                    (isDark ? NSColor.controlAccentColor.withAlphaComponent(0.24) : NSColor.controlAccentColor.withAlphaComponent(0.16)).setFill()
                    rowRect.fill()
                } else {
                    // Left cell
                    let leftRect = NSRect(x: 0, y: y, width: colW, height: h)
                    if let left = row.left {
                        if left.type == .deleted {
                            deletedBgColor.setFill()
                            leftRect.fill()
                        }
                    } else {
                        placeholderColor.setFill()
                        leftRect.fill()
                    }

                    // Center divider
                    separatorColor.setFill()
                    NSRect(x: colW, y: y, width: 1, height: h).fill()

                    // Right cell
                    let rightRect = NSRect(x: colW + 1, y: y, width: colW, height: h)
                    if let right = row.right {
                        if right.type == .added {
                            addedBgColor.setFill()
                            rightRect.fill()
                        }
                    } else {
                        placeholderColor.setFill()
                        rightRect.fill()
                    }
                }

                if isFirstLineOfBlock(at: i) {
                    let state = revertStates[row.id] ?? revertStates[row.left?.id ?? ""] ?? revertStates[row.right?.id ?? ""] ?? .normal
                    let isThisIconHovered = (isBlockHighlighted && isHoveringIcon)

                    if row.left != nil {
                        let leftIconRect = NSRect(x: 3.0, y: y + (h - 13.0) / 2.0, width: 13.0, height: 13.0)
                        drawRevertIcon(state: state, in: leftIconRect, isHovered: isThisIconHovered, lineType: row.left?.type ?? .unchanged)
                    }
                    if row.right != nil {
                        let rightIconRect = NSRect(x: colW + 1 + 3.0, y: y + (h - 13.0) / 2.0, width: 13.0, height: 13.0)
                        drawRevertIcon(state: state, in: rightIconRect, isHovered: isThisIconHovered, lineType: row.right?.type ?? .unchanged)
                    }
                }

                if let left = row.left {
                    if let old = left.oldLineNumber {
                        ("\(old)" as NSString).draw(in: NSRect(x: 20, y: y + 2.5, width: 38, height: 16), withAttributes: numAttrs)
                    }
                    if left.type == .deleted {
                        ("-" as NSString).draw(in: NSRect(x: 62, y: y + 2.5, width: 12, height: 16), withAttributes: delSymbolAttrs)
                    }
                    if let (start, end) = normalizedSelection, start.side == .left, i >= start.itemIndex && i <= end.itemIndex {
                        let len = left.text.count
                        let charStart = (i == start.itemIndex) ? start.charIndex : 0
                        let charEnd = (i == end.itemIndex) ? end.charIndex : len
                        for selRect in selectionRects(for: i, side: .left, charStart: charStart, charEnd: charEnd) {
                            (isDark ? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45) : NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)).setFill()
                            selRect.fill()
                        }
                    }
                    if let leftAttr = leftAttributedText {
                        leftAttr.draw(
                            with: NSRect(x: 78, y: y + 2.5, width: max(0, colW - 82), height: max(16.0, h - 4.0)),
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            context: nil
                        )
                    }
                }

                // If block is highlighted, make sure center divider line is visible
                if isBlockHighlighted {
                    separatorColor.setFill()
                    NSRect(x: colW, y: y, width: 1, height: h).fill()
                }

                if let right = row.right {
                    if let new = right.newLineNumber {
                        ("\(new)" as NSString).draw(in: NSRect(x: colW + 1 + 20, y: y + 2.5, width: 38, height: 16), withAttributes: numAttrs)
                    }
                    if right.type == .added {
                        ("+" as NSString).draw(in: NSRect(x: colW + 1 + 62, y: y + 2.5, width: 12, height: 16), withAttributes: addSymbolAttrs)
                    }
                    if let (start, end) = normalizedSelection, start.side == .right, i >= start.itemIndex && i <= end.itemIndex {
                        let len = right.text.count
                        let charStart = (i == start.itemIndex) ? start.charIndex : 0
                        let charEnd = (i == end.itemIndex) ? end.charIndex : len
                        for selRect in selectionRects(for: i, side: .right, charStart: charStart, charEnd: charEnd) {
                            (isDark ? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45) : NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)).setFill()
                            selRect.fill()
                        }
                    }
                    if right.type == .added {
                        ("+" as NSString).draw(in: NSRect(x: colW + 1 + 62, y: y + 2.5, width: 12, height: 16), withAttributes: addSymbolAttrs)
                    }
                    if let rightAttr = rightAttributedText {
                        rightAttr.draw(
                            with: NSRect(x: colW + 1 + 78, y: y + 2.5, width: max(0, colW - 82), height: max(16.0, h - 4.0)),
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            context: nil
                        )
                    }
                }
            }
        }
    }

    func item(at y: CGFloat) -> DiffRowItem? {
        guard let idx = itemIndex(at: y) else { return nil }
        return items[idx]
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "DiffMenu")

        if let text = getSelectedText(), !text.isEmpty {
            let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
            copyItem.target = self
            menu.addItem(copyItem)
            menu.addItem(NSMenuItem.separator())
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let idx = itemIndex(at: point.y) else {
            let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
            selectAllItem.target = self
            menu.addItem(selectAllItem)
            return menu
        }
        let item = items[idx]

        if isChangeItem(at: idx) {
            let range = calculateBlockRange(at: idx)
            let revertItem = NSMenuItem(title: "Revert Block Against Working Directory", action: #selector(revertBlockMenuAction(_:)), keyEquivalent: "")
            revertItem.representedObject = range
            revertItem.target = self
            menu.addItem(revertItem)
            menu.addItem(NSMenuItem.separator())
        }

        switch item {
        case .unifiedLine(let line, _, _, _):
            let copyItem = NSMenuItem(title: "Copy Line", action: #selector(copyLineAction(_:)), keyEquivalent: "")
            copyItem.representedObject = line.text
            copyItem.target = self
            menu.addItem(copyItem)

        case .sideBySideRow(let row, _, _, _, _):
            if point.x <= columnWidth {
                if let leftText = row.left?.text {
                    let copyItem = NSMenuItem(title: "Copy Previous Line", action: #selector(copyLineAction(_:)), keyEquivalent: "")
                    copyItem.representedObject = leftText
                    copyItem.target = self
                    menu.addItem(copyItem)
                }
            } else {
                if let rightText = row.right?.text {
                    let copyItem = NSMenuItem(title: "Copy Current Line", action: #selector(copyLineAction(_:)), keyEquivalent: "")
                    copyItem.representedObject = rightText
                    copyItem.target = self
                    menu.addItem(copyItem)
                }
            }

        case .unifiedHeader(let text, _, _), .sideBySideHeader(let text, _, _):
            let copyItem = NSMenuItem(title: "Copy Hunk Header", action: #selector(copyLineAction(_:)), keyEquivalent: "")
            copyItem.representedObject = text
            copyItem.target = self
            menu.addItem(copyItem)
        }

        menu.addItem(NSMenuItem.separator())
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        return menu
    }

    @objc private func revertBlockMenuAction(_ sender: NSMenuItem) {
        guard let range = sender.representedObject as? Range<Int> else { return }
        let details = extractBlockDetails(for: range)
        onRevertBlock?(details.keys, details.removedLines, details.addedLines, details.contextBefore, details.contextAfter)
        needsDisplay = true
    }

    @objc private func copyLineAction(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
