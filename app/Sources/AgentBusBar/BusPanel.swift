import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case activity = "Activity", work = "Open work", seats = "Seats"
    var id: String { rawValue }
}

struct BusPanel: View {
    @ObservedObject var store: BusStore
    @State private var tab: Tab
    // ImageRenderer can't draw AppKit-backed controls or scroll views, so
    // `--render` lays the list out flat and leaves the controls out.
    private let forImage: Bool

    init(store: BusStore, tab: Tab = .activity, forImage: Bool = false) {
        self.store = store
        self.forImage = forImage
        _tab = State(initialValue: tab)
    }
    @State private var showGone = false

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
                VStack(alignment: .leading, spacing: 6) { list }.frame(height: 440, alignment: .top).clipped()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) { list }.padding(.vertical, 2)
                }
                .frame(height: 440)
                Divider()
                footer
            }
        }
        .padding(12)
        .frame(width: 440)
    }

    @ViewBuilder private var list: some View {
        switch tab {
        case .activity: activity
        case .work: work
        case .seats: seats
        }
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: 14) {
            stat("\(snap.seats.count)", "live seats")
            stat("\(store.liveOpen.count)", "open, owned")
            stat("\(snap.open.count - store.liveOpen.count)", "no live owner",
                 tint: snap.open.contains(where: \.gone) ? .orange : .secondary)
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
            Button("Refresh") { store.refresh() }
            Button("Open bus folder") { NSWorkspace.shared.open(store.busDir) }
            Spacer()
            Text("click a row to copy its id").font(.caption2).foregroundStyle(.tertiary)
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
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
        default:
            var line = "\(e.from ?? "?") → \(e.to ?? "?")"
            if let c = e.close { line += " · closes \(c)" }
            return line
        }
    }

    @ViewBuilder private func eventBadge(_ e: Event) -> some View {
        switch e.kind {
        case "resolve": badge("closed", .green)
        case "delivery": badge("wake", .purple)
        default: badge(e.state ?? "msg", stateColor(e.state))
        }
    }

    // MARK: open work

    @ViewBuilder private var work: some View {
        let items = showGone ? snap.open : store.liveOpen
        if !forImage {
            Toggle("Include items with no live owner (\(snap.open.count - store.liveOpen.count))", isOn: $showGone)
                .toggleStyle(.checkbox).font(.caption)
        }
        if items.isEmpty { empty("No open work with a live owner.") }
        ForEach(groups(items), id: \.key) { group in
            HStack(spacing: 6) {
                Text(group.key).font(.caption.weight(.semibold)).lineLimit(1)
                if group.items.first?.gone == true { badge("GONE", .red) }
            }
            .padding(.top, 4)
            ForEach(group.items) { item in
                row(copy: item.id) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        badge(item.state ?? "", stateColor(item.state))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.subject).font(.callout).lineLimit(2)
                            Text("from \(item.from ?? "?")\(item.lane.isEmpty ? "" : " · @\(item.lane)")")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if item.stale { badge("STALE", .orange) }
                        Text(ago(item.epoch, now: snap.now)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private struct Group { let key: String; let items: [Item] }

    private func groups(_ items: [Item]) -> [Group] {
        let byKey = Dictionary(grouping: items) { "\(repoName($0.repo)) · \($0.owner)" }
        // Live owners first, then by most recent item.
        return byKey.map { Group(key: $0.key, items: $0.value.sorted { $0.epoch > $1.epoch }) }
            .sorted { a, b in
                let ag = a.items.first?.gone ?? false, bg = b.items.first?.gone ?? false
                if ag != bg { return !ag }
                return (a.items.first?.epoch ?? 0) > (b.items.first?.epoch ?? 0)
            }
    }

    // MARK: seats

    @ViewBuilder private var seats: some View {
        if snap.seats.isEmpty { empty("No live seats.") }
        let byRepo = Dictionary(grouping: snap.seats) { repoName($0.repo) }
        ForEach(byRepo.keys.sorted(), id: \.self) { repo in
            Text(repo).font(.caption.weight(.semibold)).padding(.top, 4)
            ForEach(byRepo[repo] ?? []) { seat in
                row(copy: seat.addr) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        badge(seat.tool ?? "?", toolColor(seat.tool))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(seat.addr).font(.callout.monospaced()).lineLimit(1)
                            Text(seat.branch ?? "-").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if !seat.lane.isEmpty { badge("@\(seat.lane)", .teal) }
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

    private func row<Content: View>(copy: String, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy, forType: .string)
            }
            .help("Click to copy \(copy)")
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
        default: return .gray
        }
    }
}
