import Foundation

enum SupportLinks {
    static var bugReport: URL {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return bugReportURL(version: "\(version) (\(build))", macOS: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    static func bugReportURL(version: String, macOS: String) -> URL {
        var components = URLComponents(string: "https://github.com/johndavidwright/f1-live-macos/issues/new")!
        components.queryItems = [URLQueryItem(name: "body", value: """
        ## What happened?

        Describe the problem and what you expected instead.

        ## Steps to reproduce

        1.
        2.
        3.

        ## App and system

        - F1 Live: \(version)
        - macOS: \(macOS)
        - Mac: Apple silicon / Intel (choose one)
        - Session, if relevant:

        ## Screenshots or extra context

        Please remove any personal information before submitting. No logs are attached automatically.
        """)]
        return components.url!
    }
}
