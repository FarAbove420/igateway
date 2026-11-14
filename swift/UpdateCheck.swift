//
//  UpdateCheck.swift
//
//  Tells you when a newer iGateway.exe is out. Once a day the main app asks
//  GitHub's API for the latest release of this repository: one HTTPS request,
//  no cookies, nothing about you or your servers. A newer version shows as a
//  button in the host list's title bar that opens its release page. The app
//  never downloads or installs anything itself.
//

import Foundation

enum UpdateCheck {
    static let repository = "FarAbove420/igateway"
    static let interval: TimeInterval = 24 * 60 * 60

    static var installed: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "v0.7.2" or "0.7.2" gives "0.7.2". Anything but up to four dotted
    /// numbers gives nil, so nothing odd from the answer reaches a URL or the UI.
    static func version(fromTag tag: String) -> String? {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count),
              parts.allSatisfy({ (1...6).contains($0.count) && $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return nil }
        return version
    }

    /// Numerically, part by part: 0.7.10 is newer than 0.7.9.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func numbers(_ version: String) -> [Int] { version.split(separator: ".").map { Int($0) ?? 0 } }
        let a = numbers(candidate), b = numbers(installed)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The version in GitHub's "latest release" answer. That answer leaves
    /// out drafts and pre-releases.
    static func latestVersion(from data: Data) -> String? {
        struct Release: Decodable { let tag_name: String }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        return version(fromTag: release.tag_name)
    }

    /// Built here from the version, never taken from the answer.
    static func releasePage(_ version: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
    }

    /// Once a day. A last check in the future means the clock went back.
    static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }

    enum Result: Equatable {
        case latest(String)
        case failed(String)
    }

    /// Asks GitHub for the latest release. Calls back on the main queue.
    static func fetch(_ done: @escaping (Result) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iGateway.exe/\(installed)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, error in
            let result: Result
            if let error {
                result = .failed(error.localizedDescription)
            } else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                result = .failed("GitHub answered with status \(status).")
            } else if let data, let version = latestVersion(from: data) {
                result = .latest(version)
            } else {
                result = .failed("GitHub's answer had no version in it.")
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
        session.finishTasksAndInvalidate()
    }
}
