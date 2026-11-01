import Foundation

// Mirrors `agent-bus snapshot`. The CLI owns every rule (liveness, ownership,
// closes); this app only renders what it reports.
struct Snapshot: Decodable {
    var now: Int
    var bus: String
    var seats: [Seat]
    var open: [Item]
    var recent: [Event]

    static let empty = Snapshot(now: 0, bus: "", seats: [], open: [], recent: [])
}

struct Seat: Decodable, Identifiable {
    var addr: String
    var tool: String?
    var repo: String?
    var wt: String?
    var branch: String?
    var lane: String
    var epoch: Int
    var wakeable: Bool
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
    var lane: String
    var owner: String
    var gone: Bool
    var stale: Bool
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
