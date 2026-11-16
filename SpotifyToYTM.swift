import Cocoa
import UserNotifications

struct ConvertedItem: Codable {
    let title: String
    let spotifyURL: String
    let ytmURL: String
    let timestamp: Date
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastChangeCount: Int = NSPasteboard.general.changeCount
    var lastWrittenURL: String = ""

    let defaults = UserDefaults.standard
    let kEnabled = "isEnabled"
    let kAutoOpen = "autoOpenBrowser"
    let kNotify = "showNotifications"
    let kHistory = "conversionHistory"

    var isEnabled: Bool {
        get { defaults.object(forKey: kEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kEnabled); rebuildMenu(); updateIcon() }
    }
    var autoOpenBrowser: Bool {
        get { defaults.object(forKey: kAutoOpen) as? Bool ?? false }
        set { defaults.set(newValue, forKey: kAutoOpen); rebuildMenu() }
    }
    var showNotifications: Bool {
        get { defaults.object(forKey: kNotify) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kNotify); rebuildMenu() }
    }

    var history: [ConvertedItem] {
        get {
            guard let data = defaults.data(forKey: kHistory),
                  let items = try? JSONDecoder().decode([ConvertedItem].self, from: data) else {
                return []
            }
            return items
        }
        set {
            let trimmed = Array(newValue.prefix(10))
            if let data = try? JSONEncoder().encode(trimmed) {
                defaults.set(data, forKey: kHistory)
            }
            rebuildMenu()
        }
    }

    let spotifyRegex = try! NSRegularExpression(
        pattern: #"https?://(?:open\.spotify\.com/(?:intl-[a-zA-Z-]+/)?(track|album|artist|playlist)/([a-zA-Z0-9]+)|spotify\.link/[a-zA-Z0-9]+)(?:\?[^\s]*)?"#,
        options: [.caseInsensitive]
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        rebuildMenu()

        // Check NSPasteboard.changeCount (lightweight integer check, does not wake Universal Clipboard)
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbolName = isEnabled ? "music.note.tv.fill" : "music.note.tv"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Spotify to YTM") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = isEnabled ? "♫→▶" : "♫×"
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let headerItem = NSMenuItem(title: "Spotify → YouTube Music", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let enableItem = NSMenuItem(title: "Auto-Convert on Copy", action: #selector(toggleEnabled), keyEquivalent: "e")
        enableItem.target = self
        enableItem.state = isEnabled ? .on : .off
        menu.addItem(enableItem)

        let notifyItem = NSMenuItem(title: "Show Notification Banner", action: #selector(toggleNotify), keyEquivalent: "n")
        notifyItem.target = self
        notifyItem.state = showNotifications ? .on : .off
        menu.addItem(notifyItem)

        let autoOpenItem = NSMenuItem(title: "Auto-Open in Browser", action: #selector(toggleAutoOpen), keyEquivalent: "o")
        autoOpenItem.target = self
        autoOpenItem.state = autoOpenBrowser ? .on : .off
        menu.addItem(autoOpenItem)

        let convertNowItem = NSMenuItem(title: "Convert Current Clipboard Now", action: #selector(convertClipboardNow), keyEquivalent: "c")
        convertNowItem.target = self
        menu.addItem(convertNowItem)

        menu.addItem(NSMenuItem.separator())

        let histHeader = NSMenuItem(title: "Recent Conversions (Click to Copy, ⌥-Click to Open)", action: nil, keyEquivalent: "")
        histHeader.isEnabled = false
        menu.addItem(histHeader)

        let items = history
        if items.isEmpty {
            let emptyItem = NSMenuItem(title: "No conversions yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for (idx, item) in items.enumerated() {
                let displayTitle = item.title.count > 45 ? String(item.title.prefix(42)) + "..." : item.title
                let menuItem = NSMenuItem(title: displayTitle, action: #selector(historyItemClicked(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.tag = idx
                menuItem.toolTip = "\(item.ytmURL)\n(From: \(item.spotifyURL))"
                menu.addItem(menuItem)
            }
            menu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Spotify to YTM", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func toggleEnabled() { isEnabled.toggle() }
    @objc func toggleNotify() { showNotifications.toggle() }
    @objc func toggleAutoOpen() { autoOpenBrowser.toggle() }
    @objc func clearHistory() { history = [] }
    @objc func quitApp() { NSApp.terminate(nil) }

    @objc func convertClipboardNow() {
        processCurrentPasteboard(force: true)
    }

    @objc func historyItemClicked(_ sender: NSMenuItem) {
        let items = history
        guard sender.tag >= 0 && sender.tag < items.count else { return }
        let item = items[sender.tag]

        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.option) {
            if let url = URL(string: item.ytmURL) {
                NSWorkspace.shared.open(url)
            }
        } else {
            writeToPasteboard(item.ytmURL)
            if showNotifications {
                sendNotification(title: "Copied YouTube Music Link", subtitle: item.title, body: item.ytmURL)
            }
        }
    }

    func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard isEnabled else { return }
        processCurrentPasteboard(force: false)
    }

    func processCurrentPasteboard(force: Bool) {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }

        if !force && text == lastWrittenURL { return }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = spotifyRegex.firstMatch(in: text, options: [], range: nsRange),
              let matchRange = Range(match.range, in: text) else {
            return
        }

        let spotifyURL = String(text[matchRange])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let (ytmURL, displayTitle) = try self.convertSpotifyURL(spotifyURL)
                DispatchQueue.main.async {
                    // Replace the Spotify URL inside the copied text (supports full message text or bare URL)
                    let updatedText = text.replacingOccurrences(of: spotifyURL, with: ytmURL)
                    self.writeToPasteboard(updatedText)

                    var currentHistory = self.history.filter { $0.ytmURL != ytmURL }
                    currentHistory.insert(ConvertedItem(
                        title: displayTitle,
                        spotifyURL: spotifyURL,
                        ytmURL: ytmURL,
                        timestamp: Date()
                    ), at: 0)
                    self.history = currentHistory

                    if self.showNotifications {
                        self.sendNotification(
                            title: "Converted to YouTube Music",
                            subtitle: displayTitle,
                            body: ytmURL
                        )
                    }

                    if self.autoOpenBrowser, let url = URL(string: ytmURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            } catch {
                NSLog("SpotifyToYTM conversion error: \(error.localizedDescription)")
            }
        }
    }

    func writeToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastWrittenURL = text
        lastChangeCount = pb.changeCount
    }

    func sendNotification(title: String, subtitle: String, body: String) {
        let script = """
        on run argv
            display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv) sound name "Pop"
        end run
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script, title, subtitle, body]
        try? proc.run()
    }

    // MARK: - Conversion Engine

    func convertSpotifyURL(_ urlString: String) throws -> (String, String) {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "SpotifyToYTM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Spotify URL"])
        }

        var req = URLRequest(url: url, timeoutInterval: 8.0)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var htmlBody = ""
        var finalURL = urlString
        var fetchErr: Error?

        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { fetchErr = err }
            if let httpResp = resp as? HTTPURLResponse, let u = httpResp.url?.absoluteString {
                finalURL = u
            }
            if let data = data, let s = String(data: data, encoding: .utf8) {
                htmlBody = s
            }
            sem.signal()
        }
        task.resume()
        sem.wait()

        if let fetchErr = fetchErr { throw fetchErr }

        var itemType = "track"
        if let m = extractRegex(#"open\.spotify\.com/(?:intl-[a-zA-Z-]+/)?(track|album|artist|playlist)/"#, from: finalURL) {
            itemType = m
        }

        var title = decodeHTMLEntities(extractRegex(#"<meta property="og:title" content="([^"]+)""#, from: htmlBody) ?? "")
        let desc = decodeHTMLEntities(extractRegex(#"<meta property="og:description" content="([^"]+)""#, from: htmlBody) ?? "")
        var artist = decodeHTMLEntities(extractRegex(#"<meta name="music:musician_description" content="([^"]+)""#, from: htmlBody) ?? "")

        title = title.replacingOccurrences(of: #"^Listen to\s+"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s*\|\s*Spotify$"#, with: "", options: .regularExpression)

        if artist.isEmpty && desc.contains("·") {
            let firstPart = desc.components(separatedBy: "·")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if !["artist", "playlist", "song"].contains(firstPart.lowercased()) {
                artist = firstPart
            }
        }

        guard !title.isEmpty else {
            throw NSError(domain: "SpotifyToYTM", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not parse Spotify metadata"])
        }

        let query: String
        let displayTitle: String
        if !artist.isEmpty && !title.lowercased().contains(artist.lowercased()) {
            query = "\(title) \(artist)"
            displayTitle = "\(title) — \(artist)"
        } else {
            query = title
            displayTitle = title
        }

        let ytmURL = try searchYouTubeMusic(query: query, itemType: itemType)
        return (ytmURL, displayTitle)
    }

    func searchYouTubeMusic(query: String, itemType: String) throws -> String {
        let apiURL = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!
        var payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": "1.20240101.01.00"
                ]
            ],
            "query": query
        ]
        if itemType == "track" {
            payload["params"] = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
        }

        var req = URLRequest(url: apiURL, timeoutInterval: 8.0)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let sem = DispatchSemaphore(value: 0)
        var responseText = ""
        var searchErr: Error?

        let task = URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err { searchErr = err }
            if let data = data, let s = String(data: data, encoding: .utf8) {
                responseText = s
            }
            sem.signal()
        }
        task.resume()
        sem.wait()

        if let searchErr = searchErr { throw searchErr }

        if itemType == "track" {
            if let videoId = extractRegex(#""videoId":"([a-zA-Z0-9_-]{11})""#, from: responseText) {
                return "https://music.youtube.com/watch?v=\(videoId)"
            }
        } else if itemType == "album" {
            if let browseId = extractRegex(#""browseId":"(MPREb_[a-zA-Z0-9_-]+)""#, from: responseText) {
                return "https://music.youtube.com/browse/\(browseId)"
            }
        } else if itemType == "artist" {
            if let browseId = extractRegex(#""browseId":"(UC[a-zA-Z0-9_-]+)""#, from: responseText) {
                return "https://music.youtube.com/channel/\(browseId)"
            }
        } else if itemType == "playlist" {
            if let browseId = extractRegex(#""browseId":"(VL[a-zA-Z0-9_-]+)""#, from: responseText) {
                return "https://music.youtube.com/browse/\(browseId)"
            }
        }

        if let videoId = extractRegex(#""videoId":"([a-zA-Z0-9_-]{11})""#, from: responseText) {
            return "https://music.youtube.com/watch?v=\(videoId)"
        }

        throw NSError(domain: "SpotifyToYTM", code: 3, userInfo: [NSLocalizedDescriptionKey: "No match found on YouTube Music"])
    }

    func extractRegex(_ pattern: String, from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
    }

    func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&#x27;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">"
        ]
        for (k, v) in entities {
            result = result.replacingOccurrences(of: k, with: v)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
