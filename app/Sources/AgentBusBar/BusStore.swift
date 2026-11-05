import Foundation
import UserNotifications

// Runs `agent-bus snapshot` whenever the ledger or seat registry changes, and
// on a slow timer so ages and liveness stay current. Writes to the bus only
// when the user presses a button, and then as the lead (tool "lead").
@MainActor
final class BusStore: ObservableObject {
    @Published private(set) var snapshot = Snapshot.empty
    @Published private(set) var error: String?
    @Published private(set) var lastAction: String?

    let busDir: URL
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    private var mergedTimer: Timer?
    private var pending: DispatchWorkItem?
    private var running = false
    private var notified: Set<String> = []
    private var primed = false

    init() {
        let env = ProcessInfo.processInfo.environment
        busDir = URL(fileURLWithPath: env["AGENT_BUS_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".agents/bus"))
        watch()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Which lane branches have merged needs git, so it runs on its own clock.
        mergedTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMerged() }
        }
        refresh()
        checkMerged()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: derived views

    func attention(_ kinds: Set<String>) -> [Attention] { snapshot.attention.filter { kinds.contains($0.kind) } }
    static let needsYou: Set<String> = ["needs-you", "review"]
    static let stuck: Set<String> = ["not-picked-up", "blocked", "budget", "wake-failed", "pm-gone"]
    static let cleanup: Set<String> = ["merged", "orphaned", "unfiled"]

    /// The badge: things waiting on the user, plus things stuck.
    var badgeCount: Int { attention(Self.needsYou).count + attention(Self.stuck).count }

    func lane(repo: String?, name: String?) -> Lane? {
        snapshot.lanes.first { $0.lane == name && (repo == nil || $0.repo == repo) }
    }

    // MARK: refresh

    func refresh() {
        guard !running else { return }
        running = true
        Task.detached(priority: .utility) {
            let result = Self.cli(["snapshot"]).flatMap { out -> Result<Snapshot, Error> in
                Result { try JSONDecoder().decode(Snapshot.self, from: Data(out.utf8)) }
            }
            await MainActor.run {
                self.running = false
                switch result {
                case .success(let snap): self.snapshot = snap; self.error = nil; self.notifyNew()
                case .failure(let err): self.error = err.localizedDescription
                }
            }
        }
    }

    func checkMerged() {
        Task.detached(priority: .background) {
            _ = Self.cli(["lanes", "--check-merged"])
            await MainActor.run { self.refresh() }
        }
    }

    // MARK: actions (as the lead)

    /// Run a bus command as the lead. Lane commands need the lane's repo; the
    /// CLI takes it from AGENT_BUS_REPO_ID and, when it still exists, its checkout.
    func act(_ args: [String], lane: Lane? = nil, label: String) {
        Task.detached(priority: .userInitiated) {
            var env = ["AGENT_BUS_TOOL": "lead", "AGENT_BUS_SESSION": "agent-bus-app",
                       "AGENT_BUS_WT": "lead", "AGENT_BUS_BRANCH": "develop"]
            var cwd: String?
            if let lane {
                env["AGENT_BUS_REPO_ID"] = lane.repo_id
                if let dir = lane.cwd, FileManager.default.fileExists(atPath: dir) { cwd = dir }
            }
            let result = Self.cli(args, extraEnv: env, cwd: cwd)
            await MainActor.run {
                switch result {
                case .success(let out):
                    self.lastAction = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? label
                case .failure(let err):
                    self.lastAction = "\(label) failed: \(err.localizedDescription)"
                }
                self.refresh()
            }
        }
    }

    /// Several lane commands, one after another, as one user action.
    func actAll(_ steps: [(args: [String], lane: Lane?)], label: String) {
        Task.detached(priority: .userInitiated) {
            var ok = 0, failed = 0
            for step in steps {
                var env = ["AGENT_BUS_TOOL": "lead", "AGENT_BUS_SESSION": "agent-bus-app",
                           "AGENT_BUS_WT": "lead", "AGENT_BUS_BRANCH": "develop"]
                var cwd: String?
                if let lane = step.lane {
                    env["AGENT_BUS_REPO_ID"] = lane.repo_id
                    if let dir = lane.cwd, FileManager.default.fileExists(atPath: dir) { cwd = dir }
                }
                if case .success = Self.cli(step.args, extraEnv: env, cwd: cwd) { ok += 1 } else { failed += 1 }
            }
            let summary = "\(label): \(ok) done\(failed > 0 ? ", \(failed) failed" : "")"
            await MainActor.run {
                self.lastAction = summary
                self.refresh()
            }
        }
    }

    // MARK: notifications

    // Tell the user when an agent asks for them. The first snapshot only primes
    // the set, so launching the app doesn't replay old asks.
    private func notifyNew() {
        let asks = attention(Self.needsYou)
        let fresh = asks.filter { !notified.contains($0.id) }
        notified.formUnion(asks.map(\.id))
        guard primed else { primed = true; return }
        guard Bundle.main.bundleIdentifier != nil else { return }
        for ask in fresh {
            let content = UNMutableNotificationContent()
            content.title = "An agent needs you"
            content.body = ask.text
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: ask.id, content: content, trigger: nil))
        }
    }

    // MARK: watching

    // Coalesce bursts of writes (a post appends, then touches a seat file).
    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.refresh() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func watch() {
        watchers.forEach { $0.cancel() }
        watchers = []
        for path in ["ledger.jsonl", "seats"] {
            let fd = open(busDir.appendingPathComponent(path).path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                // gc rotates the ledger by replacing the file; re-arm on the new inode.
                if src.data.contains(.rename) || src.data.contains(.delete) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.watch() }
                }
                self.scheduleRefresh()
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
        }
    }

    // MARK: CLI

    private nonisolated static func cli(_ args: [String], extraEnv: [String: String] = [:],
                                        cwd: String? = nil) -> Result<String, Error> {
        guard let bin = locateCLI() else {
            return .failure(BusError("agent-bus not found — set AGENT_BUS_BIN or link it into ~/.local/bin"))
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        // Launched from Finder the app gets a bare PATH; the CLI needs bash, jq, git.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Never inherit an agent identity from whatever launched the app.
        for key in ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "OPENCODE", "OPENCODE_SESSION_ID", "CODEX_THREAD_ID"] {
            env.removeValue(forKey: key)
        }
        env.merge(extraEnv) { _, new in new }
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd ?? home)
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            guard proc.terminationStatus == 0 else {
                let msg = String(data: errData, encoding: .utf8) ?? ""
                return .failure(BusError(msg.isEmpty ? "agent-bus \(args.first ?? "") failed" : msg))
            }
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func locateCLI() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let candidates = [env["AGENT_BUS_BIN"], "\(home)/.local/bin/agent-bus",
                          "/opt/homebrew/bin/agent-bus", "/usr/local/bin/agent-bus"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct BusError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message.trimmingCharacters(in: .whitespacesAndNewlines) }
    var errorDescription: String? { message }
}
