// HPLaserJetMenu.swift — menu-bar status app for hp-laserjet-mac-driver
//
// A tiny NSStatusItem utility that surfaces the state of the host-based HP
// LaserJet print pipeline: whether a supported printer is on the USB bus, how
// many jobs are queued in the spool, and one-click access to retrigger the
// watcher, open the spool/log, and clear the queue.
//
// It is intentionally standalone: it shells out to `ioreg` for USB detection
// (matching the watcher, which uses ioreg because system_profiler returns
// nothing on macOS Tahoe) and reads the spool directory directly. It never
// touches USB, execs the drivers, or writes anything but a transient nudge
// file — all real work stays in the unsandboxed launchd watcher.
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

// MARK: - Model

/// The result of a USB detection pass.
private struct PrinterStatus {
    let online: Bool
    /// USB "USB Product Name" string when the device exposes one.
    let modelName: String?
}

// MARK: - App logic

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    // Menu items we mutate on refresh.
    private let printerItem = NSMenuItem(title: "Printer: …", action: nil, keyEquivalent: "")
    private let queueItem = NSMenuItem(title: "Queue: …", action: nil, keyEquivalent: "")

    private var spoolURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(spoolDirName, isDirectory: true)
    }

    private var logURL: URL {
        spoolURL.appendingPathComponent(logFileName, isDirectory: false)
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "printer", accessibilityDescription: "HP LaserJet")
            icon?.isTemplate = true
            button.image = icon
            // Fallback for very old systems lacking the SF Symbol.
            if button.image == nil {
                button.title = "HP"
            }
        }

        buildMenu()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
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
        queueItem.isEnabled = false
        menu.addItem(printerItem)
        menu.addItem(queueItem)

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
        let status = detectPrinter()
        if status.online {
            let label = status.modelName ?? "online"
            printerItem.title = "Printer: \(label)"
        } else {
            printerItem.title = "Printer: offline"
        }

        let n = queuedJobCount()
        queueItem.title = "Queue: \(n) job\(n == 1 ? "" : "s")"
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

        // ioreg is a tree; a printer's idVendor / idProduct / USB Product Name
        // lines are all attributes of the same device node, appearing close
        // together. We scan for a device node that has both the HP vendor id and
        // a supported product id, capturing any Product Name we see alongside.
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if let v = attributeInt(line, key: "idVendor"), v == hpVendorDecimal {
                sawVendor = true
            }
            if let p = attributeInt(line, key: "idProduct"), supportedProductHex.contains(p) {
                sawProduct = true
            }
            if let name = attributeString(line, key: "USB Product Name") {
                // Only remember HP-ish names to avoid picking up an unrelated
                // device node's product string.
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
        // Take the leading digits.
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

    // MARK: Spool queries

    private func queuedJobCount() -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: spoolURL.path) else {
            return 0
        }
        return entries.filter { $0.hasPrefix("job-") && $0.hasSuffix(".pdf") }.count
    }

    // MARK: Actions

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
