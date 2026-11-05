import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case attention = "Attention", lanes = "Lanes", activity = "Activity", seats = "Seats"
    var id: String { rawValue }
}

enum LaneFilter: String, CaseIterable, Identifiable {
    case active = "Active", cleanup = "Needs cleanup", all = "All"
    var id: String { rawValue }
}

struct BusPanel: View {
    @ObservedObject var store: BusStore
    @State private var tab: Tab
    @State private var laneFilter: LaneFilter = .active
    @State private var expanded: Set<String> = []
    @State private var showAllOrphans = false
    @State private var drafts: [String: String] = [:]
    @State private var recordDecision: Set<String> = []
    // ImageRenderer can't draw AppKit-backed controls or scroll views, so
    // `--render` lays the list out flat and leaves the controls out.
    private let forImage: Bool

    init(store: BusStore, tab: Tab = .attention, forImage: Bool = false) {
        self.store = store
        self.forImage = forImage
        _tab = State(initialValue: tab)
    }

    private var snap: Snapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if forImage {
                Text(tab.rawValue).font(.headline)
            } else {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            if forImage {
                VStack(alignment: .leading, spacing: 6) { list }.frame(height: 520, alignment: .top).clipped()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) { list }.padding(.vertical, 2)
                }
                .frame(height: 520)
                Divider()
                footer
            }
        }
        .padding(12)
        .frame(width: 480)
    }

    @ViewBuilder private var list: some View {
        switch tab {
        case .attention: attentionTab
        case .lanes: lanesTab
        case .activity: activity
        case .seats: seats
        }
    }

    // MARK: header / footer

    private var header: some View {
        let needs = store.attention(BusStore.needsYou).count
        let stuck = store.attention(BusStore.stuck).count
        let cleanup = store.attention(BusStore.cleanup).count
        let active = snap.lanes.filter { $0.health == "active" }.count
        return HStack(spacing: 16) {
            stat("\(needs)", "need you", tint: needs > 0 ? .red : .secondary)
            stat("\(stuck)", "stuck", tint: stuck > 0 ? .orange : .secondary)
            stat("\(cleanup)", "to clean up", tint: cleanup > 0 ? .yellow : .secondary)
            stat("\(active)", "active lanes")
            stat("\(snap.seats.count)", "live agents")
            Spacer()
        }
    }

    private func stat(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") { store.refresh(); store.checkMerged() }
            Button("Open bus folder") { NSWorkspace.shared.open(store.busDir) }
            Spacer()
            if let msg = store.lastAction {
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    // MARK: attention

    @ViewBuilder private var attentionTab: some View {
        let needs = store.attention(["needs-you"])
        let reviews = store.attention(["review"])
        let stuck = store.attention(BusStore.stuck)
        let merged = store.attention(["merged"])
        let orphaned = store.attention(["orphaned"])
        let unfiled = store.attention(["unfiled"])
        if needs.isEmpty && reviews.isEmpty && stuck.isEmpty && merged.isEmpty && orphaned.isEmpty && unfiled.isEmpty {
            empty("Nothing needs you. Agents ask for you with --to @lead.")
        }

        if !needs.isEmpty {
            section("Needs you", "Agents asked for a decision (posted --to @lead). Your answer goes back to them.")
            ForEach(needs) { a in
                card(tint: .red) {
                    Text(a.text).font(.callout)
                    meta(a)
                    if !forImage {
                        TextField("Your answer", text: draft(a.id), axis: .vertical)
                            .textFieldStyle(.roundedBorder).font(.callout).lineLimit(1...4)
                    }
                    HStack {
                        actionButton("Answer") { answer(a) }
                        if !forImage {
                            Toggle("Record as decision", isOn: Binding(
                                get: { recordDecision.contains(a.id) },
                                set: { if $0 { recordDecision.insert(a.id) } else { recordDecision.remove(a.id) } }))
                                .toggleStyle(.checkbox).font(.caption)
                        }
                        actionButton("Dismiss") { store.act(["resolve", a.id_ ?? "", "--reason", "canceled"], label: "Dismissed") }
                    }
                }
            }
        }

        if !reviews.isEmpty {
            section("To review", "Finished work that waits for your approval.")
            ForEach(reviews) { a in
                card(tint: .purple) {
                    Text(a.text).font(.callout).lineLimit(3)
                    meta(a)
                    if !forImage {
                        TextField("What to fix (for Request changes)", text: draft(a.id), axis: .vertical)
                            .textFieldStyle(.roundedBorder).font(.callout).lineLimit(1...4)
                    }
                    HStack {
                        actionButton("Approve") { store.act(["review", a.id_ ?? "", "--approve"], label: "Approved") }
                        actionButton("Request changes") {
                            let note = (drafts[a.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !note.isEmpty else { return }
                            store.act(["review", a.id_ ?? "", "--changes", "-m", note], label: "Sent back")
                            drafts[a.id] = nil
                        }
                        copyButton(a.id_ ?? "", "Copy id")
                    }
                }
            }
        }

        if !stuck.isEmpty {
            section("Stuck", "Work that is not moving: unread by a live owner, blocked, or an agent that can't be woken.")
            ForEach(stuck) { a in
                card(tint: .orange) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        badge(label(a.kind), .orange)
                        Text(a.text).font(.callout).lineLimit(3)
                    }
                    meta(a)
                    fixLine(a.fix)
                }
            }
        }

        if !merged.isEmpty {
            section("Finished but still open", "The lane's branch is merged; its work items were never closed.")
            ForEach(merged) { a in
                card(tint: .green) {
                    Text(a.text).font(.callout).lineLimit(2)
                    meta(a)
                    HStack {
                        let lane = store.lane(repo: a.repo, name: a.lane)
                        actionButton("Close lane") {
                            store.act(["lane", a.lane ?? "", "done", "--reason", "merged"], lane: lane, label: "Closed @\(a.lane ?? "")")
                        }
                    }
                }
            }
            if merged.count > 1 {
                actionButton("Close all \(merged.count) merged lanes") {
                    confirm("Close \(merged.count) merged lanes?", "Every open work item in them is closed with reason \"merged\".") {
                        store.actAll(merged.map { (["lane", $0.lane ?? "", "done", "--reason", "merged"],
                                                   store.lane(repo: $0.repo, name: $0.lane)) }, label: "Merged lanes closed")
                    }
                }
            }
        }

        if !orphaned.isEmpty {
            let items = orphaned.compactMap { store.lane(repo: $0.repo, name: $0.lane) }
            let count = items.map(\.open).reduce(0, +)
            section("Abandoned lanes", "\(orphaned.count) lanes with open work and nobody on them for over a day — \(count) items.")
            HStack {
                actionButton("Close all \(orphaned.count)…") {
                    confirm("Close \(orphaned.count) abandoned lanes?",
                            "Their \(count) open work items are closed with reason \"canceled\". New work in a lane stays open.") {
                        store.actAll(orphaned.map { (["lane", $0.lane ?? "", "done", "--reason", "canceled"],
                                                     store.lane(repo: $0.repo, name: $0.lane)) }, label: "Abandoned lanes closed")
                    }
                }
                if !forImage {
                    Button(showAllOrphans ? "Show fewer" : "Show all") { showAllOrphans.toggle() }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            ForEach(showAllOrphans ? items : Array(items.prefix(8))) { lane in
                laneRow(lane)
            }
        }

        if !unfiled.isEmpty {
            section("Unfiled", "Work that belongs to no lane (sent from develop/main with no ticket).")
            ForEach(unfiled) { a in
                card(tint: .gray) {
                    Text(a.text).font(.callout)
                    HStack {
                        let lane = store.lane(repo: a.repo, name: "unfiled")
                        actionButton("Close items older than 7d") {
                            store.act(["lane", "unfiled", "sweep", "--older", "7d", "--reason", "canceled"], lane: lane,
                                      label: "Unfiled swept")
                        }
                        fixLine("agent-bus file <id> <lane>")
                    }
                }
            }
        }
    }

    private func draft(_ key: String) -> Binding<String> {
        Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })
    }

    /// Reply to the agent that asked, closing its question; optionally record
    /// the answer as the lane's decision so later sessions follow it.
    private func answer(_ a: Attention) {
        let text = (drafts[a.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = a.id_, let to = a.from else { return }
        let lane = store.lane(repo: a.repo, name: a.lane)
        var steps: [(args: [String], lane: Lane?)] = [
            (["post", "--re", id, "--close", "done", "--to", to, "--state", "done", "-m", text], lane)]
        if recordDecision.contains(a.id) {
            var decide = ["decide", text]
            if let l = a.lane, l != "unfiled", !l.isEmpty { decide += ["--lane", l] } else { decide += ["--repo-wide"] }
            steps.append((decide, lane))
        }
        store.actAll(steps, label: recordDecision.contains(a.id) ? "Answered and recorded" : "Answered")
        drafts[a.id] = nil
        recordDecision.remove(a.id)
    }

    private func label(_ kind: String) -> String {
        switch kind {
        case "not-picked-up": return "unread"
        case "blocked": return "blocked"
        case "budget": return "no wakes left"
        case "wake-failed": return "wake failed"
        case "pm-gone": return "PM gone"
        default: return kind
        }
    }

    // MARK: lanes

    @ViewBuilder private var lanesTab: some View {
        if !forImage {
            Picker("", selection: $laneFilter) {
                ForEach(LaneFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        }
        let lanes = snap.lanes.filter { lane in
            switch laneFilter {
            case .active: return ["active", "idle"].contains(lane.health)
            case .cleanup: return ["merged", "orphaned", "unfiled"].contains(lane.health)
            case .all: return lane.health != "quiet"
            }
        }
        if lanes.isEmpty { empty(laneFilter == .active ? "No lane is being worked on right now." : "No lanes.") }
        let byProject = Dictionary(grouping: lanes, by: \.project)
        ForEach(byProject.keys.sorted(), id: \.self) { project in
            Text(project).font(.caption.weight(.semibold)).padding(.top, 4)
            ForEach((byProject[project] ?? []).sorted { $0.last > $1.last }) { lane in
                laneRow(lane)
            }
        }
    }

    private func laneRow(_ lane: Lane) -> some View {
        let isOpen = expanded.contains(lane.key) || forImage && lane.health == "active"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                badge(lane.health, healthColor(lane.health))
                VStack(alignment: .leading, spacing: 1) {
                    Text(lane.title.map { "@\(lane.lane) — \($0)" } ?? "@\(lane.lane)")
                        .font(.callout.weight(.medium)).lineLimit(1)
                    Text(laneMeta(lane)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(ago(lane.last, now: snap.now)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            if isOpen {
                let items = snap.open.filter { $0.lane == lane.lane && $0.repo_id == lane.repo_id }.sorted { $0.epoch > $1.epoch }
                ForEach(items.prefix(12)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        badge(item.state ?? "", stateColor(item.state))
                        Text(item.subject).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(item.gone ? "\(item.owner) (gone)" : item.owner)
                            .font(.caption2.monospaced()).foregroundStyle(item.gone ? .red : .secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { copy(item.id) }
                    .help("Click to copy \(item.id)")
                }
                if items.count > 12 { Text("…and \(items.count - 12) more").font(.caption2).foregroundStyle(.secondary) }
                ForEach(lane.decisions ?? []) { d in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        badge("decided", .purple)
                        Text(d.text).font(.caption).lineLimit(2)
                    }
                    .help(d.why ?? "")
                }
                if !lane.seats.isEmpty {
                    Text("agents: \(lane.seats.joined(separator: ", "))").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                HStack {
                    if lane.open > 0 {
                        actionButton("Close lane") {
                            confirm("Close @\(lane.lane)?", "Its \(lane.open) open work item(s) are closed with reason \"done\".") {
                                store.act(["lane", lane.lane, "done", "--reason", "done"], lane: lane, label: "Closed @\(lane.lane)")
                            }
                        }
                    }
                    if lane.health == "parked" {
                        actionButton("Reopen") { store.act(["lane", lane.lane, "reopen"], lane: lane, label: "Reopened @\(lane.lane)") }
                    } else {
                        actionButton("Park") { store.act(["lane", lane.lane, "park"], lane: lane, label: "Parked @\(lane.lane)") }
                    }
                }
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded.contains(lane.key) { expanded.remove(lane.key) } else { expanded.insert(lane.key) }
        }
    }

    private func laneMeta(_ lane: Lane) -> String {
        var parts = ["\(lane.open) open"]
        if lane.gone > 0 && lane.gone < lane.open { parts.append("\(lane.gone) ownerless") }
        parts.append(lane.seats.isEmpty ? "nobody on it" : "\(lane.seats.count) agent\(lane.seats.count == 1 ? "" : "s")")
        if !lane.branch.isEmpty { parts.append(lane.branch) }
        if lane.pm != nil { parts.append("PM") }
        return parts.joined(separator: " · ")
    }

    // MARK: activity

    @ViewBuilder private var activity: some View {
        if snap.recent.isEmpty { empty("No activity yet.") }
        ForEach(snap.recent) { e in
            row(copy: e.id) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    eventBadge(e)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(eventLine(e)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        if let s = e.subject, !s.isEmpty { Text(s).font(.callout).lineLimit(2) }
                    }
                    Spacer(minLength: 4)
                    Text(ago(e.epoch, now: snap.now)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func eventLine(_ e: Event) -> String {
        switch e.kind {
        case "resolve": return "\(e.from ?? "?") closed it (\(e.reason ?? ""))"
        case "delivery": return "→ \(e.to ?? "?") via \(e.transport ?? "?"): \(e.status ?? "")"
        case "lane":
            let why = (e.reason ?? "").isEmpty ? "" : " (\(e.reason ?? ""))"
            return "\(e.from ?? "?") · @\(e.lane ?? "") \(e.state ?? "updated")\(why)"
        case "file": return "\(e.from ?? "?") filed it in @\(e.lane ?? "")"
        case "decision":
            let scope = (e.lane ?? "").isEmpty ? "repo" : "@\(e.lane ?? "")"
            return "\(e.from ?? "?") decided for \(scope)"
        default:
            var line = "\(e.from ?? "?") → \(e.to ?? "?")"
            if let l = e.lane, !l.isEmpty, l != "unfiled" { line += " · @\(l)" }
            if let c = e.close { line += " · closes \(c)" }
            return line
        }
    }

    @ViewBuilder private func eventBadge(_ e: Event) -> some View {
        switch e.kind {
        case "resolve": badge("closed", .green)
        case "delivery": badge("wake", .purple)
        case "lane": badge("lane", .teal)
        case "file": badge("filed", .teal)
        case "decision": badge("decided", .purple)
        default: badge(e.state ?? "msg", stateColor(e.state))
        }
    }

    // MARK: seats

    @ViewBuilder private var seats: some View {
        if snap.seats.isEmpty { empty("No live agents.") }
        let byRepo = Dictionary(grouping: snap.seats) { repoName($0.repo) }
        ForEach(byRepo.keys.sorted(), id: \.self) { repo in
            Text(repo).font(.caption.weight(.semibold)).padding(.top, 4)
            ForEach(byRepo[repo] ?? []) { seat in
                row(copy: seat.addr) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        badge(seat.tool ?? "?", toolColor(seat.tool))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(seat.lane.isEmpty ? seat.addr : "@\(seat.lane)").font(.callout.monospaced()).lineLimit(1)
                            Text(seat.lane.isEmpty ? (seat.branch ?? "-") : "\(seat.addr) · \(seat.branch ?? "-")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if seat.wakeable {
                            Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow)
                                .help("can be woken while idle")
                        }
                        Text(ago(seat.epoch, now: snap.now)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: pieces

    private func repoName(_ repo: String?) -> String {
        guard let repo, repo != "-", !repo.isEmpty else { return "(no repo)" }
        return repo
    }

    private func section(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private func card<Content: View>(tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) { content() }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.07)))
            .overlay(alignment: .leading) { Rectangle().fill(tint.opacity(0.6)).frame(width: 2) }
    }

    private func meta(_ a: Attention) -> some View {
        let parts = [a.repo.map(repoName), a.lane.map { "@\($0)" }, a.epoch.map { ago($0, now: snap.now) + " ago" }]
            .compactMap { $0 }
        return Text(parts.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
    }

    private func fixLine(_ fix: String) -> some View {
        HStack(spacing: 4) {
            Text(fix).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            copyButton(fix, "Copy")
        }
    }

    @ViewBuilder private func actionButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        if forImage {
            Text(title).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().stroke(Color.secondary.opacity(0.5)))
        } else {
            Button(title, action: action).controlSize(.small)
        }
    }

    @ViewBuilder private func copyButton(_ text: String, _ title: String) -> some View {
        if !forImage {
            Button(title) { copy(text) }.buttonStyle(.borderless).font(.caption2)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func confirm(_ title: String, _ detail: String, _ action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Close them")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }

    private func row<Content: View>(copy text: String, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
            .onTapGesture { copy(text) }
            .help("Click to copy \(text)")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
            .fixedSize()
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 20).frame(maxWidth: .infinity)
    }

    private func healthColor(_ health: String) -> Color {
        switch health {
        case "active": return .green
        case "idle": return .blue
        case "merged": return .mint
        case "orphaned": return .orange
        default: return .gray
        }
    }

    private func stateColor(_ state: String?) -> Color {
        switch state {
        case "needs-review": return .blue
        case "blocked": return .red
        case "handoff": return .indigo
        case "question": return .orange
        case "done": return .green
        default: return .gray
        }
    }

    private func toolColor(_ tool: String?) -> Color {
        switch tool {
        case "claude": return .orange
        case "opencode": return .blue
        case "codex": return .green
        case "grok": return .pink
        case "lead": return .red
        default: return .gray
        }
    }
}
