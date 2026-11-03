import AppKit
import SwiftTerm
import UniformTypeIdentifiers

/// Terminal view that accepts files and images the way Terminal.app does: dropping or pasting
/// them types their paths, which Claude Code then reads (images show up as [Image #n]).
final class ClaudeTerminalView: LocalProcessTerminalView {
    /// Images without a file on disk (screenshots in the clipboard, images dragged from a browser
    /// or Photos) are saved here first so Claude can open them.
    static let attachmentsDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hive/Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let promiseQueue = OperationQueue()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        setDropHighlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        window?.makeFirstResponder(self)
        let pasteboard = sender.draggingPasteboard

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            insertPaths(urls)
            return true
        }
        // Photos, Mail etc. hand over "file promises" that are written to disk on request.
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            receive(promises)
            return true
        }
        if let url = saveImage(from: pasteboard) {
            insertPaths([url])
            return true
        }
        return false
    }

    private func receive(_ promises: [NSFilePromiseReceiver]) {
        let dir = Self.attachmentsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var received: [URL] = []
        let group = DispatchGroup()
        for promise in promises {
            group.enter()
            promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: promiseQueue) { url, error in
                if error == nil { DispatchQueue.main.async { received.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            if !received.isEmpty { self?.insertPaths(received) }
        }
    }

    private func setDropHighlight(_ on: Bool) {
        wantsLayer = true
        layer?.borderColor = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.9).cgColor
        layer?.borderWidth = on ? 2 : 0
        layer?.cornerRadius = 6
    }

    // MARK: Paste

    /// ⌘V: files copied in Finder paste as paths, an image in the clipboard (e.g. a screenshot
    /// taken with ⌃⇧⌘4) is saved and pasted as a path; plain text pastes as usual.
    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            insertPaths(urls)
        } else if pasteboard.string(forType: .string) == nil, let url = saveImage(from: pasteboard) {
            insertPaths([url])
        } else {
            super.paste(sender)
        }
    }

    // MARK: Attach via file picker

    func chooseAttachments() {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        picker.prompt = "Anhängen"
        picker.message = "Dateien oder Bilder für Claude auswählen"
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            window.makeFirstResponder(self)
            if response == .OK { self.insertPaths(picker.urls) }
        }
    }

    // MARK: Helpers

    private func saveImage(from pasteboard: NSPasteboard) -> URL? {
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.attachmentsDir.appendingPathComponent("Bild \(stamp).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Types the paths like Terminal.app does on drop: shell-escaped, separated by spaces.
    private func insertPaths(_ urls: [URL]) {
        let text = urls.map { Self.shellEscape($0.path) }.joined(separator: " ") + " "
        let bracketed = terminal.bracketedPasteMode
        if bracketed { send(data: EscapeSequences.bracketedPasteStart[0...]) }
        send(txt: text)
        if bracketed { send(data: EscapeSequences.bracketedPasteEnd[0...]) }
    }

    static func shellEscape(_ path: String) -> String {
        let special = Set(" \t\n\\'\"()[]{}&;|<>*?$`!#~")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }
}
