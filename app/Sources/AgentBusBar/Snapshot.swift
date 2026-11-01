import Foundation

// Mirrors `agent-bus snapshot`. The CLI owns every rule (liveness, ownership,
// lanes, closes, attention); this app only renders what it reports.
struct Snapshot: Decodable {
    var now: Int
    var bus: String
    var seats: [Seat]
    var open: [Item]
    var lanes: [Lane]
    var attention: [Attention]
    var recent: [Event]

    static let empty = Snapshot(now: 0, bus: "", seats: [], open: [], lanes: [], attention: [], recent: [])

    init(now: Int, bus: String, seats: [Seat], open: [Item], lanes: [Lane], attention: [Attention], recent: [Event]) {
        self.now = now; self.bus = bus; self.seats = seats; self.open = open
        self.lanes = lanes; self.attention = attention; self.recent = recent
    }

    // Older CLIs have no lanes/attention; decode them as empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        now = try c.decode(Int.self, forKey: .now)
        bus = try c.decode(String.self, forKey: .bus)
        seats = try c.decode([Seat].self, forKey: .seats)
        open = try c.decode([Item].self, forKey: .open)
        lanes = try c.decodeIfPresent([Lane].self, forKey: .lanes) ?? []
        attention = try c.decodeIfPresent([Attention].self, forKey: .attention) ?? []
        recent = try c.decode([Event].self, forKey: .recent)
    }
    enum CodingKeys: String, CodingKey { case now, bus, seats, open, lanes, attention, recent }
}

struct Seat: Decodable, Identifiable {
    var addr: String
    var tool: String?
    var repo: String?
    var wt: String?
    var branch: String?
    var lane: String
    var lane_src: String?
    var epoch: Int
    var wakeable: Bool
    var wakes: Int?
    var id: String { addr }
}

struct Item: Decodable, Identifiable {
    var id: String
    var epoch: Int
    var from: String?
    var to: String?
    var state: String?
    var subject: String
    var repo: String
    var repo_id: String?
    var lane: String
    var owner: String
    var gone: Bool
    var stale: Bool
    var unread: Bool?
}

struct Lane: Decodable, Identifiable {
    var key: String
    var repo: String
    var repo_id: String
    var lane: String
    var project: String
    var title: String?
    var state: String
    var open: Int
    var gone: Int
    var oldest: Int?
    var last: Int
    var seats: [String]
    var pm: String?
    var branch: String
    var cwd: String?
    var health: String
    var id: String { key }
}

struct Attention: Decodable, Identifiable {
    var kind: String
    var repo: String?
    var repo_id: String?
    var lane: String?
    var id_: String?
    var seat: String?
    var epoch: Int?
    var text: String
    var fix: String
    var id: String { "\(kind)|\(id_ ?? "")|\(lane ?? "")|\(seat ?? "")|\(text)" }

    enum CodingKeys: String, CodingKey { case kind, repo, repo_id, lane, id_ = "id", seat, epoch, text, fix }
}

struct Event: Decodable, Identifiable {
    var kind: String
    var id: String
    var epoch: Int
    var from: String?
    var to: String?
    var state: String?
    var subject: String?
    var repo: String?
    var lane: String?
    var close: String?
    var reason: String?
    var transport: String?
    var status: String?
}

func ago(_ epoch: Int, now: Int) -> String {
    let s = max(0, now - epoch)
    switch s {
    case ..<60: return "\(s)s"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h"
    default: return "\(s / 86400)d"
    }
}
