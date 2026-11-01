import Foundation

// Runs `agent-bus snapshot` whenever the ledger or seat registry changes, and
// on a slow timer so ages and liveness stay current. Never writes to the bus.
@MainActor
final class BusStore: ObservableObject {
    @Published private(set) var snapshot = Snapshot.empty
    @Published private(set) var error: String?

    let busDir: URL
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var running = false

    init() {
        let env = ProcessInfo.processInfo.environment
        busDir = URL(fileURLWithPath: env["AGENT_BUS_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".agents/bus"))
        watch()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Items whose owner is a live seat: the work actually in flight.
    var liveOpen: [Item] { snapshot.open.filter { !$0.gone } }

    func refresh() {
        guard !running else { return }
        running = true
        Task.detached(priority: .utility) {
            let result = Self.runSnapshot()
            await MainActor.run {
                self.running = false
                switch result {
                case .success(let snap): self.snapshot = snap; self.error = nil
                case .failure(let err): self.error = err.localizedDescription
                }
            }
        }
    }

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

    private nonisolated static func runSnapshot() -> Result<Snapshot, Error> {
        guard let bin = locateCLI() else {
            return .failure(BusError("agent-bus not found — set AGENT_BUS_BIN or link it into ~/.local/bin"))
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["snapshot"]
        // Launched from Finder the app gets a bare PATH; the CLI needs bash, jq, git.
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: home)
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return .failure(BusError(msg.isEmpty ? "agent-bus snapshot failed" : msg))
            }
            return .success(try JSONDecoder().decode(Snapshot.self, from: data))
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
