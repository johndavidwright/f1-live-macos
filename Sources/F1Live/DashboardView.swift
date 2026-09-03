import AppKit
import SwiftUI

struct DashboardView: View {
    static let windowWidth: CGFloat = 540
    static let windowHeight: CGFloat = 860

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let data = store.data {
                    ScrollView {
                        if store.liveMode {
                            LiveTimingView(data: data)
                        } else if let race = data.race {
                            RaceOverviewView(data: data, race: race)
                        } else {
                            ContentUnavailableView("Off season", systemImage: "calendar.badge.clock", description: Text("Waiting for the next Formula 1 calendar."))
                                .frame(height: 520)
                        }
                    }
                    .scrollIndicators(.visible)
                } else if store.isLoading {
                    ProgressView("Loading the season calendar…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Couldn’t load F1 data", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(store.errorMessage ?? "Check your connection and try again.")
                    } actions: {
                        Button("Try Again") { Task { await store.refresh() } }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: Self.windowWidth, height: Self.windowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            if store.isLoading, store.data != nil {
                ProgressView().controlSize(.small).padding(.top, 17).padding(.trailing, 154)
            }
        }
        .background {
            Button("") { store.toggleLive() }
                .keyboardShortcut(.return, modifiers: [])
                .frame(width: 0, height: 0).opacity(0)
            Button("") { Task { await store.refresh() } }
                .keyboardShortcut("r", modifiers: [])
                .frame(width: 0, height: 0).opacity(0)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusChip(text: store.liveMode ? "LIVE TIMING" : store.weekend.label, kind: store.liveMode ? .live : store.weekend.kind)
            if let race = store.race, !store.liveMode {
                Text("ROUND \(race.round)  ·  \(race.season)")
                    .font(.caption2.monospaced()).tracking(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.toggleLive()
            } label: {
                Label(store.liveMode ? "LIVE RACE · ON" : "LIVE RACE · OFF", systemImage: store.liveMode ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.caption.monospaced().weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(store.liveMode ? .red : .secondary)
            .help("Toggle the OpenF1 live timing tower (Return)")
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("All times in \(TimeZone.autoupdatingCurrent.identifier)")
                if let data = store.data {
                    Text(data.stale ? "Offline · cached \(F1Formatting.ago(data.lastUpdatedAt, now: store.now))" : "Updated \(F1Formatting.ago(data.lastUpdatedAt, now: store.now))")
                        .foregroundStyle(data.stale ? Color.orange : Color.secondary)
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh (R)")
            Button {
                updates.checkForUpdates()
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .disabled(!updates.canCheckForUpdates)
            .help("Check for Updates…")
            Button {
                SettingsWindowController.shared.show(store: store, settings: settings, updates: updates)
            } label: {
                Image(systemName: "gearshape")
            }
                .buttonStyle(.plain)
                .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit F1 Live")
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }
}

private struct RaceOverviewView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: SettingsStore
    let data: DashboardData
    let race: Race

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            hero
            DashboardSection("WEEKEND · \(F1Formatting.dateRange(race.weekendStartAt, race.weekendEndAt))") {
                VStack(spacing: 0) {
                    ForEach(race.sessions) { SessionRowView(session: $0) }
                }
            }
            if let qualifying = data.qualifying, qualifying.round == race.round, !qualifying.positions.isEmpty {
                DashboardSection("STARTING GRID · QUALIFYING RESULT") {
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 2) {
                        ForEach(qualifying.positions.prefix(10)) { QualifyingRowView(position: $0) }
                    }
                }
            }
            if !data.upcoming.isEmpty {
                DashboardSection("UPCOMING RACES") {
                    VStack(spacing: 5) {
                        ForEach(data.upcoming) { UpcomingRaceView(race: $0) }
                    }
                }
            }
            if !data.standings.isEmpty {
                DashboardSection("DRIVER STANDINGS") {
                    VStack(spacing: 2) {
                        let view = store.standingsView()
                        let leaderPoints = data.standings.first?.points ?? 0
                        ForEach(view.top) { driver in
                            let favorite = settings.isFavorite(driver.id)
                            StandingRowView(
                                driver: driver,
                                gap: favorite ? max(0, leaderPoints - driver.points) : nil,
                                favorite: favorite
                            )
                        }
                        ForEach(view.favorites) { favorite in
                            StandingRowView(
                                driver: favorite.driver,
                                gap: favorite.gapToLeader,
                                favorite: true
                            )
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(race.name)
                        .font(.title2.monospaced().weight(.bold))
                    if race.isSprintWeekend {
                        Text("SPRINT")
                            .font(.caption2.monospaced().weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(race.circuitName).font(.callout.monospaced()).foregroundStyle(.secondary)
                Text("\(race.locality) · \(race.country)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                Spacer().frame(height: 7)
                Text("LIGHTS OUT").font(.caption2.monospaced()).tracking(1.2).foregroundStyle(.tertiary)
                Text(F1Formatting.longDate(race.raceStartAt)).font(.callout.monospaced())
                Text("\(F1Formatting.time(race.raceStartAt, twelveHour: settings.useTwelveHourTime)) your time · in \(F1Formatting.countdown(to: race.raceStartAt, from: store.now))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            CircuitImage(race: race)
                .frame(width: 124, height: 124)
        }
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
    }
}

private struct LiveTimingView: View {
    @EnvironmentObject private var store: AppStore
    let data: DashboardData

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if let session = store.activeFeedSession {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name.uppercased()).font(.title2.monospaced().weight(.bold))
                        Text(data.race?.name ?? "Formula 1").font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(store.live.status.label)
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(statusColour)
                        if store.live.currentLap > 0 {
                            Text(data.raceDistance.map { "LAP \(store.live.currentLap) / \($0)" } ?? "LAP \(store.live.currentLap)")
                                .font(.headline.monospaced())
                        }
                    }
                }

                if !store.live.rows.isEmpty, let warning = store.liveWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }

                if store.live.rows.isEmpty {
                    VStack(spacing: 12) {
                        if store.isPollingLive { ProgressView() }
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 30)).foregroundStyle(.red)
                        Text("Waiting for live timing data…").font(.headline.monospaced())
                        Text("OpenF1 begins publishing shortly before the session starts.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let warning = store.liveWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 430)
                } else {
                    VStack(spacing: 2) {
                        HStack {
                            Text("POS  DRIVER").frame(maxWidth: .infinity, alignment: .leading)
                            Text("INTERVAL").frame(width: 105, alignment: .trailing)
                            Text("LEADER").frame(width: 105, alignment: .trailing)
                            Text("PIT").frame(width: 38, alignment: .trailing)
                        }
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary).padding(.horizontal, 10)
                        ForEach(store.live.rows) { LiveTimingRowView(row: $0) }
                    }
                    HStack {
                        Circle().fill(store.liveWarning == nil ? .red : .orange).frame(width: 7, height: 7)
                        Text(store.liveWarning ?? "Live · updated \(F1Formatting.ago(store.live.lastUpdateAt, now: store.now))")
                        Spacer()
                        if store.isPollingLive { ProgressView().controlSize(.mini) }
                    }
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView {
                    Label("No session is live", systemImage: "flag.checkered")
                } description: {
                    if let next = data.race?.nextSession(at: store.now) {
                        Text("\(next.name) starts in \(F1Formatting.countdown(to: next.startAt, from: store.now)).")
                    } else {
                        Text("Live timing activates during a Formula 1 session.")
                    }
                } actions: {
                    Button("Back to Race Overview") { store.setLiveMode(false) }
                }
                .frame(maxWidth: .infinity, minHeight: 560)
            }
        }
        .padding(18)
    }

    private var statusColour: Color {
        switch store.live.status.kind {
        case "caution": return .yellow
        case "stopped", "finished": return .red
        default: return .green
        }
    }
}

private struct StatusChip: View {
    let text: String
    let kind: WeekendKind

    var colour: Color {
        switch kind {
        case .live: return .red
        case .soon: return .orange
        case .finished: return .secondary
        default: return .accentColor
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2.monospaced().weight(.bold)).tracking(1)
            .foregroundStyle(colour)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(colour.opacity(0.45)))
    }
}

struct DashboardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(title).font(.caption2.monospaced().weight(.bold)).foregroundStyle(.secondary)
            content
        }
    }
}

private struct SessionRowView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: SettingsStore
    let session: RaceSession

    var state: SessionState { session.state(at: store.now) }

    var body: some View {
        HStack(spacing: 10) {
            Text(session.shortName).fontWeight(.semibold).frame(width: 52, alignment: .leading)
            Text(session.name).foregroundStyle(state == .done ? .tertiary : .secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text(F1Formatting.shortDay(session.startAt)).foregroundStyle(.tertiary).frame(width: 34)
            Text(session.dateOnly ? "—" : F1Formatting.time(session.startAt, twelveHour: settings.useTwelveHourTime)).frame(width: 64, alignment: .leading)
            Text(stateText)
                .font(.caption2.monospaced().weight(.medium))
                .foregroundStyle(stateColour)
                .frame(width: 72, alignment: .trailing)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(state == .live ? Color.red.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.name), \(stateText), \(F1Formatting.longDate(session.startAt)) at \(F1Formatting.time(session.startAt, twelveHour: settings.useTwelveHourTime))")
    }

    private var stateText: String {
        switch state {
        case .done: return "DONE"
        case .live: return "LIVE"
        case .soon: return "SOON"
        case .upcoming: return F1Formatting.countdown(to: session.startAt, from: store.now, compact: true)
        }
    }

    private var stateColour: Color {
        switch state { case .live: return .red; case .soon: return .orange; case .done: return .secondary; case .upcoming: return .secondary }
    }
}

private struct UpcomingRaceView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: SettingsStore
    let race: Race

    var body: some View {
        HStack(spacing: 10) {
            Text("R\(race.round)").foregroundStyle(.tertiary).frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(race.name).fontWeight(.semibold)
                    if race.isSprintWeekend { Text("SPRINT").font(.system(size: 8).monospaced().weight(.bold)).foregroundStyle(.orange) }
                }
                Text("\(race.locality) · \(race.country)").foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(F1Formatting.date(race.raceStartAt)) · \(F1Formatting.time(race.raceStartAt, twelveHour: settings.useTwelveHourTime))")
                Text("in \(F1Formatting.countdown(to: race.raceStartAt, from: store.now, compact: true))").foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

private struct StandingRowView: View {
    let driver: DriverStanding
    var gap: Double? = nil
    var favorite = false

    var body: some View {
        HStack(spacing: 10) {
            Text("P\(driver.position)").foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: TeamColours.hex(constructorID: driver.constructorID, name: driver.constructorName))).frame(width: 4, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(driver.fullName) + Text("  \(driver.code)").foregroundColor(.secondary)
                }
                Text(driver.constructorName).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(pointsText).fontWeight(.semibold)
                if let gap { Text("\(formatPoints(gap)) pts behind leader").font(.caption2).foregroundStyle(.blue) }
                else if driver.wins > 0 { Text("\(driver.wins) \(driver.wins == 1 ? "win" : "wins")").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(favorite ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay { if favorite { RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(0.42)) } }
        .accessibilityElement(children: .combine)
    }

    private var pointsText: String { "\(formatPoints(driver.points)) pts" }
    private func formatPoints(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
}

private struct QualifyingRowView: View {
    let position: QualifyingPosition

    var body: some View {
        HStack(spacing: 8) {
            Text("P\(position.position)").foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: TeamColours.hex(constructorID: position.constructorID, name: position.constructorName))).frame(width: 3, height: 20)
            Text(position.familyName).lineLimit(1)
            Spacer()
            Text(position.bestTime).foregroundStyle(.secondary)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
    }
}

private struct LiveTimingRowView: View {
    let row: LiveRow

    var body: some View {
        HStack(spacing: 9) {
            Text("P\(row.position)").foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: TeamColours.hex(constructorID: "", name: row.teamName, live: row.teamColour))).frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.acronym).fontWeight(.bold)
                Text(row.teamName).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.interval).frame(width: 105, alignment: .trailing)
            Text(row.gapToLeader).frame(width: 105, alignment: .trailing).foregroundStyle(.secondary)
            Text(row.pitStops == 0 ? "—" : "\(row.pitStops)").frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(row.position == 1 ? Color.green.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Position \(row.position), \(row.fullName.isEmpty ? row.acronym : row.fullName), \(row.teamName), gap \(row.gapToLeader), \(row.pitStops) pit stops")
    }
}

private struct CircuitImage: View {
    let race: Race

    var body: some View {
        if let filename = CircuitMaps.filename(for: race), let image = ResourceLocator.circuitImage(named: filename) {
            Image(nsImage: image)
                .resizable().scaledToFit()
                .colorMultiply(.primary)
                .accessibilityLabel("Circuit map of \(race.circuitName)")
        }
    }
}

enum ResourceLocator {
    static func circuitImage(named filename: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: filename, withExtension: nil, subdirectory: "Circuits"), let image = NSImage(contentsOf: url) { return image }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/F1Live/Resources/Circuits").appendingPathComponent(filename)
        return NSImage(contentsOf: development)
    }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let number = UInt64(value, radix: 16) ?? 0x8a8f98
        self.init(
            red: Double((number >> 16) & 0xff) / 255,
            green: Double((number >> 8) & 0xff) / 255,
            blue: Double(number & 0xff) / 255
        )
    }
}
