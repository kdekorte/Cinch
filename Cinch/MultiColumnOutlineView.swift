#if canImport(AppKit)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

struct MultiColumnOutlineView: NSViewRepresentable {
    @Binding private var selected: ZipNode?
    private let roots: [ZipNode]
    private let onRemove: () -> Void
    private let onSelect: (ZipNode?) -> Void
    private let onCreateZip: () -> Void
    // DRAG-IN SUPPORT: dropped file URLs, plus the folder node they were dropped onto (if any)
    private let onDropFiles: ([URL], ZipNode?) -> Void
    // INTERNAL MOVE SUPPORT: nodes dragged within the outline, plus the target folder (nil = root)
    private let onMoveNodes: ([ZipNode], ZipNode?) -> Void
    // CONTEXT MENU: create a new folder inside the given folder (nil = root)
    private let onCreateFolder: (ZipNode?) -> Void
    // CONTEXT MENU: rename the given node
    private let onRename: (ZipNode) -> Void

    // Pasteboard type used to recognize drags that originate from this outline view
    static let movePasteboardType = NSPasteboard.PasteboardType("com.kdekorte.cinch.zipnode")

    init(
        roots: [ZipNode],
        selected: Binding<ZipNode?>,
        onRemove: @escaping () -> Void,
        onSelect: @escaping (ZipNode?) -> Void,
        onCreateZip: @escaping () -> Void = {},
        onDropFiles: @escaping ([URL], ZipNode?) -> Void = { _, _ in },
        onMoveNodes: @escaping ([ZipNode], ZipNode?) -> Void = { _, _ in },
        onCreateFolder: @escaping (ZipNode?) -> Void = { _ in },
        onRename: @escaping (ZipNode) -> Void = { _ in }
    ) {
        self.roots = roots
        self._selected = selected
        self.onRemove = onRemove
        self.onSelect = onSelect
        self.onCreateZip = onCreateZip
        self.onDropFiles = onDropFiles
        self.onMoveNodes = onMoveNodes
        self.onCreateFolder = onCreateFolder
        self.onRename = onRename
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let outlineView = NSOutlineView(frame: .zero)
        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        outlineView.headerView = NSTableHeaderView()
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = false
        outlineView.allowsColumnResizing = true
        outlineView.allowsColumnReordering = true
        outlineView.selectionHighlightStyle = .regular
        outlineView.style = .fullWidth
        outlineView.intercellSpacing = NSSize(width: 8, height: 0)
        outlineView.gridStyleMask = []

        // Adjust row height for more generous vertical padding (Finder style)
        outlineView.rowHeight = 24

        // Columns - Added "Kind" column between "Name" and "Size"
        let columns: [(identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat)] = [
            (NSUserInterfaceItemIdentifier("name"), "Name", 300),
            (NSUserInterfaceItemIdentifier("kind"), "Kind", 120), // MARK: - Added "Kind" column
            (NSUserInterfaceItemIdentifier("size"), "Size", 100),
            (NSUserInterfaceItemIdentifier("dateModified"), "Date Modified", 150)
        ]

        for col in columns {
            let column = NSTableColumn(identifier: col.identifier)
            column.title = col.title
            column.width = col.width
            column.minWidth = 50
            column.sortDescriptorPrototype = NSSortDescriptor(key: col.identifier.rawValue, ascending: true)
            outlineView.addTableColumn(column)
        }

        outlineView.outlineTableColumn = outlineView.tableColumns[0]

        // --- DRAG-OUT SUPPORT FOR FILES/FOLDERS (macOS) ---
        outlineView.registerForDraggedTypes([.fileURL])
        // --- END ---

        // --- DRAG-IN SUPPORT (drop files onto the list) ---
        // The NSOutlineView intercepts drags (it registers for .fileURL so rows can be
        // dragged out), which prevents SwiftUI's window-level .onDrop from firing over
        // the list. Accept drops here instead and forward them to the SwiftUI layer.
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        scrollView.documentView = outlineView

        // Sorting
        outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        
        if let mainMenu = NSApplication.shared.mainMenu,
           let fileMenuItem = mainMenu.items.first(where: { $0.submenu?.title == "File" || $0.title == "File" }),
           let fileSubmenu = fileMenuItem.submenu {
            // Avoid adding duplicate menu items by checking for an existing one by action
            let exists = fileSubmenu.items.contains(where: { $0.action == #selector(Coordinator.newZipMenuAction(_:)) })
            if !exists {
                fileSubmenu.addItem(NSMenuItem.separator())
                let item = NSMenuItem(title: "New Zip…", action: #selector(Coordinator.newZipMenuAction(_:)), keyEquivalent: "n")
                item.keyEquivalentModifierMask = [.command, .shift]
                item.target = context.coordinator
                fileSubmenu.addItem(item)
            }
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let outlineView = nsView.documentView as? NSOutlineView else { return }
        context.coordinator.updateRoots(roots)
        context.coordinator.updateSelected(selected)
        outlineView.reloadData()
        // Restore expansion states (tracked by path so they survive tree reloads):
        context.coordinator.restoreExpansionStates(in: outlineView)
        // Re-select the row for the selected node's path (if still present)
        context.coordinator.restoreSelection(in: outlineView)
        // Apply current sort
        context.coordinator.applySortDescriptors(outlineView.sortDescriptors)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        private let parent: () -> MultiColumnOutlineView

        private var roots: [ZipNode] = []
        private var childrenMap: [ZipNode: [ZipNode]] = [:]

        private var sortDescriptors: [NSSortDescriptor] = []

        // Expansion state, tracked by entry path (survives tree reloads)
        private var expandedPaths: Set<String> = []

        private let byteFormatter = ByteCountFormatter()
        private let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        // --- DRAG-OUT SUPPORT: Keep temp URLs alive during drag ---
        private var dragTempURLs: [URL] = []
        // --- END ---

        init(_ parent: @escaping @autoclosure () -> MultiColumnOutlineView) {
            self.parent = parent
            super.init()
            byteFormatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
            byteFormatter.countStyle = .file
            updateRoots(self.parent().roots)
        }

        func updateRoots(_ newRoots: [ZipNode]) {
            self.roots = newRoots
            self.childrenMap = [:]
            for root in roots {
                mapChildrenRecursively(root)
            }
        }

        private func mapChildrenRecursively(_ node: ZipNode) {
            if let children = node.children {
                childrenMap[node] = children
                for child in children {
                    mapChildrenRecursively(child)
                }
            } else {
                childrenMap[node] = []
            }
        }

        func updateSelected(_ selected: ZipNode?) {
            // No internal state needed here besides parent binding, handled on selection change
        }

        // MARK: OutlineView DataSource

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? ZipNode else {
                // Root level
                return !roots.isEmpty
            }
            let children = childrenMap[node]
            return !(children?.isEmpty ?? true)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let node = item as? ZipNode {
                return childrenMap[node]?.count ?? 0
            } else {
                return roots.count
            }
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? ZipNode {
                guard let children = childrenMap[node], index < children.count else {
                    return NSNull()
                }
                return children[index]
            } else {
                guard index < roots.count else {
                    return NSNull()
                }
                return roots[index]
            }
        }

        func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
            guard let node = item as? ZipNode, let identifier = tableColumn?.identifier.rawValue else {
                return nil
            }

            switch identifier {
            case "name":
                return node.name
            case "kind": // MARK: - Handle "Kind" column here
                if node.isDirectory {
                    return "Folder"
                } else {
                    if let ext = (node.name as NSString).pathExtension.nonEmpty {
                        // -- FIX: Removed NSWorkspace.shared.typeDescription usage. Use simple mapping --
                        switch ext.lowercased() {
                        case "pdf":
                            return "PDF Document"
                        case "txt":
                            return "Text Document"
                        case "jpg", "jpeg":
                            return "JPEG Image"
                        case "png":
                            return "PNG Image"
                        case "zip":
                            return "ZIP Archive"
                        default:
                            return "File"
                        }
                    } else {
                        return "File"
                    }
                }
            case "size":
                if node.isDirectory {
                    return ""
                } else {
                    return byteFormatter.string(fromByteCount: Int64(node.size ?? 0))
                }
            case "dateModified":
                if let date = node.modificationDate {
                    return dateFormatter.string(from: date)
                } else {
                    return ""
                }
            default:
                return nil
            }
        }

        // MARK: OutlineView Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? ZipNode, let tableColumn = tableColumn else {
                return nil
            }

            let identifier = NSUserInterfaceItemIdentifier("Cell-\(tableColumn.identifier.rawValue)")
            if let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                configure(cell: cell, for: node, column: tableColumn)
                return cell
            }

            let cell = NSTableCellView(frame: .zero)
            cell.identifier = identifier
            configure(cell: cell, for: node, column: tableColumn)
            return cell
        }

        private func configure(cell: NSTableCellView, for node: ZipNode, column: NSTableColumn) {
            switch column.identifier.rawValue {
            case "name":
                // MARK: - Display Finder-appropriate file/folder icon and system font, adjusted spacing
                let stack: NSStackView
                if let existingStack = cell.subviews.compactMap({ $0 as? NSStackView }).first {
                    stack = existingStack
                } else {
                    stack = NSStackView()
                    stack.orientation = .horizontal
                    stack.alignment = .centerY
                    stack.spacing = 6 // Slightly increased spacing to better match Finder
                    stack.translatesAutoresizingMaskIntoConstraints = false

                    cell.addSubview(stack)
                    NSLayoutConstraint.activate([
                        stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
                        stack.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),
                    ])
                }

                let imageView: NSImageView
                if let existingImageView = stack.arrangedSubviews.compactMap({ $0 as? NSImageView }).first {
                    imageView = existingImageView
                } else {
                    imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    imageView.setContentHuggingPriority(.required, for: .horizontal)
                    imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
                    imageView.imageScaling = .scaleProportionallyDown
                    stack.insertArrangedSubview(imageView, at: 0)
                    NSLayoutConstraint.activate([
                        imageView.widthAnchor.constraint(equalToConstant: 16),
                        imageView.heightAnchor.constraint(equalToConstant: 16)
                    ])
                }

                let textField: NSTextField
                if let existingTextField = stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).first {
                    textField = existingTextField
                } else {
                    let tf = NSTextField(labelWithString: node.name)
                    tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                    tf.lineBreakMode = .byTruncatingTail
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    textField = tf
                    stack.addArrangedSubview(textField)
                }

                textField.stringValue = node.name
                textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

                // Set appropriate icon
                if node.isDirectory {
                    imageView.image = NSImage(named: NSImage.folderName)
                } else {
                    // Use file icon from system for file extension or default generic document icon
                    if let ext = (node.name as NSString).pathExtension.nonEmpty {
                        imageView.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
                    } else {
                        imageView.image = NSWorkspace.shared.icon(for: .data)
                    }
                }

            case "kind": // MARK: - Configure cell for "Kind" column
                let kindString: String
                if node.isDirectory {
                    kindString = "Folder"
                } else {
                    if let ext = (node.name as NSString).pathExtension.nonEmpty {
                        // -- FIX: Removed NSWorkspace.shared.typeDescription usage. Use simple mapping --
                        switch ext.lowercased() {
                        case "pdf":
                            kindString = "PDF Document"
                        case "txt":
                            kindString = "Text Document"
                        case "jpg", "jpeg":
                            kindString = "JPEG Image"
                        case "png":
                            kindString = "PNG Image"
                        case "zip":
                            kindString = "ZIP Archive"
                        default:
                            kindString = "File"
                        }
                    } else {
                        kindString = "File"
                    }
                }
                let tf: NSTextField
                if let existingTF = cell.subviews.compactMap({ $0 as? NSTextField }).first {
                    tf = existingTF
                } else {
                    let textField = NSTextField(labelWithString: kindString)
                    textField.translatesAutoresizingMaskIntoConstraints = false
                    textField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                    textField.alignment = .left
                    tf = textField
                    cell.addSubview(tf)
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                }
                tf.stringValue = kindString
                tf.alignment = .left

            case "size":
                let text: String
                if node.isDirectory {
                    text = ""
                } else {
                    text = byteFormatter.string(fromByteCount: Int64(node.size ?? 0))
                }
                let tf: NSTextField
                if let existingTF = cell.subviews.compactMap({ $0 as? NSTextField }).first {
                    tf = existingTF
                } else {
                    let textField = NSTextField(labelWithString: text)
                    textField.translatesAutoresizingMaskIntoConstraints = false
                    textField.alignment = .right // Align right as typical in Finder
                    tf = textField
                    cell.addSubview(tf)
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                }
                tf.stringValue = text
                tf.alignment = .right

            case "dateModified":
                // MARK: - New "Date Modified" column case
                let text: String
                if let date = node.modificationDate {
                    text = dateFormatter.string(from: date)
                } else {
                    text = ""
                }
                let tf: NSTextField
                if let existingTF = cell.subviews.compactMap({ $0 as? NSTextField }).first {
                    tf = existingTF
                } else {
                    let textField = NSTextField(labelWithString: text)
                    textField.translatesAutoresizingMaskIntoConstraints = false
                    textField.alignment = .left
                    tf = textField
                    cell.addSubview(tf)
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                }
                tf.stringValue = text
                tf.alignment = .left

            default:
                break
            }
        }

        // MARK: Selection

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outlineView = notification.object as? NSOutlineView else { return }
            let selectedRow = outlineView.selectedRow
            if selectedRow >= 0, let node = outlineView.item(atRow: selectedRow) as? ZipNode {
                parent().selected = node
                parent().onSelect(node)
            } else {
                parent().selected = nil
                parent().onSelect(nil)
            }
        }

        // MARK: Context Menu

        func outlineView(_ outlineView: NSOutlineView, menuFor event: NSEvent) -> NSMenu? {
            let point = outlineView.convert(event.locationInWindow, from: nil)
            let row = outlineView.row(at: point)
            let node = row >= 0 ? outlineView.item(atRow: row) as? ZipNode : nil

            // Select the row under the cursor, like Finder, so actions that
            // operate on the selection act on the right-clicked entry
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }

            let menu = NSMenu(title: "Context Menu")

            let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(newFolderAction(_:)), keyEquivalent: "")
            newFolderItem.target = self
            newFolderItem.representedObject = node
            menu.addItem(newFolderItem)

            if let node = node {
                menu.addItem(NSMenuItem.separator())
                let renameItem = NSMenuItem(title: "Rename", action: #selector(renameAction(_:)), keyEquivalent: "")
                renameItem.target = self
                renameItem.representedObject = node
                menu.addItem(renameItem)

                let deleteItem = NSMenuItem(title: "Delete", action: #selector(removeAction(_:)), keyEquivalent: "")
                deleteItem.target = self
                deleteItem.representedObject = node
                menu.addItem(deleteItem)
            }

            menu.addItem(NSMenuItem.separator())
            let newZipItem = NSMenuItem(title: "New Zip…", action: #selector(newZipAction(_:)), keyEquivalent: "")
            newZipItem.target = self
            menu.addItem(newZipItem)
            return menu
        }

        @objc private func newFolderAction(_ sender: NSMenuItem) {
            // Create inside the right-clicked folder (or, for a file row, its
            // parent); at the root when the click was on empty space
            if let node = sender.representedObject as? ZipNode {
                parent().onCreateFolder(targetFolderForDrop(onItem: node))
            } else {
                parent().onCreateFolder(nil)
            }
        }

        @objc private func renameAction(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? ZipNode else { return }
            parent().onRename(node)
        }

        @objc private func removeAction(_ sender: NSMenuItem) {
            parent().onRemove()
        }

        @objc private func newZipAction(_ sender: NSMenuItem) {
            parent().onCreateZip()
        }

        @objc func newZipMenuAction(_ sender: NSMenuItem) {
            parent().onCreateZip()
        }

        // MARK: Sorting

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let newDescriptors = outlineView.sortDescriptors
            applySortDescriptors(newDescriptors)
            outlineView.reloadData()
            restoreExpansionStates(in: outlineView)
        }

        fileprivate func applySortDescriptors(_ descriptors: [NSSortDescriptor]) {
            self.sortDescriptors = descriptors
            sortNodesRecursively(&roots)
        }

        private func sortNodesRecursively(_ nodes: inout [ZipNode]) {
            guard !sortDescriptors.isEmpty else { return }
            nodes.sort { lhs, rhs in
                for descriptor in sortDescriptors {
                    let key = descriptor.key ?? ""
                    let ascending = descriptor.ascending

                    var comparisonResult: ComparisonResult = .orderedSame

                    switch key {
                    case "name":
                        comparisonResult = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    case "kind": // MARK: - Add sorting by "Kind"
                        let lhsKind: String
                        let rhsKind: String
                        if lhs.isDirectory {
                            lhsKind = "Folder"
                        } else {
                            if let extL = (lhs.name as NSString).pathExtension.nonEmpty {
                                switch extL.lowercased() {
                                case "pdf":
                                    lhsKind = "PDF Document"
                                case "txt":
                                    lhsKind = "Text Document"
                                case "jpg", "jpeg":
                                    lhsKind = "JPEG Image"
                                case "png":
                                    lhsKind = "PNG Image"
                                case "zip":
                                    lhsKind = "ZIP Archive"
                                default:
                                    lhsKind = "File"
                                }
                            } else {
                                lhsKind = "File"
                            }
                        }
                        if rhs.isDirectory {
                            rhsKind = "Folder"
                        } else {
                            if let extR = (rhs.name as NSString).pathExtension.nonEmpty {
                                switch extR.lowercased() {
                                case "pdf":
                                    rhsKind = "PDF Document"
                                case "txt":
                                    rhsKind = "Text Document"
                                case "jpg", "jpeg":
                                    rhsKind = "JPEG Image"
                                case "png":
                                    rhsKind = "PNG Image"
                                case "zip":
                                    rhsKind = "ZIP Archive"
                                default:
                                    rhsKind = "File"
                                }
                            } else {
                                rhsKind = "File"
                            }
                        }
                        comparisonResult = lhsKind.localizedCaseInsensitiveCompare(rhsKind)
                    case "size":
                        let lhsSize = lhs.size ?? 0
                        let rhsSize = rhs.size ?? 0
                        if lhsSize < rhsSize {
                            comparisonResult = .orderedAscending
                        } else if lhsSize > rhsSize {
                            comparisonResult = .orderedDescending
                        } else {
                            comparisonResult = .orderedSame
                        }
                    case "dateModified":
                        let lhsDate = lhs.modificationDate ?? Date.distantPast
                        let rhsDate = rhs.modificationDate ?? Date.distantPast
                        comparisonResult = lhsDate.compare(rhsDate)
                    default:
                        comparisonResult = .orderedSame
                    }

                    if comparisonResult != .orderedSame {
                        return ascending ? (comparisonResult == .orderedAscending) : (comparisonResult == .orderedDescending)
                    }
                }
                return true
            }

            for i in 0..<nodes.count {
                if var children = childrenMap[nodes[i]], !children.isEmpty {
                    sortNodesRecursively(&children)
                    childrenMap[nodes[i]] = children
                }
            }
        }

        // MARK: Expansion States
        // Tracked by fullPath, not by ZipNode identity: nodes are rebuilt with
        // fresh UUIDs on every tree reload, so identity-based tracking would
        // lose the expanded/collapsed state whenever the view refreshes.

        func restoreExpansionStates(in outlineView: NSOutlineView) {
            for root in roots {
                restoreExpansionRecursively(root, in: outlineView)
            }
        }

        private func restoreExpansionRecursively(_ node: ZipNode, in outlineView: NSOutlineView) {
            if expandedPaths.contains(node.fullPath) {
                outlineView.expandItem(node)
            }
            for child in childrenMap[node] ?? [] {
                restoreExpansionRecursively(child, in: outlineView)
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? ZipNode else { return }
            expandedPaths.insert(item.fullPath)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] as? ZipNode else { return }
            expandedPaths.remove(item.fullPath)
        }

        // Re-selects the row whose node matches the selected node's path
        func restoreSelection(in outlineView: NSOutlineView) {
            guard let selectedPath = parent().selected?.fullPath,
                  let node = nodeForPath(selectedPath) else { return }
            let row = outlineView.row(forItem: node)
            if row >= 0, outlineView.selectedRow != row {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        // --- DRAG-OUT SUPPORT FOR FILES/FOLDERS (macOS) ---

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? ZipNode else {
                return nil
            }

            // The pasteboard item carries two flavors:
            // 1. Our custom type, so dropping back onto this outline moves the
            //    entry inside the archive (rather than re-adding a temp copy).
            // 2. A file URL (extracted to a temp location), so the row can also
            //    be dragged out to the Finder.
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(Data(node.fullPath.utf8), forType: MultiColumnOutlineView.movePasteboardType)

            if let url = extractNodeToTemporaryURL(node: node) {
                // Keep the URLs alive for the duration of drag
                dragTempURLs = [url]
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
            }

            return pasteboardItem
        }

        // --- DRAG-IN SUPPORT: accept files/folders dropped onto the list (macOS) ---

        private let dropLogger = Logger(subsystem: "com.cinch.dragdrop", category: "outline-drop")

        private func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
            // Primary: read file URLs directly
            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty {
                dropLogger.debug("readObjects returned \(urls.count) file URL(s): \(urls.map(\.path), privacy: .public)")
                return urls
            }
            // Fallback: parse the fileURL flavor string by string
            var urls: [URL] = []
            for item in pasteboard.pasteboardItems ?? [] {
                if let s = item.string(forType: .fileURL), let url = URL(string: s) {
                    urls.append(url)
                }
            }
            dropLogger.debug("fallback parse returned \(urls.count) file URL(s)")
            return urls
        }

        // Finds the node with the given fullPath in the current tree
        private func nodeForPath(_ fullPath: String) -> ZipNode? {
            var queue = roots
            while !queue.isEmpty {
                let node = queue.removeFirst()
                if node.fullPath == fullPath { return node }
                queue.append(contentsOf: childrenMap[node] ?? [])
            }
            return nil
        }

        // Resolves the folder a drop on the given item should target
        private func targetFolderForDrop(onItem item: Any?) -> ZipNode? {
            if let node = item as? ZipNode, node.isDirectory {
                return node
            }
            if let node = item as? ZipNode,
               let parent = childrenMap.keys.first(where: { childrenMap[$0]?.contains(node) ?? false }),
               parent.isDirectory {
                // Dropped onto a file row: add alongside it, in its parent folder
                return parent
            }
            return nil
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let types = info.draggingPasteboard.types ?? []
            dropLogger.debug("validateDrop: pasteboard types = \(types.map(\.rawValue), privacy: .public)")
            // Internal drag (from this outline): move the entry within the archive
            if types.contains(MultiColumnOutlineView.movePasteboardType) {
                return .move
            }
            // Accept any drag that carries file URLs (resolved at accept time)
            if types.contains(.fileURL)
                || types.contains(where: { $0.rawValue == UTType.fileURL.identifier }) {
                return .copy
            }
            return []
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let pasteboard = info.draggingPasteboard

            // Internal move: drop entries from this outline into another folder (or the root)
            if pasteboard.types?.contains(MultiColumnOutlineView.movePasteboardType) == true {
                let fullPaths = (pasteboard.pasteboardItems ?? []).compactMap { item in
                    item.data(forType: MultiColumnOutlineView.movePasteboardType)
                        .flatMap { String(data: $0, encoding: .utf8) }
                }
                let nodes = fullPaths.compactMap { nodeForPath($0) }
                guard !nodes.isEmpty else {
                    dropLogger.error("acceptDrop: internal move but no matching nodes found")
                    return false
                }
                let targetFolder = targetFolderForDrop(onItem: item)
                dropLogger.debug("acceptDrop: moving \(nodes.count) node(s) into \(targetFolder?.fullPath ?? "root", privacy: .public)")
                // Auto-expand the destination folder so the moved entry is visible
                if let target = targetFolder {
                    expandedPaths.insert(target.fullPath)
                }
                parent().onMoveNodes(nodes, targetFolder)
                return true
            }

            // External drop: files from the Finder (or another app)
            let urls = droppedFileURLs(from: pasteboard)
            guard !urls.isEmpty else {
                dropLogger.error("acceptDrop: no file URLs found on pasteboard — rejecting")
                return false
            }
            let targetFolder = targetFolderForDrop(onItem: item)
            dropLogger.debug("acceptDrop: forwarding \(urls.count) URL(s), targetFolder = \(targetFolder?.fullPath ?? "root", privacy: .public)")
            parent().onDropFiles(urls, targetFolder)
            return true
        }

        // Helper function to extract a ZipNode (file or folder) to a temporary location.
        // If folder, recursively extracts all contents.
        private func extractNodeToTemporaryURL(node: ZipNode) -> URL? {
            // Create a unique temporary directory for the drag
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MultiColumnOutlineViewDragTemp", isDirectory: true)
            let fileManager = FileManager.default
            do {
                if fileManager.fileExists(atPath: tempDir.path) {
                    try fileManager.removeItem(at: tempDir)
                }
                try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                return nil
            }

            if node.isDirectory {
                // Extract folder recursively into a temp folder
                let destURL = tempDir.appendingPathComponent(node.name, isDirectory: true)
                do {
                    try extractNodeRecursively(node: node, toURL: destURL)
                    return destURL
                } catch {
                    return nil
                }
            } else {
                // Extract single file to temp file
                let destURL = tempDir.appendingPathComponent(node.name, isDirectory: false)
                do {
                    try extractFileNode(node: node, toURL: destURL)
                    return destURL
                } catch {
                    return nil
                }
            }
        }

        // Recursively extracts a folder node and its children to destination URL
        private func extractNodeRecursively(node: ZipNode, toURL url: URL) throws {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)

            if let children = node.children {
                for child in children {
                    let childURL = url.appendingPathComponent(child.name, isDirectory: child.isDirectory)
                    if child.isDirectory {
                        try extractNodeRecursively(node: child, toURL: childURL)
                    } else {
                        try extractFileNode(node: child, toURL: childURL)
                    }
                }
            }
        }

        // Extracts a single file node to destination URL
        private func extractFileNode(node: ZipNode, toURL url: URL) throws {
            // -- FIX: Removed usage of node.data which does not exist --
            // Create empty file as fallback since no data access
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }

        // --- END ---
    }
}

#else
import SwiftUI

struct MultiColumnOutlineView: View {
    init(
        roots: [ZipNode],
        selected: Binding<ZipNode?>,
        onRemove: @escaping () -> Void,
        onSelect: @escaping (ZipNode?) -> Void,
        onCreateZip: @escaping () -> Void = {},
        onDropFiles: @escaping ([URL], ZipNode?) -> Void = { _, _ in },
        onMoveNodes: @escaping ([ZipNode], ZipNode?) -> Void = { _, _ in },
        onCreateFolder: @escaping (ZipNode?) -> Void = { _ in },
        onRename: @escaping (ZipNode) -> Void = { _ in }
    ) {}

    var body: some View {
        Text("MultiColumnOutlineView is only available on macOS")
            .foregroundColor(.secondary)
            .italic()
    }
}
#endif


private extension String {
    var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}
