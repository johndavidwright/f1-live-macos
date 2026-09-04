import Foundation

enum SessionState: String, Sendable {
    case done, live, soon, upcoming
}

struct RaceSession: Identifiable, Hashable, Sendable {
    let key: String
    let shortName: String
    let name: String
    let group: String
    var startAt: Date
    var endAt: Date
    var dateOnly: Bool
    var exactEnd: Bool
    var sessionKey: Int?

    var id: String { key }

    func state(at now: Date) -> SessionState {
        if dateOnly {
            return now > startAt.addingTimeInterval(.day) ? .done : .upcoming
        }
        if now >= endAt { return .done }
        if now >= startAt { return .live }
        if startAt.timeIntervalSince(now) <= .hour { return .soon }
        return .upcoming
    }
}

struct Race: Identifiable, Hashable, Sendable {
    let season: String
    let round: Int
    let name: String
    let wikiURL: URL?
    let circuitID: String
    let circuitName: String
    let circuitURL: URL?
    let locality: String
    let country: String
    let latitude: Double?
    let longitude: Double?
    var sessions: [RaceSession]
    var meetingKey: Int?

    var id: String { "\(season)-\(round)" }
    var raceSession: RaceSession? { sessions.first { $0.key == "race" } }
    var qualifyingSession: RaceSession? { sessions.first { $0.key == "quali" } }
    var raceStartAt: Date { raceSession?.startAt ?? sessions.last?.startAt ?? .distantPast }
    var weekendStartAt: Date { sessions.first?.startAt ?? raceStartAt }
    var weekendEndAt: Date { sessions.last?.endAt ?? raceStartAt }
    var isSprintWeekend: Bool { sessions.contains { $0.key == "sprint" } }
    var fantasyLockSession: RaceSession? {
        let session = isSprintWeekend ? sessions.first { $0.key == "sprint" } : qualifyingSession
        guard session?.dateOnly == false else { return nil }
        return session
    }

    func liveSession(at now: Date) -> RaceSession? {
        sessions.first { $0.state(at: now) == .live }
    }

    func liveFeedSession(at now: Date) -> RaceSession? {
        sessions.first {
            // The calendar can identify an active session even when OpenF1
            // refuses the request that would provide its timing-feed key.
            guard !$0.dateOnly, now >= $0.startAt else { return false }
            let grace = $0.exactEnd ? 30.0 * .minute : 0
            return now <= $0.endAt.addingTimeInterval(grace)
        }
    }

    func nextSession(at now: Date) -> RaceSession? {
        sessions.first { $0.startAt > now }
    }
}

enum WeekendKind: String, Sendable {
    case idle, upcoming, weekend, soon, live, finished
}

struct WeekendStatus: Sendable {
    let label: String
    let kind: WeekendKind
    let session: RaceSession?
}

extension Race {
    func weekendStatus(at now: Date) -> WeekendStatus {
        if let live = liveSession(at: now) {
            let name: String
            switch live.key {
            case "quali": name = "QUALIFYING"
            case "sq": name = "SPRINT QUALIFYING"
            case "sprint": name = "SPRINT"
            default: name = live.shortName
            }
            return WeekendStatus(label: "\(name) LIVE", kind: .live, session: live)
        }
        if let raceSession, now >= raceSession.endAt {
            return WeekendStatus(label: "RACE FINISHED", kind: .finished, session: raceSession)
        }
        if let soon = sessions.first(where: { $0.state(at: now) == .soon }) {
            return WeekendStatus(label: "\(soon.shortName) STARTS SOON", kind: .soon, session: soon)
        }
        if now >= weekendStartAt {
            return WeekendStatus(label: "RACE WEEKEND", kind: .weekend, session: nextSession(at: now))
        }
        return WeekendStatus(label: "NEXT RACE", kind: .upcoming, session: raceSession)
    }
}

struct DriverStanding: Identifiable, Hashable, Sendable {
    let position: Int
    let points: Double
    let wins: Int
    let driverID: String
    let code: String
    let givenName: String
    let familyName: String
    let constructorID: String
    let constructorName: String

    var id: String { driverID }
    var fullName: String { "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces) }
}

struct FavoriteStanding: Identifiable, Sendable {
    let driver: DriverStanding
    let gapToLeader: Double

    var id: String { driver.id }
}

struct QualifyingPosition: Identifiable, Hashable, Sendable {
    let position: Int
    let driverID: String
    let code: String
    let fullName: String
    let familyName: String
    let constructorID: String
    let constructorName: String
    let bestTime: String

    var id: String { driverID }
}

struct QualifyingResult: Sendable {
    let season: String
    let round: Int
    let positions: [QualifyingPosition]
}

struct DashboardData: Sendable {
    let races: [Race]
    let raceIndex: Int
    let standings: [DriverStanding]
    let qualifying: QualifyingResult?
    let raceDistance: Int?
    let stale: Bool
    let lastUpdatedAt: Date
    var liveUnavailableReason: String? = nil

    var race: Race? { races.indices.contains(raceIndex) ? races[raceIndex] : nil }
    var upcoming: [Race] {
        guard raceIndex >= 0 else { return [] }
        return Array(races.dropFirst(raceIndex + 1).prefix(3))
    }
}

struct OpenF1Session: Sendable {
    let sessionKey: Int
    let meetingKey: Int?
    let type: String
    let name: String
    let startAt: Date
    let endAt: Date?
}

struct LiveDriver: Sendable {
    let number: Int
    let acronym: String
    let fullName: String
    let teamName: String
    let teamColour: String
}

struct TimedPosition: Sendable {
    let driverNumber: Int
    let position: Int
    let at: Date?
}

struct TimedInterval: Sendable {
    let driverNumber: Int
    let interval: String?
    let gapToLeader: String?
    let at: Date?
}

struct PitSummary: Sendable {
    var count: Int = 0
    var lastLap: Int?
    var lastDuration: Double?
}

struct RaceControlStatus: Sendable {
    let label: String
    let kind: String
    let at: Date?

    static let running = RaceControlStatus(label: "RUNNING", kind: "green", at: nil)
}

struct LiveBatch: Sendable {
    let positions: [TimedPosition]
    let intervals: [TimedInterval]
    let drivers: [Int: LiveDriver]?
    let pits: [Int: PitSummary]?
    let currentLap: Int?
    let raceControl: RaceControlStatus?
}

struct LiveRow: Identifiable, Sendable {
    let position: Int
    let number: Int
    let acronym: String
    let fullName: String
    let teamName: String
    let teamColour: String
    let interval: String
    let gapToLeader: String
    let pitStops: Int
    let updatedAt: Date?

    var id: Int { number }
}

struct LiveTimingState: Sendable {
    var drivers: [Int: LiveDriver] = [:]
    var positions: [Int: TimedPosition] = [:]
    var intervals: [Int: TimedInterval] = [:]
    var pits: [Int: PitSummary] = [:]
    var currentLap = 0
    var status = RaceControlStatus.running
    var lastUpdateAt: Date?
    var lastPollAt: Date?
    var lastDetailPollAt: Date?
    var consecutiveEmptyPolls = 0

    func needsDetailRefresh(at now: Date) -> Bool {
        guard !drivers.isEmpty, let lastDetailPollAt else { return true }
        return now.timeIntervalSince(lastDetailPollAt) >= 55
    }

    func freshnessWarning(at now: Date, refreshSeconds: Int) -> String? {
        if consecutiveEmptyPolls >= 3 {
            return "Timing delayed · no data in the last few polls."
        }
        guard !positions.isEmpty else { return nil }
        guard let lastUpdateAt else {
            return "Timing freshness unknown · timestamps unavailable."
        }
        if now.timeIntervalSince(lastUpdateAt) >= TimeInterval(max(60, refreshSeconds * 3)) {
            return "Timing delayed · last data \(F1Formatting.ago(lastUpdateAt, now: now))."
        }
        return nil
    }

    var rows: [LiveRow] {
        positions.values.compactMap { item -> LiveRow? in
            let number = item.driverNumber
            let driver = drivers[number]
            let split = intervals[number]
            let pit = pits[number] ?? PitSummary()
            return LiveRow(
                position: item.position,
                number: number,
                acronym: driver?.acronym.nonEmpty ?? "#\(number)",
                fullName: driver?.fullName ?? "",
                teamName: driver?.teamName ?? "",
                teamColour: driver?.teamColour ?? "",
                interval: Self.gapText(split?.interval, leader: item.position == 1),
                gapToLeader: Self.gapText(split?.gapToLeader, leader: item.position == 1),
                pitStops: pit.count,
                updatedAt: [split?.at, item.at].compactMap { $0 }.max()
            )
        }.sorted { $0.position < $1.position }
    }

    mutating func merge(_ batch: LiveBatch, polledAt: Date, includedDetails: Bool = false) {
        for item in batch.positions {
            if let oldAt = positions[item.driverNumber]?.at, item.at == nil || item.at! < oldAt { continue }
            positions[item.driverNumber] = item
        }
        for item in batch.intervals {
            if let oldAt = intervals[item.driverNumber]?.at, item.at == nil || item.at! < oldAt { continue }
            intervals[item.driverNumber] = item
        }
        if let incoming = batch.drivers, !incoming.isEmpty { drivers = incoming }
        if let incoming = batch.pits { pits = incoming }
        if let lap = batch.currentLap { currentLap = max(currentLap, lap) }
        if let control = batch.raceControl { status = control }
        lastPollAt = polledAt
        if includedDetails { lastDetailPollAt = polledAt }

        // A successful request is not proof of fresh data: overlapping query
        // windows can keep returning the same old rows, or an empty response.
        let newest = (positions.values.compactMap(\.at) + intervals.values.compactMap(\.at)).max()
        if let newest { lastUpdateAt = max(lastUpdateAt ?? .distantPast, newest) }
        if batch.positions.isEmpty && batch.intervals.isEmpty { consecutiveEmptyPolls += 1 }
        else { consecutiveEmptyPolls = 0 }
    }

    static func gapText(_ raw: String?, leader: Bool) -> String {
        if leader { return "LEADER" }
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "—" }
        if let number = Double(raw) { return String(format: "+%.3f", number) }
        return raw.uppercased()
    }
}

extension TimeInterval {
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

enum F1Formatting {
    static func time(_ date: Date, twelveHour: Bool) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).hour(twelveHour ? .defaultDigits(amPM: .abbreviated) : .twoDigits(amPM: .omitted)))
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).year())
    }

    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated)).uppercased()
    }

    static func dateRange(_ start: Date, _ end: Date) -> String {
        let startText = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let endText = end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(startText) – \(endText)"
    }

    static func countdown(to date: Date, from now: Date, compact: Bool = false) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if compact {
            if days > 0 { return "\(days)d \(hours)h" }
            if hours > 0 { return "\(hours)h \(minutes)m" }
            return "\(minutes)m"
        }
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "just now" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

enum TeamColours {
    static let known: [String: String] = [
        "mclaren": "#ff8000", "ferrari": "#e8002d", "mercedes": "#27f4d2",
        "red_bull": "#3671c6", "williams": "#64c4ff", "aston_martin": "#229971",
        "alpine": "#ff87bc", "haas": "#b6babd", "rb": "#6692ff", "sauber": "#52e252",
        "audi": "#009597", "cadillac": "#c8b273"
    ]

    static func hex(constructorID: String, name: String, live: String = "") -> String {
        let live = live.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if live.range(of: "^[0-9a-fA-F]{6}$", options: .regularExpression) != nil { return "#\(live)" }
        if let exact = known[constructorID.lowercased()] { return exact }
        let aliases = ["red bull racing": "red_bull", "aston martin": "aston_martin", "racing bulls": "rb", "kick sauber": "sauber"]
        if let alias = aliases[name.lowercased()], let colour = known[alias] { return colour }
        return "#8a8f98"
    }
}

enum CircuitMaps {
    static let byID: [String: String] = [
        "albert_park": "melbourne-2.svg", "americas": "austin-1.svg", "bahrain": "bahrain-1.svg",
        "baku": "baku-1.svg", "catalunya": "catalunya-6.svg", "hungaroring": "hungaroring-3.svg",
        "interlagos": "interlagos-2.svg", "jeddah": "jeddah-1.svg", "losail": "lusail-1.svg",
        "madring": "madring-1.svg", "marina_bay": "marina-bay-4.svg", "miami": "miami-1.svg",
        "monaco": "monaco-6.svg", "monza": "monza-7.svg", "red_bull_ring": "spielberg-3.svg",
        "rodriguez": "mexico-city-3.svg", "sepang": "sepang-1.svg", "shanghai": "shanghai-1.svg",
        "silverstone": "silverstone-8.svg", "spa": "spa-francorchamps-4.svg", "suzuka": "suzuka-2.svg",
        "vegas": "las-vegas-1.svg", "villeneuve": "montreal-6.svg", "yas_marina": "yas-marina-2.svg",
        "zandvoort": "zandvoort-5.svg"
    ]

    static func filename(for race: Race) -> String? { byID[race.circuitID] }
}
