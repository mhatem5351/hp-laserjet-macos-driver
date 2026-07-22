// HPLaserJetMenu.swift — menu-bar print manager for hp-laserjet-mac-driver
//
// A small NSStatusItem utility that surfaces — and lets you manage — the state
// of the host-based HP LaserJet print pipeline: whether a supported printer is
// on the USB bus, what job (if any) is printing right now, the queued jobs and
// per-job cancel/reprint actions, and the printer's toner / page-count status.
//
// It is intentionally standalone: it shells out to `ioreg` for USB detection
// (matching the watcher, which uses ioreg because system_profiler returns
// nothing on macOS Tahoe) and reads the spool directory + watcher.log directly.
// It NEVER touches USB, execs the drivers, or claims a USB interface — all real
// work stays in the unsandboxed launchd watcher. The only things it writes are
// spool files: a transient nudge, a job deletion (cancel), or an atomic
// .incoming-*→job-*.pdf copy (reprint) — exactly the moves the PDF Service and
// watcher already make.
//
// Build (standalone, no Xcode project):
//   swiftc -O menubar/HPLaserJetMenu.swift -o /usr/local/share/foo2zjs/hp-laserjet-menu
//
// Copyright (C) 2026 hp-laserjet-mac-driver contributors.
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 2 of the License, or (at your option)
// any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
// details.
//
// You should have received a copy of the GNU General Public License along with
// this program; if not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Foundation

// MARK: - Constants

/// HP USB vendor id, decimal (0x03f0). This is what `ioreg` prints for idVendor.
private let hpVendorDecimal = 1008

/// Supported product ids (hex → decimal) for the whole host-based family.
/// Mirrors the model_row / name_row table in hp-laserjet-watcher.sh.
private let supportedProductHex: [Int] = [
    0x0517, // LaserJet 1000
    0x1317, // LaserJet 1005
    0x4117, // LaserJet 1018
    0x2b17, // LaserJet 1020
    0x002a, // P1102 / P1102w  (tested)
    0x092a, // P1566 / P1606
    0x3d17, // P1005
    0x3e17, // P1006
    0x4817, // P1007
    0x4917, // P1008
    0x3f17, // P1505
    0x4017, // P1505n
    0x3b17, // M1005 MFP        (tested)
]

private let spoolDirName = "HP-LaserJet-spool"
private let logFileName = "watcher.log"

/// How often we poll the spool + log. 2 s is responsive without being busy.
private let refreshInterval: TimeInterval = 2.0

/// Cap the log tail we read so a large watcher.log never costs much.
private let logTailBytes = 64 * 1024

// MARK: - Model

/// The result of a USB detection pass.
private struct PrinterStatus {
    let online: Bool
    /// USB "USB Product Name" string when the device exposes one.
    let modelName: String?
}

/// A snapshot of what the watcher is doing, derived from the spool + log.
private struct PipelineState {
    /// A job the watcher appears to be working on right now (best-effort).
    let activeJob: String?
    /// A short human phase string for the active job ("rasterising", "sending", …).
    let activePhase: String?
    /// Queued job files (basenames), oldest first.
    let queued: [String]
    /// True if a partial .incoming-* file is present (spooling in progress).
    let incoming: Bool
    /// Basename of the most recently completed job, from the log (may be gone from disk).
    let lastCompleted: String?
    /// Printer page count, if the log carried a PAGECOUNT status-kv line.
    let pageCount: Int?
    /// True when the latest status indicates low/empty toner.
    let tonerLow: Bool
    /// Latest human-readable DISPLAY/status text, if any.
    let displayText: String?
}

// MARK: - App logic

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    // Menu items we mutate on refresh.
    private let printerItem = NSMenuItem(title: "Printer: …", action: nil, keyEquivalent: "")
    private let activeItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let queueHeaderItem = NSMenuItem(title: "Queue: …", action: nil, keyEquivalent: "")
    /// Submenu holding one entry per queued job (with a Cancel action).
    private let queueSubmenu = NSMenu()
    private let reprintItem = NSMenuItem(title: "Reprint Last", action: nil, keyEquivalent: "")

    /// Cached template printer icon and its low-toner (badged) variant.
    private var baseIcon: NSImage?
    private var badgedIcon: NSImage?

    /// Path to the last completed job we can still reprint (an archived copy).
    private var reprintablePath: URL?

    private var spoolURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(spoolDirName, isDirectory: true)
    }

    private var logURL: URL {
        spoolURL.appendingPathComponent(logFileName, isDirectory: false)
    }

    /// Where we keep a copy of each completed job so "Reprint Last" has something
    /// to re-drop. The watcher deletes job-*.pdf after printing, so we snapshot
    /// the newest job we see on disk into here before it disappears.
    private var archiveURL: URL {
        spoolURL.appendingPathComponent(".menubar-last.pdf", isDirectory: false)
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        baseIcon = NSImage(systemSymbolName: "printer", accessibilityDescription: "HP LaserJet")
        baseIcon?.isTemplate = true
        badgedIcon = NSImage(systemSymbolName: "printer.fill.and.paper.fill",
                             accessibilityDescription: "HP LaserJet — low toner")
            ?? NSImage(systemSymbolName: "exclamationmark.triangle",
                       accessibilityDescription: "HP LaserJet — low toner")
        badgedIcon?.isTemplate = true
        applyIcon(tonerLow: false)

        buildMenu()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: Menu construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        printerItem.isEnabled = false
        activeItem.isEnabled = false
        statusLineItem.isEnabled = false
        queueHeaderItem.isEnabled = false

        menu.addItem(printerItem)
        menu.addItem(activeItem)
        menu.addItem(statusLineItem)

        menu.addItem(.separator())

        // Queue header + a submenu listing each queued job with a cancel action.
        queueHeaderItem.submenu = queueSubmenu
        menu.addItem(queueHeaderItem)

        reprintItem.target = self
        reprintItem.action = #selector(reprintLast)
        menu.addItem(reprintItem)

        menu.addItem(.separator())

        add(menu, "Retrigger Watcher", #selector(retriggerWatcher))
        add(menu, "Open Spool Folder", #selector(openSpoolFolder))
        add(menu, "View Log", #selector(viewLog))
        add(menu, "Clear Spool…", #selector(clearSpool))

        menu.addItem(.separator())

        add(menu, "Quit", #selector(quit))

        statusItem.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: Refresh

    private func refresh() {
        let printer = detectPrinter()
        if printer.online {
            let label = printer.modelName ?? "online"
            printerItem.title = "Printer: \(label)"
        } else {
            printerItem.title = "Printer: offline"
        }

        // Snapshot the newest queued/printing job so Reprint Last survives the
        // watcher deleting job-*.pdf on completion.
        snapshotForReprint()

        let state = readPipelineState()

        // Active job / progress line.
        if let job = state.activeJob {
            let phase = state.activePhase.map { " — \($0)" } ?? ""
            activeItem.title = "Printing: \(prettyJobName(job))\(phase)"
        } else if state.incoming {
            activeItem.title = "Spooling a new job…"
        } else {
            activeItem.title = "Idle"
        }

        // Status line: page count and toner, when known.
        var bits: [String] = []
        if let pc = state.pageCount { bits.append("\(pc) pages") }
        if state.tonerLow {
            bits.append("Toner LOW")
        } else if let d = state.displayText, !d.isEmpty {
            bits.append(d)
        }
        statusLineItem.title = bits.isEmpty ? "Status: —" : "Status: " + bits.joined(separator: " · ")

        applyIcon(tonerLow: state.tonerLow)

        // Queue header + submenu.
        let n = state.queued.count
        queueHeaderItem.title = "Queue: \(n) job\(n == 1 ? "" : "s")"
        rebuildQueueSubmenu(state.queued)

        // Reprint availability.
        if let last = reprintablePath, FileManager.default.fileExists(atPath: last.path) {
            reprintItem.isEnabled = true
            if let name = state.lastCompleted {
                reprintItem.title = "Reprint Last (\(prettyJobName(name)))"
            } else {
                reprintItem.title = "Reprint Last"
            }
        } else {
            reprintItem.isEnabled = false
            reprintItem.title = "Reprint Last"
        }
    }

    private func rebuildQueueSubmenu(_ queued: [String]) {
        queueSubmenu.removeAllItems()
        if queued.isEmpty {
            let empty = NSMenuItem(title: "(no queued jobs)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            queueSubmenu.addItem(empty)
            return
        }
        for name in queued {
            let header = NSMenuItem(title: prettyJobName(name), action: nil, keyEquivalent: "")
            header.isEnabled = false
            queueSubmenu.addItem(header)

            let cancel = NSMenuItem(title: "Cancel Job", action: #selector(cancelJob(_:)), keyEquivalent: "")
            cancel.target = self
            cancel.representedObject = name
            cancel.indentationLevel = 1
            queueSubmenu.addItem(cancel)
        }
    }

    // MARK: Icon

    private func applyIcon(tonerLow: Bool) {
        guard let button = statusItem.button else { return }
        let img = tonerLow ? (badgedIcon ?? baseIcon) : baseIcon
        button.image = img
        button.toolTip = tonerLow ? "HP LaserJet — toner low" : "HP LaserJet"
        if button.image == nil {
            button.title = tonerLow ? "HP!" : "HP"
        }
    }

    // MARK: Detection

    /// Detect a supported HP LaserJet by scanning `ioreg -p IOUSB -l`.
    ///
    /// We match on the HP vendor id (idVendor == 1008) AND a known product id,
    /// same as the watcher. When a matching device also exposes a "USB Product
    /// Name" we surface it as the model label.
    private func detectPrinter() -> PrinterStatus {
        guard let output = runIOReg() else {
            return PrinterStatus(online: false, modelName: nil)
        }

        let lines = output.components(separatedBy: .newlines)
        var sawVendor = false
        var sawProduct = false
        var productName: String?

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if let v = attributeInt(line, key: "idVendor"), v == hpVendorDecimal {
                sawVendor = true
            }
            if let p = attributeInt(line, key: "idProduct"), supportedProductHex.contains(p) {
                sawProduct = true
            }
            if let name = attributeString(line, key: "USB Product Name") {
                if name.lowercased().contains("hp") || name.lowercased().contains("laserjet") {
                    productName = name
                }
            }
        }

        let online = sawVendor && sawProduct
        return PrinterStatus(online: online, modelName: online ? productName : nil)
    }

    /// Parse a numeric ioreg attribute line like: `"idVendor" = 1008`.
    private func attributeInt(_ line: String, key: String) -> Int? {
        let needle = "\"\(key)\" = "
        guard let range = line.range(of: needle) else { return nil }
        let rest = line[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }

    /// Parse a string ioreg attribute line like: `"USB Product Name" = "HP LaserJet ..."`.
    private func attributeString(_ line: String, key: String) -> String? {
        let needle = "\"\(key)\" = \""
        guard let range = line.range(of: needle) else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func runIOReg() -> String? {
        return runProcess("/usr/sbin/ioreg", ["-p", "IOUSB", "-w0", "-l"])
    }

    // MARK: Spool + log queries

    /// Read the spool directory and the tail of watcher.log into one snapshot.
    ///
    /// The watcher's log is the only progress signal we have — it does not emit
    /// byte-level progress, so "active" is inferred: a job is being worked on
    /// when the last "processing <job>" line in the log has no matching
    /// completion ("fwload exit", "empty conversion") *after* it AND that job
    /// file (or a .incoming-*) is still present. Otherwise we are idle.
    private func readPipelineState() -> PipelineState {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: spoolURL.path)) ?? []

        let queued = entries
            .filter { $0.hasPrefix("job-") && $0.hasSuffix(".pdf") }
            .sorted()
        let incoming = entries.contains { $0.hasPrefix(".incoming-") }

        let tail = readLogTail()
        let lines = tail.components(separatedBy: .newlines)

        // Walk the log to find the last "processing" and whether it completed.
        var lastProcessing: String?
        var completedAfterProcessing = false
        var lastPhase: String?
        var lastCompleted: String?
        var pageCount: Int?
        var tonerLow = false
        var displayText: String?

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let p = parseProcessing(t) {
                lastProcessing = p
                completedAfterProcessing = false
                lastPhase = "starting"
            } else if lastProcessing != nil {
                if t.hasPrefix("page height=") {
                    lastPhase = "rasterising"
                } else if t.hasPrefix("raster ") && t.hasSuffix("bytes") {
                    lastPhase = "sending"
                } else if t.hasPrefix("fwload exit") {
                    completedAfterProcessing = true
                    lastCompleted = lastProcessing
                } else if t.hasPrefix("empty conversion") {
                    completedAfterProcessing = true
                    lastCompleted = lastProcessing
                }
            }

            // Status parsing runs regardless of job framing; take the latest.
            if t.hasPrefix("status-kv:") || t.hasPrefix("status-line:") {
                let payload = String(t.drop(while: { $0 != ":" }).dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                if let pc = extractPageCount(payload) { pageCount = pc }
                if let low = extractTonerLow(payload) { tonerLow = low }
                if let disp = extractDisplay(payload) { displayText = disp }
            }
        }

        // A job is active if the last "processing" line was not followed by a
        // completion marker AND that job (or an .incoming) is still on disk.
        var activeJob: String?
        var activePhase: String?
        if let proc = lastProcessing, !completedAfterProcessing {
            let base = (proc as NSString).lastPathComponent
            if queued.contains(base) || incoming {
                activeJob = base
                activePhase = lastPhase
            }
        }

        return PipelineState(activeJob: activeJob,
                             activePhase: activePhase,
                             queued: queued,
                             incoming: incoming,
                             lastCompleted: lastCompleted.map { ($0 as NSString).lastPathComponent },
                             pageCount: pageCount,
                             tonerLow: tonerLow,
                             displayText: displayText)
    }

    /// Match a `processing /path/job-<ts>.pdf` line, returning the path.
    private func parseProcessing(_ line: String) -> String? {
        guard line.hasPrefix("processing ") else { return nil }
        return String(line.dropFirst("processing ".count)).trimmingCharacters(in: .whitespaces)
    }

    /// Pull a page count out of a PJL status payload (e.g. `PAGECOUNT=1234`).
    private func extractPageCount(_ payload: String) -> Int? {
        let upper = payload.uppercased()
        guard let r = upper.range(of: "PAGECOUNT") else { return nil }
        let rest = upper[r.upperBound...].drop { !$0.isNumber }
        let digits = rest.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Decide if a PJL status payload indicates low/empty toner.
    /// Returns nil when the payload says nothing about toner (leave prior value).
    private func extractTonerLow(_ payload: String) -> Bool? {
        let upper = payload.uppercased()
        guard upper.contains("TONER") || upper.contains("CARTRIDGE") || upper.contains("SUPPLY") else {
            return nil
        }
        // Common PJL wording: "TONER LOW", "TONER EMPTY", "REPLACE ... CARTRIDGE",
        // "SUPPLY LOW". Treat any of these as low.
        for marker in ["LOW", "EMPTY", "REPLACE", "OUT", "DEPLETED"] {
            if upper.contains(marker) { return true }
        }
        return false
    }

    /// Pull a human-readable DISPLAY string (e.g. `DISPLAY="Ready"`).
    private func extractDisplay(_ payload: String) -> String? {
        guard let r = payload.range(of: "DISPLAY", options: .caseInsensitive) else { return nil }
        var rest = String(payload[r.upperBound...])
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " =\""))
        if let q = rest.firstIndex(of: "\"") { rest = String(rest[..<q]) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Read the last `logTailBytes` of watcher.log as UTF-8 (lossy).
    private func readLogTail() -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(logTailBytes) ? size - UInt64(logTailBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Snapshot the newest job-*.pdf currently on disk into .menubar-last.pdf so
    /// Reprint Last has a source even after the watcher deletes the original.
    private func snapshotForReprint() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: spoolURL.path) else { return }
        let jobs = entries.filter { $0.hasPrefix("job-") && $0.hasSuffix(".pdf") }.sorted()
        guard let newest = jobs.last else {
            // Nothing queued now; keep any prior archive and just point at it.
            if fm.fileExists(atPath: archiveURL.path) { reprintablePath = archiveURL }
            return
        }
        let src = spoolURL.appendingPathComponent(newest)
        // Copy over the archive (cheap; PDFs are small). Ignore failures — this
        // is best-effort convenience, not correctness.
        try? fm.removeItem(at: archiveURL)
        try? fm.copyItem(at: src, to: archiveURL)
        reprintablePath = archiveURL
    }

    /// job-1721600000.pdf → "job-1721600000".
    private func prettyJobName(_ base: String) -> String {
        var s = base
        if s.hasSuffix(".pdf") { s = String(s.dropLast(4)) }
        return s
    }

    // MARK: Actions

    @objc private func cancelJob(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let target = spoolURL.appendingPathComponent(name)
        // "Cancel" = remove the queued job file (and its sidecar, if present).
        // If the watcher is mid-conversion of this job it holds its own gs/conv
        // pipeline on a temp file, so deleting the spooled PDF only stops future
        // handling — matching Clear Spool semantics.
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        let opts = spoolURL.appendingPathComponent((name as NSString).deletingPathExtension + ".opts")
        try? fm.removeItem(at: opts)
        refresh()
    }

    @objc private func reprintLast() {
        guard let src = reprintablePath,
              FileManager.default.fileExists(atPath: src.path) else {
            warn("No completed job available to reprint yet.")
            return
        }
        // Re-drop a fresh job using the same atomic pattern as the PDF Service:
        // write .incoming-* then rename to job-<ts>.pdf so the watcher never sees
        // a partial file.
        ensureSpoolExists()
        let ts = String(Int(Date().timeIntervalSince1970))
        let incoming = spoolURL.appendingPathComponent(".incoming-reprint-\(ts).pdf")
        let final = spoolURL.appendingPathComponent("job-\(ts).pdf")
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: incoming)
            try fm.copyItem(at: src, to: incoming)
            try fm.moveItem(at: incoming, to: final)
        } catch {
            try? fm.removeItem(at: incoming)
            warn("Could not queue reprint: \(error.localizedDescription)")
            return
        }
        refresh()
    }

    @objc private func retriggerWatcher() {
        // launchd's WatchPaths fires on any change to the spool directory's
        // contents. The reliable nudge is to create then remove a temp file
        // inside it — touching the directory alone is not always observed.
        let fm = FileManager.default
        ensureSpoolExists()
        let nudge = spoolURL.appendingPathComponent(".nudge-\(UUID().uuidString)")
        do {
            try Data().write(to: nudge)
            try? fm.removeItem(at: nudge)
        } catch {
            warn("Could not nudge the watcher: \(error.localizedDescription)")
        }
    }

    @objc private func openSpoolFolder() {
        ensureSpoolExists()
        NSWorkspace.shared.open(spoolURL)
    }

    @objc private func viewLog() {
        let path = logURL.path
        if FileManager.default.fileExists(atPath: path) {
            // Open in Console.app for live tailing.
            _ = runProcess("/usr/bin/open", ["-a", "Console", path])
        } else {
            warn("No log yet at \(path).")
        }
    }

    @objc private func clearSpool() {
        let alert = NSAlert()
        alert.messageText = "Clear the print spool?"
        alert.informativeText = "This deletes queued job-*.pdf files and any partial .incoming-* files in \(spoolURL.path). Jobs still printing may be interrupted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        // Bring app forward so the modal is visible from a menu-bar-only app.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: spoolURL.path) else { return }
        for name in entries {
            let isJob = name.hasPrefix("job-") && name.hasSuffix(".pdf")
            let isIncoming = name.hasPrefix(".incoming-")
            guard isJob || isIncoming else { continue }
            try? fm.removeItem(at: spoolURL.appendingPathComponent(name))
        }
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private func ensureSpoolExists() {
        try? FileManager.default.createDirectory(at: spoolURL, withIntermediateDirectories: true)
    }

    private func warn(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Run a process and return its trimmed stdout, or nil on failure.
    @discardableResult
    private func runProcess(_ launchPath: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
// Menu-bar-only utility: no Dock icon, no main window.
app.setActivationPolicy(.accessory)
app.run()
