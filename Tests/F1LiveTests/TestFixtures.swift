import Foundation
@testable import F1Live

func fixtureDate(_ epoch: TimeInterval) -> Date {
    Date(timeIntervalSince1970: epoch)
}

func makeRace(start: Date) -> Race {
    Race(
        season: "2026", round: 13, name: "Italian Grand Prix", wikiURL: nil,
        circuitID: "monza", circuitName: "Autodromo Nazionale di Monza", circuitURL: nil,
        locality: "Monza", country: "Italy", latitude: nil, longitude: nil,
        sessions: [RaceSession(key: "race", shortName: "RACE", name: "Race", group: "Race", startAt: start, endAt: start.addingTimeInterval(7_200), dateOnly: false, exactEnd: false, sessionKey: nil)],
        meetingKey: nil
    )
}
