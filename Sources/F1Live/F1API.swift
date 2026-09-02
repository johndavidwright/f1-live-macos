import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum F1APIError: LocalizedError {
    case invalidURL
    case badResponse
    case oversizedResponse
    case noData(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The F1 service URL is invalid."
        case .badResponse: return "The F1 data service returned an invalid response."
        case .oversizedResponse: return "The F1 data response exceeded the safety limit."
        case .noData(let message): return message
        }
    }
}

struct HTTPPayload: Sendable {
    let data: Data
    let fetchedAt: Date
    let stale: Bool
}

actor CachedHTTPClient {
    private let session: URLSession
    private let cacheDirectory: URL
    private let maximumBytes = 5 * 1_024 * 1_024

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "F1Live-macOS/1.0"]
        session = URLSession(configuration: configuration)

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = base.appendingPathComponent("F1Live", isDirectory: true)
    }

    func get(_ url: URL, cacheKey: String, ttl: TimeInterval, force: Bool = false) async throws -> HTTPPayload {
        let cacheURL = cacheDirectory.appendingPathComponent(safeFilename(cacheKey)).appendingPathExtension("json")
        let cached = readCache(at: cacheURL)
        if !force, let cached, Date().timeIntervalSince(cached.fetchedAt) < ttl {
            return cached
        }

        do {
            guard url.scheme == "https", ["api.jolpi.ca", "api.openf1.org"].contains(url.host) else {
                throw F1APIError.invalidURL
            }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw F1APIError.badResponse
            }
            guard data.count <= maximumBytes else { throw F1APIError.oversizedResponse }
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            return HTTPPayload(data: data, fetchedAt: Date(), stale: false)
        } catch {
            if let cached { return HTTPPayload(data: cached.data, fetchedAt: cached.fetchedAt, stale: true) }
            throw error
        }
    }

    func live(_ url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "api.openf1.org" else { throw F1APIError.invalidURL }
        for attempt in 0...1 {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw F1APIError.badResponse }
            if http.statusCode == 404 { return Data("[]".utf8) }
            if http.statusCode == 429, attempt == 0 {
                try await Task.sleep(for: .milliseconds(750))
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw F1APIError.badResponse }
            guard data.count <= 2 * 1_024 * 1_024 else { throw F1APIError.oversizedResponse }
            return data
        }
        throw F1APIError.badResponse
    }

    private func readCache(at url: URL) -> HTTPPayload? {
        guard let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return HTTPPayload(data: data, fetchedAt: values?.contentModificationDate ?? .distantPast, stale: false)
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    }
}

final class F1API: @unchecked Sendable {
    private let client: CachedHTTPClient
    private let decoder = JSONDecoder()
    private let base = "https://api.jolpi.ca/ergast/f1"

    init(client: CachedHTTPClient = CachedHTTPClient()) {
        self.client = client
    }

    func loadDashboard(refreshMinutes: Int, force: Bool = false, now: Date = Date()) async throws -> DashboardData {
        var calendarPayload = try await fetch("\(base)/current/races/?format=json&limit=100", key: "calendar-current", ttl: 12 * .hour, force: force)
        var races = try parseRaces(calendarPayload.data)
        guard !races.isEmpty else { throw F1APIError.noData("The season calendar is empty.") }

        var raceIndex = Self.currentRaceIndex(in: races, at: now)
        if raceIndex < 0, let year = Int(races.last?.season ?? "") {
            if let next = try? await fetch("\(base)/\(year + 1)/races/?format=json&limit=100", key: "calendar-\(year + 1)", ttl: 12 * .hour, force: force),
               let parsed = try? parseRaces(next.data), !parsed.isEmpty {
                calendarPayload = next
                races = parsed
                raceIndex = Self.currentRaceIndex(in: races, at: now)
            }
        }

        let season = races.first?.season ?? String(Calendar.current.component(.year, from: now))
        async let sessionsPayload = try? fetch("https://api.openf1.org/v1/sessions?year=\(season)", key: "openf1-sessions-\(season)", ttl: 6 * .hour, force: force)
        async let standingsPayload = try? fetch("\(base)/\(season)/driverstandings/?format=json&limit=100", key: "driver-standings-\(season)", ttl: TimeInterval(max(5, refreshMinutes)) * .minute, force: force)
        let (sessionResult, standingsResult) = await (sessionsPayload, standingsPayload)

        if let sessionResult, let openSessions = try? parseOpenF1Sessions(sessionResult.data) {
            races = races.map { Self.refine($0, with: openSessions) }
            raceIndex = Self.currentRaceIndex(in: races, at: now)
        }
        let standings = (try? standingsResult.map { try parseStandings($0.data) }) ?? []

        var qualifying: QualifyingResult?
        var distance: Int?
        var detailPayloads: [HTTPPayload] = []
        if races.indices.contains(raceIndex) {
            let race = races[raceIndex]
            async let qualifyingPayload: HTTPPayload? = {
                guard let session = race.qualifyingSession, session.state(at: now) == .done else { return nil }
                return try? await self.fetch("\(self.base)/\(season)/\(race.round)/qualifying/?format=json", key: "qualifying-\(season)-\(race.round)", ttl: 15 * .minute, force: force)
            }()
            async let distancePayload = try? fetch("\(base)/circuits/\(race.circuitID)/results/1/?format=json&limit=100", key: "distance-\(race.circuitID)", ttl: 30 * .day, force: force)
            let (qPayload, dPayload) = await (qualifyingPayload, distancePayload)
            if let qPayload {
                qualifying = try? parseQualifying(qPayload.data)
                detailPayloads.append(qPayload)
            }
            if let dPayload {
                distance = try? parseRaceDistance(dPayload.data)
                detailPayloads.append(dPayload)
            }
        }

        let payloads = [calendarPayload, sessionResult, standingsResult].compactMap { $0 } + detailPayloads
        return DashboardData(
            races: races,
            raceIndex: raceIndex,
            standings: standings,
            qualifying: qualifying,
            raceDistance: distance,
            stale: payloads.contains(where: \.stale),
            lastUpdatedAt: payloads.map(\.fetchedAt).max() ?? now
        )
    }

    func loadLive(sessionKey: Int, refreshSeconds: Int, currentLap: Int, includeSlow: Bool, now: Date = Date()) async throws -> LiveBatch {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let upper = formatter.string(from: now.addingTimeInterval(1))
        let positionLower = formatter.string(from: now.addingTimeInterval(-20 * .minute))
        let intervalWindow = TimeInterval(max(20, refreshSeconds * 2 + 5))
        let intervalLower = formatter.string(from: now.addingTimeInterval(-intervalWindow))

        // OpenF1's public endpoint applies a shared request budget. Keep these
        // calls sequential, matching the upstream plugin's batched shell loop.
        let positionData = try await client.live(try makeOpenF1URL("position", ["session_key": "\(sessionKey)", "date>": positionLower, "date<": upper]))
        let intervalData = try await client.live(try makeOpenF1URL("intervals", ["session_key": "\(sessionKey)", "date>": intervalLower, "date<": upper]))

        if includeSlow {
            let controlLower = formatter.string(from: now.addingTimeInterval(-45 * .minute))
            let driverData = try await client.live(try makeOpenF1URL("drivers", ["session_key": "\(sessionKey)"]))
            let pitData = try await client.live(try makeOpenF1URL("pit", ["session_key": "\(sessionKey)"]))
            let controlData = try await client.live(try makeOpenF1URL("race_control", ["session_key": "\(sessionKey)", "date>": controlLower, "date<": upper]))
            let lapData = try await client.live(try makeOpenF1URL("laps", ["session_key": "\(sessionKey)", "lap_number>": "\(max(1, currentLap))"]))
            return LiveBatch(
                positions: try parsePositions(positionData),
                intervals: try parseIntervals(intervalData),
                drivers: try parseDrivers(driverData),
                pits: try parsePits(pitData),
                currentLap: try parseCurrentLap(lapData),
                raceControl: try parseRaceControl(controlData)
            )
        }

        return LiveBatch(
            positions: try parsePositions(positionData),
            intervals: try parseIntervals(intervalData),
            drivers: nil,
            pits: nil,
            currentLap: nil,
            raceControl: nil
        )
    }

    private func fetch(_ string: String, key: String, ttl: TimeInterval, force: Bool) async throws -> HTTPPayload {
        guard let url = URL(string: string) else { throw F1APIError.invalidURL }
        return try await client.get(url, cacheKey: key, ttl: ttl, force: force)
    }

    private func makeOpenF1URL(_ path: String, _ items: [String: String]) throws -> URL {
        var parts = URLComponents(string: "https://api.openf1.org/v1/\(path)")
        parts?.queryItems = items.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        guard let url = parts?.url else { throw F1APIError.invalidURL }
        return url
    }

    static func currentRaceIndex(in races: [Race], at now: Date) -> Int {
        races.firstIndex {
            let end = $0.raceSession?.endAt ?? $0.raceStartAt
            return now < end.addingTimeInterval(.day)
        } ?? -1
    }

    static func refine(_ race: Race, with openSessions: [OpenF1Session]) -> Race {
        var result = race
        var meetingKey: Int?
        result.sessions = race.sessions.map { scheduled in
            let candidates = openSessions.filter { sessionTypesMatch(scheduled, $0) }
            guard let best = candidates.min(by: {
                abs($0.startAt.timeIntervalSince(scheduled.startAt)) < abs($1.startAt.timeIntervalSince(scheduled.startAt))
            }), abs(best.startAt.timeIntervalSince(scheduled.startAt)) < 6 * .hour else { return scheduled }
            meetingKey = meetingKey ?? best.meetingKey
            var updated = scheduled
            updated.startAt = best.startAt
            updated.endAt = best.endAt ?? scheduled.endAt
            updated.dateOnly = false
            updated.exactEnd = best.endAt != nil
            updated.sessionKey = best.sessionKey
            return updated
        }.sorted { $0.startAt < $1.startAt }
        result.meetingKey = meetingKey
        return result
    }

    private static func sessionTypesMatch(_ scheduled: RaceSession, _ live: OpenF1Session) -> Bool {
        let name = live.name.lowercased()
        let type = live.type.lowercased()
        switch scheduled.key {
        case "fp1": return name == "practice 1"
        case "fp2": return name == "practice 2"
        case "fp3": return name == "practice 3"
        case "quali": return type == "qualifying" && !name.contains("sprint")
        case "sq": return name.contains("sprint") && (name.contains("qualif") || name.contains("shootout"))
        case "sprint": return name == "sprint" || (type == "race" && name.contains("sprint"))
        case "race": return type == "race" && !name.contains("sprint")
        default: return false
        }
    }
}

// MARK: - API decoding

private extension F1API {
    struct RacesEnvelope: Decodable { let MRData: RaceMRData }
    struct RaceMRData: Decodable { let RaceTable: RaceTable }
    struct RaceTable: Decodable { let Races: [RaceDTO] }
    struct RaceDTO: Decodable {
        let season: String
        let round: String
        let raceName: String
        let url: String?
        let Circuit: CircuitDTO
        let date: String
        let time: String?
        let FirstPractice: StampDTO?
        let SecondPractice: StampDTO?
        let ThirdPractice: StampDTO?
        let SprintQualifying: StampDTO?
        let SprintShootout: StampDTO?
        let Sprint: StampDTO?
        let Qualifying: StampDTO?
        let Results: [RaceResultDTO]?
    }
    struct CircuitDTO: Decodable {
        let circuitId: String
        let circuitName: String
        let url: String?
        let Location: LocationDTO
    }
    struct LocationDTO: Decodable { let lat: String?; let long: String?; let locality: String; let country: String }
    struct StampDTO: Decodable { let date: String; let time: String? }

    struct OpenSessionDTO: Decodable {
        let sessionKey: Int
        let meetingKey: Int?
        let sessionType: String
        let sessionName: String
        let dateStart: String
        let dateEnd: String?
        let isCancelled: Bool?
        enum CodingKeys: String, CodingKey {
            case sessionKey = "session_key", meetingKey = "meeting_key", sessionType = "session_type"
            case sessionName = "session_name", dateStart = "date_start", dateEnd = "date_end", isCancelled = "is_cancelled"
        }
    }

    struct StandingsEnvelope: Decodable { let MRData: StandingsMRData }
    struct StandingsMRData: Decodable { let StandingsTable: StandingsTable }
    struct StandingsTable: Decodable { let StandingsLists: [StandingsList] }
    struct StandingsList: Decodable { let DriverStandings: [StandingDTO]? }
    struct StandingDTO: Decodable {
        let position: String
        let points: String
        let wins: String
        let Driver: DriverDTO
        let Constructors: [ConstructorDTO]
    }
    struct DriverDTO: Decodable {
        let driverId: String
        let code: String?
        let givenName: String
        let familyName: String
    }
    struct ConstructorDTO: Decodable { let constructorId: String; let name: String }

    struct QualifyingEnvelope: Decodable { let MRData: QualifyingMRData }
    struct QualifyingMRData: Decodable { let RaceTable: QualifyingRaceTable }
    struct QualifyingRaceTable: Decodable { let Races: [QualifyingRaceDTO] }
    struct QualifyingRaceDTO: Decodable {
        let season: String
        let round: String
        let QualifyingResults: [QualifyingDTO]
    }
    struct QualifyingDTO: Decodable {
        let position: String
        let Driver: DriverDTO
        let Constructor: ConstructorDTO
        let Q1: String?
        let Q2: String?
        let Q3: String?
    }
    struct RaceResultDTO: Decodable { let laps: String }

    struct PositionDTO: Decodable {
        let driverNumber: Int
        let position: Int
        let date: String?
        enum CodingKeys: String, CodingKey { case driverNumber = "driver_number", position, date }
    }
    struct IntervalDTO: Decodable {
        let driverNumber: Int
        let interval: FlexibleValue?
        let gapToLeader: FlexibleValue?
        let date: String?
        enum CodingKeys: String, CodingKey { case driverNumber = "driver_number", interval, gapToLeader = "gap_to_leader", date }
    }
    struct LiveDriverDTO: Decodable {
        let driverNumber: Int
        let nameAcronym: String?
        let fullName: String?
        let teamName: String?
        let teamColour: String?
        enum CodingKeys: String, CodingKey {
            case driverNumber = "driver_number", nameAcronym = "name_acronym", fullName = "full_name"
            case teamName = "team_name", teamColour = "team_colour"
        }
    }
    struct PitDTO: Decodable {
        let driverNumber: Int
        let lapNumber: Int?
        let pitDuration: Double?
        enum CodingKeys: String, CodingKey { case driverNumber = "driver_number", lapNumber = "lap_number", pitDuration = "pit_duration" }
    }
    struct LapDTO: Decodable { let lapNumber: Int; enum CodingKeys: String, CodingKey { case lapNumber = "lap_number" } }
    struct ControlDTO: Decodable {
        let category: String?
        let flag: String?
        let scope: String?
        let message: String?
        let date: String?
    }

    enum FlexibleValue: Decodable {
        case string(String)
        case number(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) { self = .number(number); return }
            self = .string((try? container.decode(String.self)) ?? "")
        }

        var text: String {
            switch self {
            case .string(let value): return value
            case .number(let value): return String(value)
            }
        }
    }

    func parseRaces(_ data: Data) throws -> [Race] {
        let rows = try decoder.decode(RacesEnvelope.self, from: data).MRData.RaceTable.Races
        let specs: [(String, String, String, String, KeyPath<RaceDTO, StampDTO?>)] = [
            ("fp1", "FP1", "Practice 1", "Practice", \.FirstPractice),
            ("fp2", "FP2", "Practice 2", "Practice", \.SecondPractice),
            ("sq", "SQ", "Sprint Qualifying", "Sprint", \.SprintQualifying),
            ("sq", "SQ", "Sprint Qualifying", "Sprint", \.SprintShootout),
            ("fp3", "FP3", "Practice 3", "Practice", \.ThirdPractice),
            ("sprint", "SPR", "Sprint", "Sprint", \.Sprint),
            ("quali", "QUAL", "Qualifying", "Qualifying", \.Qualifying)
        ]
        let durations = ["fp1": 65, "fp2": 65, "fp3": 65, "sq": 50, "sprint": 65, "quali": 70, "race": 140]

        return rows.compactMap { row in
            guard let raceStamp = parseErgast(date: row.date, time: row.time) else { return nil }
            var sessions: [RaceSession] = []
            var keys = Set<String>()
            for spec in specs {
                guard !keys.contains(spec.0), let stamp = row[keyPath: spec.4], let parsed = parseErgast(date: stamp.date, time: stamp.time) else { continue }
                keys.insert(spec.0)
                sessions.append(RaceSession(
                    key: spec.0, shortName: spec.1, name: spec.2, group: spec.3,
                    startAt: parsed.date, endAt: parsed.date.addingTimeInterval(TimeInterval(durations[spec.0] ?? 60) * .minute),
                    dateOnly: parsed.dateOnly, exactEnd: false, sessionKey: nil
                ))
            }
            sessions.append(RaceSession(
                key: "race", shortName: "RACE", name: "Race", group: "Race", startAt: raceStamp.date,
                endAt: raceStamp.date.addingTimeInterval(TimeInterval(durations["race"]!) * .minute),
                dateOnly: raceStamp.dateOnly, exactEnd: false, sessionKey: nil
            ))
            sessions.sort { $0.startAt < $1.startAt }
            return Race(
                season: row.season, round: Int(row.round) ?? 0, name: row.raceName, wikiURL: row.url.flatMap(URL.init),
                circuitID: row.Circuit.circuitId, circuitName: row.Circuit.circuitName,
                circuitURL: row.Circuit.url.flatMap(URL.init), locality: row.Circuit.Location.locality,
                country: row.Circuit.Location.country, latitude: row.Circuit.Location.lat.flatMap(Double.init),
                longitude: row.Circuit.Location.long.flatMap(Double.init), sessions: sessions, meetingKey: nil
            )
        }.sorted { $0.raceStartAt < $1.raceStartAt }
    }

    func parseOpenF1Sessions(_ data: Data) throws -> [OpenF1Session] {
        try decoder.decode([OpenSessionDTO].self, from: data).compactMap { row in
            guard row.isCancelled != true, let start = parseISO(row.dateStart) else { return nil }
            return OpenF1Session(sessionKey: row.sessionKey, meetingKey: row.meetingKey, type: row.sessionType, name: row.sessionName, startAt: start, endAt: row.dateEnd.flatMap(parseISO))
        }.sorted { $0.startAt < $1.startAt }
    }

    func parseStandings(_ data: Data) throws -> [DriverStanding] {
        let rows = try decoder.decode(StandingsEnvelope.self, from: data).MRData.StandingsTable.StandingsLists.first?.DriverStandings ?? []
        return rows.enumerated().map { index, row in
            let team = row.Constructors.last
            return DriverStanding(
                position: Int(row.position) ?? index + 1, points: Double(row.points) ?? 0, wins: Int(row.wins) ?? 0,
                driverID: row.Driver.driverId, code: row.Driver.code ?? String(row.Driver.familyName.prefix(3)).uppercased(),
                givenName: row.Driver.givenName, familyName: row.Driver.familyName,
                constructorID: team?.constructorId ?? "", constructorName: team?.name ?? ""
            )
        }.sorted { $0.position < $1.position }
    }

    func parseQualifying(_ data: Data) throws -> QualifyingResult? {
        guard let race = try decoder.decode(QualifyingEnvelope.self, from: data).MRData.RaceTable.Races.first else { return nil }
        let rows = race.QualifyingResults.enumerated().map { index, row in
            QualifyingPosition(
                position: Int(row.position) ?? index + 1, driverID: row.Driver.driverId,
                code: row.Driver.code ?? String(row.Driver.familyName.prefix(3)).uppercased(),
                fullName: "\(row.Driver.givenName) \(row.Driver.familyName)", familyName: row.Driver.familyName,
                constructorID: row.Constructor.constructorId, constructorName: row.Constructor.name,
                bestTime: row.Q3 ?? row.Q2 ?? row.Q1 ?? "—"
            )
        }.sorted { $0.position < $1.position }
        return QualifyingResult(season: race.season, round: Int(race.round) ?? 0, positions: rows)
    }

    func parseRaceDistance(_ data: Data) throws -> Int? {
        let rows = try decoder.decode(RacesEnvelope.self, from: data).MRData.RaceTable.Races
        return rows.last?.Results?.first.flatMap { Int($0.laps) }
    }

    func parsePositions(_ data: Data) throws -> [TimedPosition] {
        try decoder.decode([PositionDTO].self, from: data).map { TimedPosition(driverNumber: $0.driverNumber, position: $0.position, at: $0.date.flatMap(parseISO)) }
    }

    func parseIntervals(_ data: Data) throws -> [TimedInterval] {
        try decoder.decode([IntervalDTO].self, from: data).map {
            TimedInterval(driverNumber: $0.driverNumber, interval: $0.interval?.text, gapToLeader: $0.gapToLeader?.text, at: $0.date.flatMap(parseISO))
        }
    }

    func parseDrivers(_ data: Data) throws -> [Int: LiveDriver] {
        var result: [Int: LiveDriver] = [:]
        for row in try decoder.decode([LiveDriverDTO].self, from: data) {
            result[row.driverNumber] = LiveDriver(
                number: row.driverNumber, acronym: row.nameAcronym ?? "", fullName: row.fullName ?? "",
                teamName: row.teamName ?? "", teamColour: row.teamColour ?? ""
            )
        }
        return result
    }

    func parsePits(_ data: Data) throws -> [Int: PitSummary] {
        var result: [Int: PitSummary] = [:]
        for row in try decoder.decode([PitDTO].self, from: data) {
            var item = result[row.driverNumber] ?? PitSummary()
            item.count += 1
            if let lap = row.lapNumber, lap >= (item.lastLap ?? 0) { item.lastLap = lap; item.lastDuration = row.pitDuration }
            result[row.driverNumber] = item
        }
        return result
    }

    func parseCurrentLap(_ data: Data) throws -> Int? {
        try decoder.decode([LapDTO].self, from: data).map(\.lapNumber).max()
    }

    func parseRaceControl(_ data: Data) throws -> RaceControlStatus? {
        let rows = try decoder.decode([ControlDTO].self, from: data)
        for row in rows.reversed() {
            let category = row.category?.uppercased() ?? ""
            let flag = row.flag?.uppercased() ?? ""
            let scope = row.scope?.uppercased() ?? ""
            let message = row.message?.uppercased() ?? ""
            let at = row.date.flatMap(parseISO)
            if category == "SAFETYCAR" || message.contains("SAFETY CAR") {
                if message.contains("VIRTUAL") { return RaceControlStatus(label: message.contains("ENDING") ? "VSC ENDING" : "VIRTUAL SAFETY CAR", kind: "caution", at: at) }
                return RaceControlStatus(label: "SAFETY CAR", kind: "caution", at: at)
            }
            if category == "FLAG", scope == "TRACK" {
                if flag == "RED" { return RaceControlStatus(label: "RED FLAG", kind: "stopped", at: at) }
                if flag == "CHEQUERED" { return RaceControlStatus(label: "CHEQUERED FLAG", kind: "finished", at: at) }
                if flag.contains("YELLOW") { return RaceControlStatus(label: "YELLOW FLAG", kind: "caution", at: at) }
                if flag == "GREEN" || flag == "CLEAR" { return .running }
            }
        }
        return rows.isEmpty ? nil : .running
    }

    func parseErgast(date: String, time: String?) -> (date: Date, dateOnly: Bool)? {
        if let time, let parsed = parseISO("\(date)T\(time)") { return (parsed, false) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date).map { ($0, true) }
    }

    func parseISO(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: value) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
