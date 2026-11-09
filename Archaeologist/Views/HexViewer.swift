import SwiftUI
import AppKit

// MARK: - Custom Table View for Hex Dump

final class HexTableView: NSTableView {
    var onCopy: (() -> Void)?
    var onCopyHexOnly: (() -> Void)?
    var onCopyAsciiOnly: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "c" {
                copySelectedRows()
                return
            } else if event.charactersIgnoringModifiers == "a" {
                selectAll(nil)
                return
            }
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        copySelectedRows()
    }

    @objc func copySelectedRows() {
        onCopy?()
    }

    @objc func copyHexBytes() {
        onCopyHexOnly?()
    }

    @objc func copyAscii() {
        onCopyAsciiOnly?()
    }

    @objc func selectAllRows() {
        selectAll(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = self.row(at: point)
        if clickedRow >= 0 && !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        let menu = NSMenu(title: "Hex Context Menu")

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copySelectedRows), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        let copyHexItem = NSMenuItem(title: "Copy Hex Bytes", action: #selector(copyHexBytes), keyEquivalent: "")
        copyHexItem.target = self
        menu.addItem(copyHexItem)

        let copyAsciiItem = NSMenuItem(title: "Copy Text Representation", action: #selector(copyAscii), keyEquivalent: "")
        copyAsciiItem.target = self
        menu.addItem(copyAsciiItem)

        menu.addItem(NSMenuItem.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAllRows), keyEquivalent: "a")
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        return menu
    }
}

// MARK: - Custom Row View for Clean Selection

final class HexTableRowView: NSTableRowView {
    var isDark: Bool = false

    override func drawSelection(in dirtyRect: NSRect) {
        if isSelected {
            let selectionColor = isDark
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35)
                : NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25)
            selectionColor.setFill()
            dirtyRect.fill()
        }
    }
}

// MARK: - Reusable Cell View

final class HexTableCellView: NSTableCellView {
    let hexTextField = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        hexTextField.isBordered = false
        hexTextField.isBezeled = false
        hexTextField.drawsBackground = false
        hexTextField.isEditable = false
        hexTextField.isSelectable = false
        hexTextField.maximumNumberOfLines = 1
        hexTextField.lineBreakMode = .byClipping
        hexTextField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hexTextField)
        textField = hexTextField

        NSLayoutConstraint.activate([
            hexTextField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            hexTextField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hexTextField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

// MARK: - Custom Scroll View for Hex Dump

final class HexScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - Virtualized NSViewRepresentable

public struct HexEditorRepresentable: NSViewRepresentable {
    public let data: Data
    public let isDark: Bool

    public static let defaultFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    public static func requiredWidth(for bytes: Int, font: NSFont = defaultFont) -> CGFloat {
        let dummy = HexDumpFormatter.formatRow(data: Data(repeating: 0x41, count: bytes), rowIndex: 0, bytesPerRow: bytes)
        let textWidth = (dummy as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth + 36) // 24pt for cell padding (12 left + 12 right) + extra margin
    }

    public init(data: Data, isDark: Bool) {
        self.data = data
        self.isDark = isDark
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(data: data, isDark: isDark)
    }

    public func createScrollView(coordinator: Coordinator) -> NSScrollView {
        let scrollView = HexScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let tableView = HexTableView()
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 18
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsMultipleSelection = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HexColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)

        tableView.dataSource = coordinator
        tableView.delegate = coordinator

        coordinator.tableView = tableView
        coordinator.scrollView = scrollView
        coordinator.setupTableActions()

        scrollView.documentView = tableView

        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.scrollViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )

        scrollView.onLayout = { [weak coordinator] in
            coordinator?.updateDimensionsAndLayout()
        }

        coordinator.update(
            data: data,
            isDark: isDark,
            force: true
        )

        return scrollView
    }

    public func makeNSView(context: Context) -> NSScrollView {
        createScrollView(coordinator: context.coordinator)
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            data: data,
            isDark: isDark,
            force: false
        )
    }

    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var data: Data
        public private(set) var bytesPerRow: Int = 16
        var isDark: Bool
        let font = HexEditorRepresentable.defaultFont
        private var isUpdatingLayout = false

        weak var tableView: HexTableView?
        weak var scrollView: NSScrollView?

        public init(data: Data, isDark: Bool) {
            self.data = data
            self.isDark = isDark
            super.init()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func scrollViewFrameDidChange(_ notification: Notification) {
            updateDimensionsAndLayout()
        }

        func setupTableActions() {
            tableView?.onCopy = { [weak self] in
                guard let self = self, let tableView = self.tableView else { return }
                var selected = tableView.selectedRowIndexes
                if selected.isEmpty && tableView.clickedRow >= 0 {
                    selected.insert(tableView.clickedRow)
                }
                guard !selected.isEmpty else { return }

                let maxRows = 100_000
                var lines: [String] = []
                lines.reserveCapacity(min(selected.count, maxRows))
                for r in selected.prefix(maxRows) {
                    lines.append(HexDumpFormatter.formatRow(data: self.data, rowIndex: r, bytesPerRow: self.bytesPerRow))
                }
                let text = lines.joined(separator: "\n")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }

            tableView?.onCopyHexOnly = { [weak self] in
                guard let self = self, let tableView = self.tableView else { return }
                var selected = tableView.selectedRowIndexes
                if selected.isEmpty && tableView.clickedRow >= 0 {
                    selected.insert(tableView.clickedRow)
                }
                guard !selected.isEmpty else { return }

                let maxRows = 100_000
                var lines: [String] = []
                lines.reserveCapacity(min(selected.count, maxRows))
                for r in selected.prefix(maxRows) {
                    lines.append(HexDumpFormatter.formatHexOnly(data: self.data, rowIndex: r, bytesPerRow: self.bytesPerRow))
                }
                let text = lines.joined(separator: "\n")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }

            tableView?.onCopyAsciiOnly = { [weak self] in
                guard let self = self, let tableView = self.tableView else { return }
                var selected = tableView.selectedRowIndexes
                if selected.isEmpty && tableView.clickedRow >= 0 {
                    selected.insert(tableView.clickedRow)
                }
                guard !selected.isEmpty else { return }

                let maxRows = 100_000
                var lines: [String] = []
                lines.reserveCapacity(min(selected.count, maxRows))
                for r in selected.prefix(maxRows) {
                    lines.append(HexDumpFormatter.formatAsciiOnly(data: self.data, rowIndex: r, bytesPerRow: self.bytesPerRow))
                }
                let text = lines.joined(separator: "\n")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }

        public func update(data: Data, isDark: Bool, force: Bool = false) {
            let dataChanged = force || (self.data.count != data.count) || (self.data != data)
            let themeChanged = force || (self.isDark != isDark)

            if dataChanged || themeChanged || force {
                self.data = data
                self.isDark = isDark

                if let scrollView = scrollView, let tableView = tableView {
                    let bgColor = isDark
                        ? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)
                        : NSColor.textBackgroundColor
                    scrollView.backgroundColor = bgColor
                    tableView.backgroundColor = bgColor

                    updateDimensionsAndLayout()
                    tableView.reloadData()
                    return
                }
            }
        }

        func requiredWidth(for bytes: Int) -> CGFloat {
            HexEditorRepresentable.requiredWidth(for: bytes, font: font)
        }

        public func updateDimensionsAndLayout() {
            guard !isUpdatingLayout else { return }
            isUpdatingLayout = true
            defer { isUpdatingLayout = false }

            guard let scrollView = scrollView, let tableView = tableView, let column = tableView.tableColumns.first else { return }

            let availableWidth = scrollView.contentSize.width
            guard availableWidth > 0 else { return }

            let widthFor16 = HexEditorRepresentable.requiredWidth(for: 16, font: font)
            let widthFor32 = HexEditorRepresentable.requiredWidth(for: 32, font: font)
            let newBytesPerRow = (availableWidth >= widthFor32) ? 32 : 16

            let bytesChanged = (newBytesPerRow != self.bytesPerRow)

            if bytesChanged {
                // Preserve the scroll position corresponding to the current byte offset
                let visibleRows = tableView.rows(in: scrollView.contentView.bounds)
                let currentTopRow = visibleRows.location != NSNotFound ? visibleRows.location : 0
                let currentByteOffset = currentTopRow * self.bytesPerRow

                self.bytesPerRow = newBytesPerRow
                tableView.reloadData()

                let newTopRow = currentByteOffset / newBytesPerRow
                tableView.scrollRowToVisible(newTopRow)
            }

            let measuredWidth = HexEditorRepresentable.requiredWidth(for: self.bytesPerRow, font: font)

            // When displaying hex content, hide the horizontal scrollbar if the window/view
            // is wide enough to show at least the 16 column view.
            let isWideEnoughFor16 = availableWidth >= widthFor16
            let shouldShowHorizontalScroller = !isWideEnoughFor16

            if scrollView.hasHorizontalScroller != shouldShowHorizontalScroller {
                scrollView.hasHorizontalScroller = shouldShowHorizontalScroller
            }

            if isWideEnoughFor16 && scrollView.contentView.bounds.origin.x > 0 {
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }

            let targetWidth = max(measuredWidth, availableWidth)

            if column.width != targetWidth {
                column.width = targetWidth
                column.minWidth = measuredWidth
                tableView.setFrameSize(NSSize(width: targetWidth, height: tableView.frame.height))
            }
        }

        // MARK: - NSTableViewDataSource

        public func numberOfRows(in tableView: NSTableView) -> Int {
            HexDumpFormatter.rowCount(dataLength: data.count, bytesPerRow: bytesPerRow)
        }

        // MARK: - NSTableViewDelegate

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("HexTableCellView")
            var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? HexTableCellView
            if cellView == nil {
                cellView = HexTableCellView()
                cellView?.identifier = identifier
            }

            // Convert and format ONLY the requested row on demand with syntax colors!
            let attrText = HexDumpFormatter.formatAttributedRow(
                data: data,
                rowIndex: row,
                bytesPerRow: bytesPerRow,
                isDark: isDark,
                font: font
            )
            cellView?.hexTextField.attributedStringValue = attrText
            return cellView
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("HexTableRowView")
            var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? HexTableRowView
            if rowView == nil {
                rowView = HexTableRowView()
                rowView?.identifier = identifier
            }
            rowView?.isDark = isDark
            return rowView
        }
    }
}

// MARK: - Hex Content View with Metadata Toolbar

public struct HexContentView: View {
    @ObservedObject var viewModel: HistoryViewModel
    let content: FileRevisionContent

    @Environment(\.colorScheme) private var colorScheme

    public init(viewModel: HistoryViewModel, content: FileRevisionContent) {
        self.viewModel = viewModel
        self.content = content
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        let data = content.binaryData ?? Data()
        let byteCount = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)

        VStack(spacing: 0) {
            // Hex Sub-toolbar
            HStack(spacing: 0) {
                // Left metadata badges (Binary tag, byte count)
                HStack(spacing: 12) {
                    Text("Binary")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.18))
                        .foregroundColor(.purple)
                        .cornerRadius(4)

                    Text("\(data.count) bytes (\(byteCount))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 16)

                // Repo path of the file
                Text(viewModel.displayedPath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.displayedPath)
                    .padding(.leading, 16)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)
            }
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)
            .fixedSize(horizontal: false, vertical: true)

            // Virtualized Hex display: rows formatted strictly on demand as they scroll into view,
            // automatically resizing to 32 bytes/row if wide enough, or 16 bytes/row otherwise.
            // Horizontal scrollbar is hidden when wide enough to show at least the 16 column view.
            HexEditorRepresentable(
                data: data,
                isDark: isDark
            )
        }
    }
}
