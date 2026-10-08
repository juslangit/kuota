// Kuota — shows Claude plan usage (5-hour session and weekly limit) in the Mac menu bar.
//
// It reads the access token Claude Code already keeps in the login keychain and asks
// the same usage endpoint the /usage screen uses. It never refreshes the token itself:
// refreshing would rotate the refresh token out from under Claude Code and log it out.
// When the token has expired, the menu says so until Claude Code next refreshes it.
import AppKit
import ServiceManagement

struct Window: Decodable {
    let utilization: Double?
    let resets_at: String?
}

struct Limit: Decodable {
    struct Scope: Decodable {
        struct Model: Decodable { let display_name: String? }
        let model: Model?
    }
    let kind: String
    let percent: Double?
    let resets_at: String?
    let scope: Scope?
}

struct Usage: Decodable {
    let five_hour: Window?
    let seven_day: Window?
    let limits: [Limit]?
}

enum FetchError: Error {
    case noLogin, expired, http(Int), other(String)

    var message: String {
        switch self {
        case .noLogin: return "Not signed in to Claude Code"
        case .expired: return "Login expired — open Claude Code to refresh it"
        case .http(let code): return "Usage server answered \(code)"
        case .other(let text): return text
        }
    }
}

// Through /usr/bin/security rather than the Security framework: Claude Code created the
// item with `security`, so that tool is already on its access list and reading never prompts.
func readToken() throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else { throw FetchError.noLogin }
    if let expires = oauth["expiresAt"] as? Double, expires / 1000 < Date().timeIntervalSince1970 {
        throw FetchError.expired
    }
    return token
}

func fetchUsage() async throws -> Usage {
    let token = try readToken()
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("kuota/1.0", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 { throw FetchError.expired }
    guard code == 200 else { throw FetchError.http(code) }
    return try JSONDecoder().decode(Usage.self, from: data)
}

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func resetText(_ s: String?) -> String {
    guard let d = parseDate(s) else { return "" }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "EEE h:mm a"
    let mins = Int(d.timeIntervalSinceNow / 60)
    let left = mins < 60 ? "\(max(mins, 0))m" : mins < 1440 ? "\(mins / 60)h \(mins % 60)m" : "\(mins / 1440)d \(mins % 1440 / 60)h"
    return "resets \(f.string(from: d)) (in \(left))"
}

func color(for percent: Double) -> NSColor {
    percent >= 90 ? .systemRed : percent >= 70 ? .systemOrange : .labelColor
}

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    var last: Usage?
    var lastError: FetchError?
    var updated: Date?

    func applicationDidFinishLaunching(_ note: Notification) {
        item.button?.title = "Claude …"
        // Open at login from the first launch; after that the menu toggle is the user's call.
        if !UserDefaults.standard.bool(forKey: "loginItemOffered") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
        }
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
        // Catch up straight after the Mac wakes instead of showing hours-old numbers.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
        }
    }

    @objc func refresh() {
        Task { @MainActor in
            do {
                last = try await fetchUsage()
                lastError = nil
                updated = Date()
            } catch let e as FetchError {
                lastError = e
            } catch {
                lastError = .other(error.localizedDescription)
            }
            render()
        }
    }

    func render() {
        guard let button = item.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString(string: "✳ ", attributes: [.font: font, .foregroundColor: NSColor.systemOrange])
        if let u = last {
            let s = u.five_hour?.utilization ?? 0
            let w = u.seven_day?.utilization ?? 0
            title.append(NSAttributedString(string: "\(Int(s))%", attributes: [.font: font, .foregroundColor: color(for: s)]))
            title.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            title.append(NSAttributedString(string: "\(Int(w))%", attributes: [.font: font, .foregroundColor: color(for: w)]))
        } else {
            title.append(NSAttributedString(string: "–", attributes: [.font: font]))
        }
        if lastError != nil && last != nil {
            title.append(NSAttributedString(string: " !", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        button.attributedTitle = title
        button.toolTip = "Claude usage: 5-hour session · week"
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        func info(_ text: String) {
            let m = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
        }
        if let u = last {
            info("Session (5 hours): \(Int(u.five_hour?.utilization ?? 0))%")
            info("    \(resetText(u.five_hour?.resets_at))")
            info("Week (all models): \(Int(u.seven_day?.utilization ?? 0))%")
            info("    \(resetText(u.seven_day?.resets_at))")
            for l in u.limits ?? [] where l.kind == "weekly_scoped" {
                let name = l.scope?.model?.display_name ?? "Scoped"
                info("Week (\(name)): \(Int(l.percent ?? 0))%")
            }
        }
        if let e = lastError { info("⚠︎ \(e.message)") }
        if let d = updated {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            info("Updated \(f.string(from: d))")
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open usage page", action: #selector(openPage), keyEquivalent: "u"))
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Kuota", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for m in menu.items where m.action != nil && m.action != #selector(NSApplication.terminate(_:)) { m.target = self }
        item.menu = menu
    }

    @objc func openPage() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            lastError = .other("Open at login: \(error.localizedDescription)")
        }
        rebuildMenu()
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
