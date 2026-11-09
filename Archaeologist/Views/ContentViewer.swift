import SwiftUI
import AppKit

public struct ContentViewer: View {
    @ObservedObject var viewModel: HistoryViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var hoveredLineId: String?
    @State private var blameColumnWidth: CGFloat = CodeGutterView.defaultBlameColumnWidth

    private var blameGutterWidth: CGFloat {
        (viewModel.showBlame ? blameColumnWidth : 0) + CodeGutterView.diffBarWidth + CodeGutterView.lineNumberWidth
    }

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color(NSColor.textBackgroundColor)

            if viewModel.isContentLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Loading revision content...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let error = viewModel.currentContent?.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("Revision Content Unavailable")
                        .font(.system(size: 14, weight: .semibold))
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let content = viewModel.currentContent {
                if content.isImage {
                    ImageViewerView(viewModel: viewModel, content: content)
                } else if content.isBinary || viewModel.isBinary {
                    HexContentView(viewModel: viewModel, content: content)
                } else {
                    textEditorWithBlame(content: content)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No file content loaded")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
    }

    // MARK: - Text & Blame Viewer
    private func textEditorWithBlame(content: FileRevisionContent) -> some View {
        let isDark = colorScheme == .dark
        let language = SyntaxLanguage.detect(filename: viewModel.fileName)
        let addedCount = content.addedLinesCount
        let removedCount = content.removedLinesCount

        return VStack(alignment: .leading, spacing: 0) {
            // Sub-toolbar for Text View
            HStack(spacing: 0) {
                // Left metadata badges (Language, Line count, Delta)
                HStack(spacing: 10) {
                    // Language badge
                    Text(language.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.quaternaryLabelColor))
                        .cornerRadius(4)
                        .lineLimit(1)
                        .fixedSize()

                    // Total lines
                    let displayedLinesCount = viewModel.showDeletedLines ? content.textLines.count : content.nonRemovedLines.count
                    Text("\(displayedLinesCount) lines")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()

                    // Added and Removed lines count in current commit
                    if addedCount > 0 || removedCount > 0 {
                        HStack(spacing: 6) {
                            if addedCount > 0 {
                                Text("+\(addedCount)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.green)
                            }
                            if removedCount > 0 {
                                Text("-\(removedCount)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.separatorColor).opacity(0.12))
                        .cornerRadius(4)
                        .lineLimit(1)
                        .fixedSize()
                    }

                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .frame(maxWidth: blameGutterWidth, alignment: .leading)

                // Repo path of the file aligned directly above the code area if blame were shown
                Text(viewModel.displayedPath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.displayedPath)
                    .padding(.leading, CodeGutterView.defaultTextViewInset.width)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)

                // Toggle Blame Column, Line Wrap & Show Deleted Lines
                HStack(spacing: 12) {
                    Toggle(isOn: $viewModel.showBlame) {
                        HStack(spacing: 4) {
                            Image(systemName: "person.text.rectangle")
                            Text("Blame")
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $viewModel.wrapLines) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.left")
                            Text("Wrap")
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $viewModel.showDeletedLines) {
                        HStack(spacing: 4) {
                            Image(systemName: "minus.circle")
                            Text("Deleted Lines")
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                    .help("Show deleted lines")
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .padding(.trailing, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)
            .fixedSize(horizontal: false, vertical: true)

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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(NSColor.systemRed).opacity(0.12))
                .overlay(Divider(), alignment: .bottom)
            }

            // Code & Blame Editor
            GeometryReader { geometry in
                CodeEditorRepresentable(
                    content: content,
                    language: language,
                    isDark: isDark,
                    showBlame: viewModel.showBlame,
                    wrapLines: viewModel.wrapLines,
                    showDeletedLines: viewModel.showDeletedLines,
                    selectedCommit: viewModel.selectedCommit,
                    commits: viewModel.commits,
                    vcsType: viewModel.vcsType,
                    blameColumnWidth: blameColumnWidth,
                    onBlameClick: { rev in
                        viewModel.goToCommit(byHash: rev)
                    },
                    revertStates: viewModel.revertStates,
                    onRevertBlock: { lineIdx in
                        viewModel.revertBlock(targetIndex: lineIdx)
                    }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .clipped()
        }
    }
}

// MARK: - Image Viewer
public struct ImageViewerView: View {
    @ObservedObject var viewModel: HistoryViewModel
    let content: FileRevisionContent

    @State private var zoomScale: CGFloat? = nil

    public init(viewModel: HistoryViewModel, content: FileRevisionContent) {
        self.viewModel = viewModel
        self.content = content
    }

    private var contentId: String {
        "\(viewModel.selectedCommit?.id ?? ""):\(content.binaryData?.count ?? 0)"
    }

    /// Calculates a default zoom factor that scales large images down to fit within available bounds.
    /// If the image already fits within the available area, returns 1.0 (100%).
    public static func calculateDefaultZoom(imageSize: CGSize, availableSize: CGSize, padding: CGFloat = 48) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, availableSize.width > 0, availableSize.height > 0 else {
            return 1.0
        }
        let availWidth = max(50, availableSize.width - padding)
        let availHeight = max(50, availableSize.height - padding)

        if imageSize.width > availWidth || imageSize.height > availHeight {
            let scaleW = availWidth / imageSize.width
            let scaleH = availHeight / imageSize.height
            let fit = min(scaleW, scaleH)
            return max(0.01, (fit * 100).rounded() / 100)
        }
        return 1.0
    }

    public var body: some View {
        let data = content.binaryData ?? Data()
        let nsImage = NSImage(data: data)

        GeometryReader { geometry in
            let toolbarHeight: CGFloat = 33
            let availableHeight = max(0, geometry.size.height - toolbarHeight)
            let availableSize = CGSize(width: geometry.size.width, height: availableHeight)

            let defaultZoom: CGFloat = {
                if let nsImage = nsImage {
                    return Self.calculateDefaultZoom(imageSize: nsImage.size, availableSize: availableSize)
                }
                return 1.0
            }()

            let effectiveZoom = zoomScale ?? defaultZoom

            VStack(spacing: 0) {
                // Image Toolbar
                HStack(spacing: 16) {
                    if let nsImage = nsImage {
                        Text("\(Int(nsImage.size.width)) × \(Int(nsImage.size.height)) px")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)

                        let byteCount = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                        Text(byteCount)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Text(viewModel.displayedPath)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(viewModel.displayedPath)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                    Spacer()

                    if nsImage != nil {
                        HStack(spacing: 8) {
                            Button(action: {
                                zoomScale = max(0.05, ((effectiveZoom - 0.1) * 10).rounded() / 10)
                            }) {
                                Image(systemName: "minus.magnifyingglass")
                            }
                            .buttonStyle(.plain)

                            Text("\(Int((effectiveZoom * 100).rounded()))%")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 45)

                            Button(action: {
                                zoomScale = min(10.0, ((effectiveZoom + 0.1) * 10).rounded() / 10)
                            }) {
                                Image(systemName: "plus.magnifyingglass")
                            }
                            .buttonStyle(.plain)

                            Button("Reset") {
                                zoomScale = nil
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(Divider(), alignment: .bottom)
                .fixedSize(horizontal: false, vertical: true)

                // Image Content Display: centralized in content area with fit/zoom support
                if let nsImage = nsImage {
                    let displayWidth = nsImage.size.width * effectiveZoom
                    let displayHeight = nsImage.size.height * effectiveZoom

                    let contentWidth = max(availableSize.width, displayWidth + 48)
                    let contentHeight = max(availableHeight, displayHeight + 48)

                    ScrollView([.horizontal, .vertical]) {
                        ZStack {
                            CheckerboardBackground()

                            Image(nsImage: nsImage)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: displayWidth, height: displayHeight)
                                .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                        }
                        .frame(width: contentWidth, height: contentHeight, alignment: .center)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("No image data available")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: contentId) {
                zoomScale = nil
            }
        }
    }
}

// MARK: - Code Editor Representable
struct CodeEditorRepresentable: NSViewRepresentable {
    let content: FileRevisionContent
    let language: SyntaxLanguage
    let isDark: Bool
    let showBlame: Bool
    let wrapLines: Bool
    let showDeletedLines: Bool
    let selectedCommit: CommitInfo?
    let commits: [CommitInfo]
    let vcsType: VCSType?
    let blameColumnWidth: CGFloat
    let onBlameClick: (String) -> Void
    var revertStates: [String: BlockRevertState] = [:]
    var onRevertBlock: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> CodeEditorContainerView {
        let view = CodeEditorContainerView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.update(
            content: content,
            language: language,
            isDark: isDark,
            showBlame: showBlame,
            wrapLines: wrapLines,
            showDeletedLines: showDeletedLines,
            selectedCommit: selectedCommit,
            commits: commits,
            vcsType: vcsType,
            blameColumnWidth: blameColumnWidth,
            onBlameClick: onBlameClick,
            revertStates: revertStates,
            onRevertBlock: onRevertBlock
        )
        return view
    }

    func updateNSView(_ nsView: CodeEditorContainerView, context: Context) {
        nsView.update(
            content: content,
            language: language,
            isDark: isDark,
            showBlame: showBlame,
            wrapLines: wrapLines,
            showDeletedLines: showDeletedLines,
            selectedCommit: selectedCommit,
            commits: commits,
            vcsType: vcsType,
            blameColumnWidth: blameColumnWidth,
            onBlameClick: onBlameClick,
            revertStates: revertStates,
            onRevertBlock: onRevertBlock
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodeEditorContainerView, context: Context) -> CGSize? {
        return CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
    }
}

// MARK: - Code Editor Container View
final class CodeEditorContainerView: NSView {
    let gutterView: CodeGutterView
    let scrollView: NSScrollView
    let textView: CodeTextView
    let minimapView: CodeMinimapView

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        return window?.makeFirstResponder(textView) ?? false
    }

    var showBlame: Bool = true {
        didSet {
            gutterView.showBlame = showBlame
            needsLayout = true
        }
    }
    var wrapLines: Bool = false {
        didSet {
            gutterView.wrapLines = wrapLines
            applyWrapMode()
        }
    }
    var showDeletedLines: Bool = true
    var blameColumnWidth: CGFloat = 316 {
        didSet {
            gutterView.blameColumnWidth = blameColumnWidth
            needsLayout = true
        }
    }
    let minimapWidth: CGFloat = 78

    private final class FormattedContentBox {
        let attributedString: NSAttributedString
        let lineRanges: [NSRange]
        let maxLineChars: Int

        init(attributedString: NSAttributedString, lineRanges: [NSRange], maxLineChars: Int) {
            self.attributedString = attributedString
            self.lineRanges = lineRanges
            self.maxLineChars = maxLineChars
        }
    }
    private static let formattedCache: NSCache<NSString, FormattedContentBox> = {
        let cache = NSCache<NSString, FormattedContentBox>()
        cache.countLimit = 150
        return cache
    }()

    private var maxLineChars: Int = 0
    private var lastContentKey: String?

    init() {
        let layoutManager = NSLayoutManager()
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        self.textView = CodeTextView(frame: .zero, textContainer: textContainer)
        self.scrollView = NSScrollView()
        self.gutterView = CodeGutterView()
        self.minimapView = CodeMinimapView()

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        gutterView.wantsLayer = true
        gutterView.layer?.masksToBounds = true
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true
        minimapView.wantsLayer = true
        minimapView.layer?.masksToBounds = true

        gutterView.layoutManager = layoutManager
        gutterView.scrollView = scrollView
        gutterView.wrapLines = wrapLines
        gutterView.onHoverBlockChange = { [weak self] range in
            self?.textView.highlightedBlockRange = range
            self?.textView.needsDisplay = true
        }

        minimapView.scrollView = scrollView
        minimapView.layoutManager = layoutManager
        minimapView.textView = textView

        textView.textContainerInset = NSSize(width: 8, height: 4)
        gutterView.textViewInset = textView.textContainerInset

        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        addSubview(gutterView)
        addSubview(scrollView)
        addSubview(minimapView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        applyWrapMode()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onScrollViewDidScroll(_ notification: Notification) {
        gutterView.scrollY = scrollView.contentView.bounds.origin.y
        gutterView.needsDisplay = true
        if !minimapView.isHidden {
            minimapView.needsDisplay = true
        }
    }

    func updateTextViewSize() {
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        if !wrapLines {
            let totalContentHeight = CGFloat(textView.lines.count) * 20.0 + textView.textContainerInset.height * 2
            let h = max(contentSize.height, totalContentHeight)
            let charWidth: CGFloat = 7.8
            let estimatedWidth = max(contentSize.width, CGFloat(maxLineChars) * charWidth + textView.textContainerInset.width * 2 + 30)
            if abs(textView.frame.width - estimatedWidth) > 0.5 || abs(textView.frame.height - h) > 0.5 {
                textView.frame = NSRect(x: 0, y: 0, width: estimatedWidth, height: h)
            }
            return
        }

        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        let usedRect = layoutManager.usedRect(for: textContainer)
        let totalContentHeight = usedRect.height + textView.textContainerInset.height * 2
        let w = contentSize.width
        let h = (totalContentHeight > contentSize.height) ? max(contentSize.height, usedRect.height + 20) : contentSize.height

        if abs(textView.frame.width - w) > 0.5 || abs(textView.frame.height - h) > 0.5 {
            textView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        }
    }

    func applyWrapMode() {
        guard let textContainer = textView.textContainer,
              let textStorage = textView.textStorage else { return }

        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 20.0

        if wrapLines {
            style.maximumLineHeight = 0
            style.lineBreakMode = .byWordWrapping

            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textContainer.widthTracksTextView = true
            let contentWidth = max(80, scrollView.contentSize.width)
            textView.frame.size.width = contentWidth
            textContainer.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        } else {
            style.maximumLineHeight = 20.0
            style.lineBreakMode = .byClipping

            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        if textStorage.length > 0 {
            textStorage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: textStorage.length))
            if wrapLines {
                textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length))
            }
        }

        updateTextViewSize()
        needsLayout = true
        gutterView.needsDisplay = true
        textView.needsDisplay = true
    }

    func checkRequiresScrollbar(availableWidth: CGFloat, availableHeight: CGFloat) -> Bool {
        guard !textView.lines.isEmpty, availableHeight > 0 else {
            return false
        }

        if !wrapLines {
            let totalContentHeight = CGFloat(textView.lines.count) * 20.0 + textView.textContainerInset.height * 2
            return totalContentHeight > availableHeight
        }

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              (textView.textStorage?.length ?? 0) > 0 else {
            return false
        }

        let contentW = max(80, availableWidth)
        if abs(textContainer.containerSize.width - contentW) > 0.5 {
            textContainer.containerSize = NSSize(width: contentW, height: CGFloat.greatestFiniteMagnitude)
        }

        if let storage = textView.textStorage, storage.length > 0 {
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: storage.length))
        }

        let usedRect = layoutManager.usedRect(for: textContainer)
        let totalContentHeight = usedRect.height + textView.textContainerInset.height * 2
        return totalContentHeight > availableHeight
    }

    override func layout() {
        super.layout()
        let totalBounds = bounds
        guard totalBounds.width > 0, totalBounds.height > 0 else { return }

        let gutterW: CGFloat = showBlame ? (blameColumnWidth + gutterView.diffBarWidth + gutterView.lineNumberWidth) : (gutterView.diffBarWidth + gutterView.lineNumberWidth)
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterW, height: totalBounds.height)

        let availableW = max(0, totalBounds.width - gutterW)
        let effectiveH = totalBounds.height

        var requiresScrollbar = checkRequiresScrollbar(availableWidth: availableW, availableHeight: effectiveH)

        var scrollW = requiresScrollbar ? max(0, availableW - minimapWidth) : availableW
        scrollView.frame = NSRect(x: gutterW, y: 0, width: scrollW, height: totalBounds.height)

        // If an autohidden horizontal scroller appeared and reduced vertical viewport height, re-check:
        let actualH = scrollView.contentSize.height
        if !requiresScrollbar && actualH > 0 && actualH < effectiveH {
            if checkRequiresScrollbar(availableWidth: availableW, availableHeight: actualH) {
                requiresScrollbar = true
                scrollW = max(0, availableW - minimapWidth)
                scrollView.frame = NSRect(x: gutterW, y: 0, width: scrollW, height: totalBounds.height)
            }
        }

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

        if wrapLines {
            let contentW = max(80, scrollW)
            if let tc = textView.textContainer, abs(tc.containerSize.width - contentW) > 0.5 {
                tc.containerSize = NSSize(width: contentW, height: CGFloat.greatestFiniteMagnitude)
            }
        } else {
            if let tc = textView.textContainer, tc.containerSize.width != CGFloat.greatestFiniteMagnitude {
                tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
        }

        updateTextViewSize()
        gutterView.needsDisplay = true
        if !minimapView.isHidden {
            minimapView.needsDisplay = true
        }
    }

    func update(
        content: FileRevisionContent,
        language: SyntaxLanguage,
        isDark: Bool,
        showBlame: Bool,
        wrapLines: Bool,
        showDeletedLines: Bool,
        selectedCommit: CommitInfo?,
        commits: [CommitInfo] = [],
        vcsType: VCSType? = nil,
        blameColumnWidth: CGFloat,
        onBlameClick: @escaping (String) -> Void,
        revertStates: [String: BlockRevertState] = [:],
        onRevertBlock: ((Int) -> Void)? = nil
    ) {
        self.showBlame = showBlame
        self.blameColumnWidth = blameColumnWidth
        let deletedLinesChanged = (self.showDeletedLines != showDeletedLines)
        self.showDeletedLines = showDeletedLines

        gutterView.wrapLines = wrapLines
        gutterView.commits = commits
        gutterView.vcsType = vcsType
        gutterView.onBlameClick = onBlameClick
        gutterView.isDark = isDark
        gutterView.selectedCommit = selectedCommit
        gutterView.revertStates = revertStates
        gutterView.onRevertBlock = onRevertBlock

        let activeLines = showDeletedLines ? content.textLines : content.nonRemovedLines

        minimapView.update(lines: activeLines, selectedCommit: selectedCommit, isDark: isDark)

        textView.isDark = isDark
        textView.selectedCommit = selectedCommit
        textView.onBlameClick = onBlameClick
        textView.backgroundColor = isDark ? NSColor(white: 0.12, alpha: 1.0) : NSColor.textBackgroundColor

        if self.wrapLines != wrapLines {
            self.wrapLines = wrapLines
        }

        let contentKey = "\(content.rawText.hashValue)_\(activeLines.count)_\(language.rawValue)_\(isDark)_\(showDeletedLines)_\(wrapLines)"
        if contentKey != lastContentKey || deletedLinesChanged {
            lastContentKey = contentKey
            loadLines(lines: activeLines, language: language, isDark: isDark, contentKey: contentKey)
        } else {
            gutterView.needsDisplay = true
            if !minimapView.isHidden {
                minimapView.needsDisplay = true
            }
            textView.needsDisplay = true
        }
    }

    private func loadLines(lines: [BlameLine], language: SyntaxLanguage, isDark: Bool, contentKey: String) {
        if let cached = Self.formattedCache.object(forKey: contentKey as NSString) {
            textView.textStorage?.setAttributedString(cached.attributedString)
            textView.lines = lines
            textView.lineRanges = cached.lineRanges
            maxLineChars = cached.maxLineChars

            gutterView.lines = lines
            gutterView.lineRanges = cached.lineRanges

            minimapView.lines = lines

            updateTextViewSize()

            needsLayout = true
            gutterView.needsDisplay = true
            if !minimapView.isHidden {
                minimapView.needsDisplay = true
            }
            textView.needsDisplay = true
            return
        }

        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let fullAttr = NSMutableAttributedString()
        var ranges: [NSRange] = []
        ranges.reserveCapacity(lines.count)
        var offset = 0
        var maxChars = 0

        for line in lines {
            let clean = line.content.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            let display = clean.isEmpty ? " " : clean
            if display.count > maxChars {
                maxChars = display.count
            }
            let highlighted = SyntaxHighlighter.shared.highlight(text: display, language: language, isDark: isDark, font: font)
            let mutableLine = NSMutableAttributedString(attributedString: highlighted)
            mutableLine.append(NSAttributedString(string: "\n", attributes: [.font: font]))

            let range = NSRange(location: offset, length: mutableLine.length)
            ranges.append(range)
            offset += range.length
            fullAttr.append(mutableLine)
        }

        let paraStyle = NSMutableParagraphStyle()
        paraStyle.minimumLineHeight = 20.0
        if wrapLines {
            paraStyle.maximumLineHeight = 0
            paraStyle.lineBreakMode = .byWordWrapping
        } else {
            paraStyle.maximumLineHeight = 20.0
            paraStyle.lineBreakMode = .byClipping
        }
        if fullAttr.length > 0 {
            fullAttr.addAttribute(.paragraphStyle, value: paraStyle, range: NSRange(location: 0, length: fullAttr.length))
        }

        Self.formattedCache.setObject(
            FormattedContentBox(attributedString: fullAttr, lineRanges: ranges, maxLineChars: maxChars),
            forKey: contentKey as NSString
        )
        maxLineChars = maxChars

        textView.textStorage?.setAttributedString(fullAttr)
        textView.lines = lines
        textView.lineRanges = ranges

        gutterView.lines = lines
        gutterView.lineRanges = ranges

        minimapView.lines = lines

        if wrapLines {
            textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: fullAttr.length))
        }
        updateTextViewSize()

        needsLayout = true
        gutterView.needsDisplay = true
        if !minimapView.isHidden {
            minimapView.needsDisplay = true
        }
        textView.needsDisplay = true
    }
}

// MARK: - Code Minimap View (Scrollbar with Changes Overview)
final class CodeMinimapView: NSView {
    weak var scrollView: NSScrollView?
    weak var layoutManager: NSLayoutManager?
    weak var textView: NSTextView?

    var lines: [BlameLine] = []
    var isDark: Bool = false
    var selectedCommit: CommitInfo?

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

    func update(lines: [BlameLine], selectedCommit: CommitInfo?, isDark: Bool) {
        self.lines = lines
        self.selectedCommit = selectedCommit
        self.isDark = isDark
        needsDisplay = true
    }

    var thumbMetrics: (rect: NSRect, maxScrollY: CGFloat, docHeight: CGFloat, viewportHeight: CGFloat) {
        let defaultMetrics = (rect: NSRect(x: 2, y: 0, width: max(0, bounds.width - 4), height: bounds.height),
                              maxScrollY: CGFloat(0),
                              docHeight: CGFloat(1),
                              viewportHeight: CGFloat(1))
        guard let scrollView = scrollView else { return defaultMetrics }

        let docH = max(textView?.bounds.height ?? scrollView.documentView?.bounds.height ?? 0, 1)
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
        guard bounds.height > 0, !lines.isEmpty else {
            toolTip = nil
            return
        }

        let ratio = max(0, min(1.0, point.y / bounds.height))
        let lineIdx = min(lines.count - 1, max(0, Int(ratio * CGFloat(lines.count))))
        let line = lines[lineIdx]
        let isRemoved = line.changeType == .removed
        let isChanged = line.changeType != .unchanged

        if isRemoved {
            toolTip = "Removed line (Commit \(line.revision))"
        } else if isChanged {
            let lineNumStr = line.lineNumber.map { "Line \($0)" } ?? "Added"
            toolTip = "\(lineNumStr) (Added in \(line.revision))"
        } else if let num = line.lineNumber {
            toolTip = "Line \(num)"
        } else {
            toolTip = "Line \(lineIdx + 1)"
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
        let docH = max(textView?.bounds.height ?? scrollView.documentView?.bounds.height ?? 0, 1)
        let viewH = scrollView.contentSize.height
        let maxScroll = max(0, docH - viewH)
        let clampedY = max(0, min(maxScroll, y))

        let clipView = scrollView.contentView
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: clampedY))
        scrollView.reflectScrolledClipView(clipView)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
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

        guard !lines.isEmpty else { return }

        let totalLines = CGFloat(lines.count)
        let h = bounds.height
        let w = bounds.width
        let lineH = max(1.0, h / totalLines)

        // 3. Draw Diff Markers & Micro-lines
        let trackW: CGFloat = 4.5
        let trackX = w - trackW - 1.0
        var lastNormalDrawnPixelY: Int = -1

        for i in 0..<lines.count {
            let line = lines[i]
            let isRemoved = (line.changeType == .removed)
            let isChanged = line.changeType != .unchanged

            let y = (CGFloat(i) / totalLines) * h
            let markerH = max(2.5, lineH)

            if y + markerH < clipRect.minY || y > clipRect.maxY {
                continue
            }

            if isRemoved {
                // Removed Line: Full-width red highlight band
                NSColor.systemRed.withAlphaComponent(0.26).setFill()
                NSRect(x: 1, y: y, width: w - 1, height: markerH).fill()

                // High-visibility Red indicator in the right change rail
                NSColor.systemRed.setFill()
                NSRect(x: trackX, y: y, width: trackW, height: markerH).fill()

                // Left accent tick
                NSRect(x: 1, y: y, width: 2.5, height: markerH).fill()

                // Red micro-line
                drawMicroLine(content: line.content, y: y, h: markerH, color: NSColor.systemRed.withAlphaComponent(0.9))
            } else if isChanged {
                // Added Line: Full-width green highlight band
                NSColor.systemGreen.withAlphaComponent(0.22).setFill()
                NSRect(x: 1, y: y, width: w - 1, height: markerH).fill()

                // High-visibility Green indicator in the right change rail
                NSColor.systemGreen.setFill()
                NSRect(x: trackX, y: y, width: trackW, height: markerH).fill()

                // Left accent tick
                NSRect(x: 1, y: y, width: 2.5, height: markerH).fill()

                // Green micro-line
                drawMicroLine(content: line.content, y: y, h: markerH, color: NSColor.systemGreen.withAlphaComponent(0.95))
            } else {
                let pixelY = Int(y)
                if pixelY == lastNormalDrawnPixelY {
                    continue
                }
                lastNormalDrawnPixelY = pixelY

                // Normal code micro-line
                let codeColor = isDark
                    ? NSColor(white: 0.50, alpha: 0.45)
                    : NSColor(white: 0.45, alpha: 0.40)
                drawMicroLine(content: line.content, y: y, h: markerH, color: codeColor)
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

// MARK: - Code Gutter View
final class CodeGutterView: NSView {
    static let diffBarWidth: CGFloat = 3.5
    static let lineNumberWidth: CGFloat = 62
    static let defaultBlameColumnWidth: CGFloat = 316
    static let defaultTextViewInset: NSSize = NSSize(width: 8, height: 4)

    weak var scrollView: NSScrollView?
    weak var layoutManager: NSLayoutManager?
    var textViewInset: NSSize = CodeGutterView.defaultTextViewInset

    var lines: [BlameLine] = []
    var lineRanges: [NSRange] = []
    var wrapLines: Bool = false
    var commits: [CommitInfo] = [] {
        didSet {
            var map: [String: CommitInfo] = [:]
            for commit in commits {
                map[commit.id] = commit
                map[commit.fullRevision] = commit
                map[commit.displayRevision] = commit
                if commit.id.count >= 7 {
                    map[String(commit.id.prefix(7))] = commit
                }
            }
            commitsByRevision = map
        }
    }
    private var commitsByRevision: [String: CommitInfo] = [:]

    func commit(for revision: String) -> CommitInfo? {
        if let direct = commitsByRevision[revision] {
            return direct
        }
        return commits.first(where: { $0.matches(revision: revision) })
    }

    var scrollY: CGFloat = 0
    var showBlame: Bool = true
    var blameColumnWidth: CGFloat = CodeGutterView.defaultBlameColumnWidth
    var diffBarWidth: CGFloat { Self.diffBarWidth }
    var lineNumberWidth: CGFloat { Self.lineNumberWidth }
    var isDark: Bool = false
    var selectedCommit: CommitInfo?
    var vcsType: VCSType? = nil
    var onBlameClick: ((String) -> Void)?
    var revertStates: [String: BlockRevertState] = [:]
    var onRevertBlock: ((Int) -> Void)?
    var onHoverBlockChange: ((Range<Int>?) -> Void)?
    var hoveredBlockRange: Range<Int>?

    private var hoveredLineIndex: Int?
    private var isHoveringIcon: Bool = false
    private var trackingArea: NSTrackingArea?
    private var clickedLine: BlameLine?

    override var isFlipped: Bool { true }

    func isFirstLineOfBlock(at index: Int) -> Bool {
        BlameLine.isFirstLineOfBlock(lines: lines, index: index, vcsType: vcsType)
    }

    static let blameRevWidth: CGFloat = 52.0
    static let blameDateWidth: CGFloat = 110.0

    func displayRevision(for line: BlameLine) -> String {
        BlameLine.displayRevision(for: line, vcsType: vcsType)
    }

    func isBlameEntryHidden(at index: Int) -> Bool {
        guard index > 0, index < lines.count else { return false }
        return BlameLine.shouldHideConsecutiveBlame(prev: lines[index - 1], current: lines[index], vcsType: vcsType)
    }

    func blameLayout(screenY: CGFloat = 0) -> (revRect: NSRect, authorRect: NSRect, dateRect: NSRect) {
        let revX: CGFloat = 8.0
        let revWidth = Self.blameRevWidth
        let dateW = Self.blameDateWidth
        let dateX = blameColumnWidth - dateW - 10.0
        let authorX = revX + revWidth + 8.0
        // Reallocate width to the author/username with fixed 7-character revision width
        let authorW = max(50.0, dateX - 8.0 - authorX)

        let revRect = NSRect(x: revX, y: screenY + 2.5, width: revWidth, height: 16.0)
        let authorRect = NSRect(x: authorX, y: screenY + 2.5, width: authorW, height: 16.0)
        let dateRect = NSRect(x: dateX, y: screenY + 3.0, width: dateW, height: 16.0)

        return (revRect, authorRect, dateRect)
    }

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

    private func authorTooltip(for line: BlameLine) -> String {
        let commit = commit(for: line.revision)
        let name = commit?.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? commit!.author
            : line.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = commit?.authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? commit!.authorEmail
            : line.authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        if !name.isEmpty && !email.isEmpty {
            if name.contains("<") && name.contains(">") {
                return name
            }
            return "\(name) <\(email)>"
        } else if !name.isEmpty {
            return name
        } else if !email.isEmpty {
            return email
        } else {
            return "Unknown"
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHoverIndex = lineIndex(at: point)
        if newHoverIndex != hoveredLineIndex {
            hoveredLineIndex = newHoverIndex
            needsDisplay = true
        }

        let diffBarX: CGFloat = showBlame ? blameColumnWidth : 0
        let lineNumberStartX: CGFloat = diffBarX + diffBarWidth
        let inIconArea = (point.x >= lineNumberStartX && point.x <= lineNumberStartX + 18)
        if inIconArea != isHoveringIcon {
            isHoveringIcon = inIconArea
            needsDisplay = true
        }

        var newHoverBlockRange: Range<Int>? = nil
        if inIconArea, let idx = newHoverIndex, idx < lines.count, isFirstLineOfBlock(at: idx) {
            newHoverBlockRange = BlameLine.calculateBlockRange(lines: lines, targetIndex: idx, vcsType: vcsType)
        }

        if newHoverBlockRange != hoveredBlockRange {
            hoveredBlockRange = newHoverBlockRange
            needsDisplay = true
            onHoverBlockChange?(newHoverBlockRange)
        }

        if inIconArea, let idx = newHoverIndex, idx < lines.count, isFirstLineOfBlock(at: idx) {
            let line = lines[idx]
            let state = revertStates[line.id] ?? .normal
            switch state {
            case .success:
                toolTip = "Block reverted successfully in working directory"
            case .error(let msg):
                toolTip = "Revert failed: \(msg)"
            case .normal:
                toolTip = "Revert block against working directory"
            }
            NSCursor.pointingHand.set()
            return
        }

        if showBlame && point.x < blameColumnWidth, let idx = newHoverIndex, idx < lines.count {
            let line = lines[idx]
            let layout = blameLayout()
            if point.x >= layout.authorRect.minX && point.x <= layout.authorRect.maxX {
                toolTip = authorTooltip(for: line)
            } else {
                let revDisp = displayRevision(for: line)
                if revDisp == "Pending" {
                    toolTip = line.changeType == .removed ? "Removed in pending changes" : "Pending uncommitted changes"
                } else {
                    toolTip = line.changeType == .removed ? "Removed in commit \(revDisp)" : "Jump to commit \(revDisp)"
                }
            }
            NSCursor.pointingHand.set()
        } else {
            toolTip = nil
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredLineIndex != nil || isHoveringIcon || hoveredBlockRange != nil {
            hoveredLineIndex = nil
            isHoveringIcon = false
            hoveredBlockRange = nil
            needsDisplay = true
            onHoverBlockChange?(nil)
        }
        toolTip = nil
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let diffBarX: CGFloat = showBlame ? blameColumnWidth : 0
        let lineNumberStartX: CGFloat = diffBarX + diffBarWidth
        let inIconArea = (point.x >= lineNumberStartX && point.x <= lineNumberStartX + 18)

        if inIconArea, let idx = lineIndex(at: point), idx < lines.count {
            if isFirstLineOfBlock(at: idx) {
                onRevertBlock?(idx)
                return
            }
        }

        if showBlame && point.x < blameColumnWidth, let idx = lineIndex(at: point), idx < lines.count {
            let line = lines[idx]
            onBlameClick?(line.revision)
        } else if let idx = lineIndex(at: point), idx < lineRanges.count {
            let range = lineRanges[idx]
            if let tv = scrollView?.documentView as? CodeTextView {
                tv.setSelectedRange(range)
                window?.makeFirstResponder(tv)
            }
        } else {
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scrollView?.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let idx = lineIndex(at: point), idx < lines.count else { return nil }
        let line = lines[idx]
        clickedLine = line

        let menu = NSMenu(title: "GutterMenu")
        let copyLineItem = NSMenuItem(title: "Copy Line", action: #selector(copyLineAction(_:)), keyEquivalent: "")
        copyLineItem.target = self
        menu.addItem(copyLineItem)

        let copyHashItem = NSMenuItem(title: "Copy Commit Hash (\(line.revision))", action: #selector(copyHashAction(_:)), keyEquivalent: "")
        copyHashItem.target = self
        menu.addItem(copyHashItem)

        if line.isChangeLine {
            menu.addItem(NSMenuItem.separator())
            let revertItem = NSMenuItem(title: "Revert Block Against Working Directory", action: #selector(revertBlockAction(_:)), keyEquivalent: "")
            revertItem.target = self
            revertItem.tag = idx
            menu.addItem(revertItem)
        }

        if showBlame {
            menu.addItem(NSMenuItem.separator())
            let jumpItem = NSMenuItem(title: "Jump to Commit \(line.revision)", action: #selector(jumpToCommitAction(_:)), keyEquivalent: "")
            jumpItem.target = self
            menu.addItem(jumpItem)
        }
        return menu
    }

    @objc private func revertBlockAction(_ sender: NSMenuItem) {
        onRevertBlock?(sender.tag)
    }

    @objc private func copyLineAction(_ sender: NSMenuItem) {
        guard let line = clickedLine else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line.content, forType: .string)
    }

    @objc private func copyHashAction(_ sender: NSMenuItem) {
        guard let line = clickedLine else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line.revision, forType: .string)
    }

    @objc private func jumpToCommitAction(_ sender: NSMenuItem) {
        guard let line = clickedLine else { return }
        onBlameClick?(line.revision)
    }

    func lineIndex(at point: NSPoint) -> Int? {
        guard !lines.isEmpty else { return nil }
        let docY = point.y + scrollY

        if !wrapLines {
            let relativeY = docY - textViewInset.height
            if relativeY < 0 { return nil }
            let idx = Int(relativeY / 20.0)
            if idx >= 0 && idx < lines.count {
                return idx
            }
            return nil
        }

        guard let layoutManager = layoutManager, !lineRanges.isEmpty else { return nil }

        let firstGlyph = layoutManager.glyphIndexForCharacter(at: lineRanges[0].location)
        let firstRect = layoutManager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        let firstTop = textViewInset.height + firstRect.minY
        if docY < firstTop { return nil }

        var low = 0
        var high = lineRanges.count - 1
        var candidate = 0
        while low <= high {
            let mid = (low + high) / 2
            let charRange = lineRanges[mid]
            let g = layoutManager.glyphIndexForCharacter(at: charRange.location)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let top = textViewInset.height + rect.minY
            if top <= docY {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        if candidate < lineRanges.count {
            let charRange = lineRanges[candidate]
            let firstG = layoutManager.glyphIndexForCharacter(at: charRange.location)
            let firstR = layoutManager.lineFragmentRect(forGlyphAt: firstG, effectiveRange: nil)
            let lastG = layoutManager.glyphIndexForCharacter(at: max(charRange.location, NSMaxRange(charRange) - 1))
            let lastR = layoutManager.lineFragmentRect(forGlyphAt: lastG, effectiveRange: nil)
            let top = textViewInset.height + firstR.minY
            let bottom = textViewInset.height + NSMaxY(lastR)
            if docY >= top && docY < bottom {
                return candidate
            }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let clipRect = dirtyRect.intersection(bounds)
        guard !clipRect.isNull else { return }

        guard !lines.isEmpty else {
            let bg = isDark ? NSColor(white: 0.10, alpha: 1.0) : NSColor(white: 0.97, alpha: 1.0)
            bg.setFill()
            clipRect.fill()
            return
        }

        let bg = isDark ? NSColor(white: 0.10, alpha: 1.0) : NSColor(white: 0.97, alpha: 1.0)
        bg.setFill()
        clipRect.fill()

        let totalW = bounds.width
        let diffBarX: CGFloat = showBlame ? blameColumnWidth : 0
        let lineNumberStartX: CGFloat = diffBarX + diffBarWidth

        let rightStyle = NSMutableParagraphStyle()
        rightStyle.alignment = .right

        let leftStyle = NSMutableParagraphStyle()
        leftStyle.alignment = .left
        leftStyle.lineBreakMode = .byClipping

        let targetDocY = clipRect.minY + scrollY
        let staticLayout = blameLayout()
        let revX = staticLayout.revRect.origin.x
        let revW = staticLayout.revRect.width
        let authorX = staticLayout.authorRect.origin.x
        let authorW = staticLayout.authorRect.width
        let dateX = staticLayout.dateRect.origin.x
        let dateW = staticLayout.dateRect.width

        let maxDocY = clipRect.maxY + scrollY
        let startIndex: Int
        let endIndex: Int

        if !wrapLines {
            let startY = max(0, targetDocY - textViewInset.height)
            let endY = max(0, maxDocY - textViewInset.height)
            startIndex = max(0, min(lines.count - 1, Int(startY / 20.0)))
            endIndex = max(0, min(lines.count - 1, Int(ceil(endY / 20.0))))
        } else {
            guard let layoutManager = layoutManager else { return }
            var low = 0
            var high = lines.count - 1
            var sIdx = 0
            while low <= high {
                let mid = (low + high) / 2
                guard mid < lineRanges.count else { break }
                let charRange = lineRanges[mid]
                let g = layoutManager.glyphIndexForCharacter(at: charRange.location)
                let rect = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let top = textViewInset.height + rect.minY
                if top <= targetDocY {
                    sIdx = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            startIndex = sIdx
            endIndex = lines.count - 1
        }

        for i in startIndex...endIndex {
            guard i < lines.count else { break }

            let screenY: CGFloat
            let lineH: CGFloat

            if !wrapLines {
                let lineTop = textViewInset.height + CGFloat(i) * 20.0
                screenY = lineTop - scrollY
                lineH = 20.0
                if screenY > clipRect.maxY + 20.0 {
                    break
                }
            } else {
                guard let layoutManager = layoutManager, i < lineRanges.count else { break }
                let charRange = lineRanges[i]
                let firstGlyph = layoutManager.glyphIndexForCharacter(at: charRange.location)
                let firstRect = layoutManager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
                let lineTop = textViewInset.height + firstRect.minY
                if lineTop > maxDocY {
                    break
                }

                let lastGlyph = layoutManager.glyphIndexForCharacter(at: max(charRange.location, NSMaxRange(charRange) - 1))
                let lastRect = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
                lineH = NSMaxY(lastRect) - firstRect.minY
                screenY = lineTop - scrollY
            }

            let line = lines[i]
            let isRemoved = line.changeType == .removed
            let isChanged = line.changeType != .unchanged
            let isConsecutive = isBlameEntryHidden(at: i)
            let isHovered = (hoveredLineIndex == i)
            let isBlockHighlighted = (hoveredBlockRange?.contains(i) == true)

            // Gutter Row Background
            let rawRowRect = NSRect(x: 0, y: screenY, width: totalW, height: lineH)
            let rowRect = rawRowRect.intersection(bounds)
            if !rowRect.isNull {
                if isBlockHighlighted {
                    (isDark ? NSColor.controlAccentColor.withAlphaComponent(0.24) : NSColor.controlAccentColor.withAlphaComponent(0.16)).setFill()
                    rowRect.fill()
                } else if isHovered {
                    NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
                    rowRect.fill()
                } else if isRemoved {
                    (isDark ? NSColor.systemRed.withAlphaComponent(0.09) : NSColor.systemRed.withAlphaComponent(0.06)).setFill()
                    rowRect.fill()
                } else if isChanged {
                    (isDark ? NSColor.systemGreen.withAlphaComponent(0.08) : NSColor.systemGreen.withAlphaComponent(0.05)).setFill()
                    rowRect.fill()
                }
            }

            // 1. Blame Section
            if showBlame {
                if !isConsecutive {
                    // Revision Button (fixed 7 chars, right-aligned)
                    let revRect = NSRect(x: revX, y: screenY + 2.5, width: revW, height: 16.0)
                    let revColor: NSColor
                    if isRemoved {
                        revColor = .systemRed
                    } else if isChanged {
                        revColor = .systemGreen
                    } else {
                        revColor = .controlAccentColor
                    }
                    let revAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: isChanged ? .bold : .medium),
                        .foregroundColor: revColor,
                        .paragraphStyle: rightStyle
                    ]
                    let revDisplay = displayRevision(for: line)
                    (revDisplay as NSString).draw(in: revRect, withAttributes: revAttrs)

                    // Author
                    let authorRect = NSRect(x: authorX, y: screenY + 2.5, width: authorW, height: 16.0)
                    let authorColor: NSColor
                    if isRemoved {
                        authorColor = .systemRed
                    } else if isChanged {
                        authorColor = isDark ? .white : .black
                    } else {
                        authorColor = .labelColor
                    }
                    let authorStyle = NSMutableParagraphStyle()
                    authorStyle.alignment = .left
                    authorStyle.lineBreakMode = .byTruncatingTail

                    let authorAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: authorColor,
                        .paragraphStyle: authorStyle
                    ]
                    (line.author as NSString).draw(in: authorRect, withAttributes: authorAttrs)

                    // Date
                    let dateRect = NSRect(x: dateX, y: screenY + 3.0, width: dateW, height: 16.0)
                    let dateColor: NSColor = isRemoved ? NSColor.systemRed.withAlphaComponent(0.85) : .secondaryLabelColor
                    let dateAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                        .foregroundColor: dateColor,
                        .paragraphStyle: rightStyle
                    ]
                    let dateDisplay: String
                    if let d = line.date {
                        dateDisplay = VCSManager.formatBlameDate(d)
                    } else if let commit = commit(for: line.revision) {
                        dateDisplay = VCSManager.formatBlameDate(commit.date)
                    } else {
                        dateDisplay = line.dateString
                    }
                    (dateDisplay as NSString).draw(in: dateRect, withAttributes: dateAttrs)
                }

                // Separator line after blame column
                let sepColor = isRemoved ? NSColor.systemRed.withAlphaComponent(0.4) : (isChanged ? NSColor.systemGreen.withAlphaComponent(0.4) : NSColor.separatorColor.withAlphaComponent(0.3))
                sepColor.setFill()
                NSRect(x: blameColumnWidth - 1, y: screenY, width: 1, height: lineH).fill()
            }

            // 2. Diff change indicator bar
            let diffRect = NSRect(x: diffBarX, y: screenY, width: diffBarWidth, height: lineH)
            if isBlockHighlighted {
                NSColor.controlAccentColor.setFill()
                diffRect.fill()
            } else if isRemoved {
                NSColor.systemRed.setFill()
                diffRect.fill()
            } else if isChanged {
                NSColor.systemGreen.setFill()
                diffRect.fill()
            }

            // 3. Revert Icon (shown on the first line of a block instead of every line)
            if isFirstLineOfBlock(at: i) {
                let state = revertStates[line.id] ?? .normal
                let iconSize: CGFloat = 13.0
                let iconRect = NSRect(
                    x: lineNumberStartX + 2.0,
                    y: screenY + (lineH - iconSize) / 2.0,
                    width: iconSize,
                    height: iconSize
                )
                let symbolName: String
                let iconColor: NSColor
                let isThisIconHovered = (hoveredLineIndex == i && isHoveringIcon)

                switch state {
                case .success:
                    symbolName = "checkmark.circle.fill"
                    iconColor = .systemGreen
                case .error:
                    symbolName = "exclamationmark.triangle.fill"
                    iconColor = .systemRed
                case .normal:
                    symbolName = "arrow.uturn.backward"
                    if isThisIconHovered {
                        iconColor = .controlAccentColor
                    } else if isRemoved {
                        iconColor = NSColor.systemRed.withAlphaComponent(0.85)
                    } else {
                        iconColor = NSColor.systemGreen.withAlphaComponent(0.85)
                    }
                }

                let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(hierarchicalColor: iconColor))
                if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Revert")?.withSymbolConfiguration(config) {
                    img.draw(in: iconRect)
                }
            }

            // 4. Line Number
            let numRect = NSRect(x: lineNumberStartX + 18, y: screenY + 2.5, width: lineNumberWidth - 22, height: 16)
            if isRemoved {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.systemRed,
                    .paragraphStyle: rightStyle
                ]
                ("-" as NSString).draw(in: numRect, withAttributes: attrs)
            } else if let num = line.lineNumber {
                let numColor: NSColor = isChanged ? .systemGreen : (isHovered ? .labelColor : NSColor.secondaryLabelColor.withAlphaComponent(0.65))
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: isChanged ? .bold : .regular),
                    .foregroundColor: numColor,
                    .paragraphStyle: rightStyle
                ]
                ("\(num)" as NSString).draw(in: numRect, withAttributes: attrs)
            }
        }

        // Right boundary separator line separating gutter from code
        NSColor.separatorColor.withAlphaComponent(0.3).setFill()
        NSRect(x: totalW - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }
}

// MARK: - Code Text View
final class CodeTextView: NSTextView {
    var lines: [BlameLine] = []
    var lineRanges: [NSRange] = []
    var isDark: Bool = false
    var selectedCommit: CommitInfo?
    var onBlameClick: ((String) -> Void)?
    var highlightedBlockRange: Range<Int>?

    override var acceptsFirstResponder: Bool { true }

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

    @objc override func copy(_ sender: Any?) {
        let range = selectedRange()
        if range.length > 0 {
            let str = (string as NSString).substring(with: range)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(str, forType: .string)
        } else {
            super.copy(sender)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !lines.isEmpty else { return }

        let inset = textContainerOrigin
        let fullWidth = max(bounds.width, visibleRect.width)

        let containerY = max(0, rect.minY - inset.y)
        let containerMaxY = max(0, rect.maxY - inset.y)
        guard containerMaxY > containerY else { return }

        let isWrapped = textContainer?.widthTracksTextView == true
        let startLineIndex: Int
        let endLineIndex: Int

        if !isWrapped {
            startLineIndex = max(0, min(lines.count - 1, Int(containerY / 20.0)))
            endLineIndex = max(0, min(lines.count - 1, Int(ceil(containerMaxY / 20.0))))
        } else {
            guard let layoutManager = layoutManager,
                  let textContainer = textContainer,
                  !lineRanges.isEmpty else { return }

            let containerRect = NSRect(x: 0, y: containerY, width: fullWidth, height: containerMaxY - containerY)
            let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
            guard glyphRange.length > 0 else { return }

            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.length > 0 else { return }

            let maxLineIdx = min(lines.count - 1, lineRanges.count - 1)
            func lineIndex(forCharacterAt charIdx: Int) -> Int {
                var low = 0
                var high = maxLineIdx
                var result = 0
                while low <= high {
                    let mid = (low + high) / 2
                    if lineRanges[mid].location <= charIdx {
                        result = mid
                        low = mid + 1
                    } else {
                        high = mid - 1
                    }
                }
                return result
            }

            startLineIndex = lineIndex(forCharacterAt: charRange.location)
            endLineIndex = lineIndex(forCharacterAt: max(charRange.location, NSMaxRange(charRange) - 1))
        }

        guard startLineIndex <= endLineIndex else { return }

        let redBg = isDark ? NSColor.systemRed.withAlphaComponent(0.18) : NSColor.systemRed.withAlphaComponent(0.10)
        let greenBg = isDark ? NSColor.systemGreen.withAlphaComponent(0.18) : NSColor.systemGreen.withAlphaComponent(0.12)

        var idx = startLineIndex
        while idx <= endLineIndex {
            let line = lines[idx]
            let isRemoved = line.changeType == .removed
            let isChanged = line.changeType != .unchanged
            guard isRemoved || isChanged else {
                idx += 1
                continue
            }

            let blockIsRemoved = isRemoved
            let blockStart = idx
            var blockEnd = idx

            while blockEnd + 1 <= endLineIndex {
                let nextLine = lines[blockEnd + 1]
                let nextIsRemoved = nextLine.changeType == .removed
                let nextIsChanged = nextLine.changeType != .unchanged
                guard nextIsRemoved || nextIsChanged else { break }
                if nextIsRemoved != blockIsRemoved { break }
                blockEnd += 1
            }

            let lineY: CGFloat
            let lineH: CGFloat

            if !isWrapped {
                lineY = inset.y + CGFloat(blockStart) * 20.0
                lineH = CGFloat(blockEnd - blockStart + 1) * 20.0
            } else if let lm = layoutManager, blockStart < lineRanges.count, blockEnd < lineRanges.count {
                let firstCharRange = lineRanges[blockStart]
                let firstGlyph = lm.glyphIndexForCharacter(at: firstCharRange.location)
                let firstRect = lm.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)

                let lastCharRange = lineRanges[blockEnd]
                let lastGlyph = lm.glyphIndexForCharacter(at: max(lastCharRange.location, NSMaxRange(lastCharRange) - 1))
                let lastRect = lm.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)

                lineY = inset.y + firstRect.minY
                lineH = NSMaxY(lastRect) - firstRect.minY
            } else {
                idx = blockEnd + 1
                continue
            }

            let blockRect = NSRect(x: 0, y: lineY, width: fullWidth, height: lineH)
            if blockRect.intersects(rect) {
                (blockIsRemoved ? redBg : greenBg).setFill()
                blockRect.fill()
            }

            idx = blockEnd + 1
        }

        // Draw hover highlight for affected block if active
        if let highlightRange = highlightedBlockRange, !highlightRange.isEmpty {
            let visibleHighlightStart = max(highlightRange.lowerBound, startLineIndex)
            let visibleHighlightEnd = min(highlightRange.upperBound - 1, endLineIndex)

            if visibleHighlightStart <= visibleHighlightEnd {
                let lineY: CGFloat
                let lineH: CGFloat

                if !isWrapped {
                    lineY = inset.y + CGFloat(visibleHighlightStart) * 20.0
                    lineH = CGFloat(visibleHighlightEnd - visibleHighlightStart + 1) * 20.0
                } else if let lm = layoutManager, visibleHighlightStart < lineRanges.count, visibleHighlightEnd < lineRanges.count {
                    let firstCharRange = lineRanges[visibleHighlightStart]
                    let firstGlyph = lm.glyphIndexForCharacter(at: firstCharRange.location)
                    let firstRect = lm.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)

                    let lastCharRange = lineRanges[visibleHighlightEnd]
                    let lastGlyph = lm.glyphIndexForCharacter(at: max(lastCharRange.location, NSMaxRange(lastCharRange) - 1))
                    let lastRect = lm.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)

                    lineY = inset.y + firstRect.minY
                    lineH = NSMaxY(lastRect) - firstRect.minY
                } else {
                    return
                }

                let blockRect = NSRect(x: 0, y: lineY, width: fullWidth, height: lineH)
                if blockRect.intersects(rect) {
                    let highlightBg = isDark ? NSColor.controlAccentColor.withAlphaComponent(0.20) : NSColor.controlAccentColor.withAlphaComponent(0.14)
                    highlightBg.setFill()
                    blockRect.fill()

                    NSColor.controlAccentColor.setFill()
                    NSRect(x: 0, y: lineY, width: 3.0, height: lineH).fill()
                }
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu(title: "TextMenu")
        if selectedRange().length > 0 {
            if !menu.items.contains(where: { $0.action == #selector(copy(_:)) }) {
                let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
                copyItem.target = self
                menu.insertItem(copyItem, at: 0)
            }
        } else {
            let point = convert(event.locationInWindow, from: nil)
            let charIdx = characterIndexForInsertion(at: point)
            if let line = lineForCharacterIndex(charIdx) {
                if !menu.items.isEmpty {
                    menu.addItem(NSMenuItem.separator())
                }
                let copyItem = NSMenuItem(title: "Copy Line", action: #selector(copyLineFromMenu(_:)), keyEquivalent: "")
                copyItem.representedObject = line.content
                copyItem.target = self
                menu.addItem(copyItem)

                let jumpItem = NSMenuItem(title: "Jump to Commit (\(line.revision))", action: #selector(jumpToCommitFromMenu(_:)), keyEquivalent: "")
                jumpItem.representedObject = line.revision
                jumpItem.target = self
                menu.addItem(jumpItem)
            }
        }
        return menu
    }

    @objc private func jumpToCommitFromMenu(_ sender: NSMenuItem) {
        if let rev = sender.representedObject as? String {
            onBlameClick?(rev)
        }
    }

    @objc private func copyLineFromMenu(_ sender: NSMenuItem) {
        if let lineText = sender.representedObject as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lineText, forType: .string)
        }
    }

    private func lineForCharacterIndex(_ charIdx: Int) -> BlameLine? {
        for (i, range) in lineRanges.enumerated() {
            if charIdx >= range.location && charIdx < NSMaxRange(range) {
                if i < lines.count {
                    return lines[i]
                }
            }
        }
        return nil
    }
}

// MARK: - Checkerboard Background for Images
public struct CheckerboardBackground: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            let tileSize: CGFloat = 16
            let cols = Int(ceil(size.width / tileSize))
            let rows = Int(ceil(size.height / tileSize))

            for r in 0..<rows {
                for c in 0..<cols {
                    let isEven = (r + c) % 2 == 0
                    let color = isEven ? Color(NSColor.windowBackgroundColor) : Color(NSColor.controlBackgroundColor)
                    let rect = CGRect(x: CGFloat(c) * tileSize, y: CGFloat(r) * tileSize, width: tileSize, height: tileSize)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}
