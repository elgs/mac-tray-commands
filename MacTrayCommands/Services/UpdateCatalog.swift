import Foundation

/// A newer release advertised by the Homebrew cask: the version plus
/// everything needed to fetch and verify its DMG.
struct AvailableUpdate: Equatable {
    let version: String
    let dmgURL: URL
    /// Lowercased hex SHA-256 of the DMG, as published in the cask.
    let sha256: String
    /// Oldest macOS the cask says the release runs on, as a major version
    /// ("13"), from its `depends_on macos:` line. Nil when the cask states no
    /// minimum, or names a release this build has no number for.
    let minimumMacOS: String?
}

/// Reading the published cask and deciding what it means for this install.
///
/// The cask in `elgs/homebrew-taps` is the release feed: `release.sh` writes
/// the version and the DMG's hash into it as the last step of every release,
/// so whatever is there is exactly what shipped. Nothing else has to be
/// published or kept in sync — no appcast, no separate JSON.
///
/// Pure on purpose: no network, no bundle, no clock. The two ways this can go
/// wrong quietly — a half-parsed cask driving an install, and a version
/// comparison that says yes to a build it should not — are both decided here.
enum UpdateCatalog {
    /// Where the feed lives. raw.githubusercontent.com rather than the API:
    /// no token, no rate limit worth worrying about, and the tap is public.
    static let caskURL = URL(string:
        "https://raw.githubusercontent.com/elgs/homebrew-taps/main/Casks/mac-tray-commands.rb")!

    /// The Homebrew fallback named wherever an update can fail.
    static let brewUpgradeCommand = "brew upgrade --cask mac-tray-commands"

    /// Parse the cask source for everything the updater needs. Returns nil
    /// unless all three fields are present and well-formed: a partially
    /// parsed cask must never drive an install, because the fields verify
    /// each other — the hash is what makes the download trustworthy.
    static func parseCask(_ source: String) -> AvailableUpdate? {
        let code = stripComments(source)
        guard let version = firstCapture(#"^\s*version\s+"([^"]+)""#, in: code),
              let sha = firstCapture(#"^\s*sha256\s+"([0-9a-fA-F]{64})""#, in: code),
              let template = firstCapture(#"^\s*url\s+"([^"]+)""#, in: code)
        else { return nil }
        // The cask writes its url once and interpolates the version, so the
        // tag always matches the version stanza. Resolve it the way Ruby would.
        let resolved = template.replacingOccurrences(of: "#{version}", with: version)
        guard let url = URL(string: resolved), url.scheme == "https" else { return nil }
        return AvailableUpdate(version: version, dmgURL: url, sha256: sha.lowercased(),
                               minimumMacOS: minimumMacOS(inCask: code))
    }

    /// Ruby comments, dropped line by line so prose about the stanzas is not
    /// mistaken for them. A `#` after a quote on the same line is left alone:
    /// inside a string it is the interpolation in `.../v#{version}/...`.
    private static func stripComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let hash = line.firstIndex(of: "#") else { return line }
                return line[line.startIndex..<hash].contains("\"") ? line : line[line.startIndex..<hash]
            }
            .joined(separator: "\n")
    }

    /// Homebrew's names for macOS releases, with their major versions. A cask
    /// can only name a release, never a number.
    private static let homebrewMacOSReleases = [
        "big_sur": "11", "monterey": "12", "ventura": "13", "sonoma": "14",
        "sequoia": "15", "tahoe": "26", "golden_gate": "27",
    ]

    /// The minimum macOS a cask's `depends_on macos:` line asks for, as a
    /// major version. Homebrew reads a bare release name as "this or later",
    /// so `:ventura` and the older spelling `">= :ventura"` both give "13".
    /// Nil for no such line, for a line that is not a minimum (a list of
    /// releases, `"<= :…"`), and for a release name this build has no number
    /// for. The last case is deliberately not treated as a refusal: a name
    /// this build has never heard of may well be the macOS it is running on,
    /// and refusing would leave that Mac with no way to update. The
    /// downloaded bundle's own minimum still decides before anything is
    /// installed (see `launchBlocker`).
    static func minimumMacOS(inCask content: String) -> String? {
        // A trailing comment is tolerated here: the comment stripper keeps
        // any line with a quote in it (see `stripComments`), and this line
        // quotes its old spelling.
        guard let name = firstCapture(#"^\s*depends_on\s+macos:\s*(?:">=\s*)?:([a-z_]+)"?\s*(?:#.*)?$"#,
                                      in: stripComments(content))
        else { return nil }
        return homebrewMacOSReleases[name]
    }

    /// What a fetched cask means for this install.
    enum Offer: Equatable {
        case upToDate
        case available
        /// A newer release exists, but it needs this macOS major version or
        /// later and the Mac runs something older.
        case needsNewerMacOS(String)
    }

    /// A release that is not newer is never a macOS question, and a newer one
    /// is offered only to a Mac that can run it.
    static func offer(_ update: AvailableUpdate, installed: String, running: String) -> Offer {
        guard isNewerVersion(update.version, than: installed) else { return .upToDate }
        if let macOS = macOSNeeded(for: update, running: running) { return .needsNewerMacOS(macOS) }
        return .available
    }

    /// The macOS an update needs when this Mac runs something older, nil when
    /// the update can be offered. `running` is a dotted version ("13.6.1").
    static func macOSNeeded(for update: AvailableUpdate, running: String) -> String? {
        guard let minimum = update.minimumMacOS, isNewerVersion(minimum, than: running) else { return nil }
        return minimum
    }

    /// Why a bundle whose Info.plist declares `minimumSystemVersion`
    /// (LSMinimumSystemVersion) must not replace the running app on a Mac
    /// running `running`, or nil when it can launch there. An absent key
    /// declares no minimum. A value that does not parse blocks the install:
    /// swapping in an app that macOS then refuses to open would leave the Mac
    /// without the app, so an unreadable answer counts as "no".
    static func launchBlocker(minimumSystemVersion: String?, running: String) -> String? {
        guard let minimum = minimumSystemVersion else { return nil }
        guard parseDottedVersion(minimum) != nil else {
            return "Couldn't read which macOS the new version needs (\(minimum))."
        }
        guard isNewerVersion(minimum, than: running) else { return nil }
        return "The new version needs macOS \(minimum) or later, and this Mac runs macOS \(running)."
    }

    /// Compare two dotted version strings ("1.2.0" > "1.1.0"). False unless
    /// BOTH parse fully as dotted integers: a version this cannot read is one
    /// it cannot compare, and answering "newer" on a guess would offer an
    /// update to a build that may already be ahead of it.
    static func isNewerVersion(_ remote: String, than current: String) -> Bool {
        guard let r = parseDottedVersion(remote), let c = parseDottedVersion(current) else { return false }
        for i in 0 ..< max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    /// "1.2.3" → [1, 2, 3]; nil if the string is empty or any component is
    /// not plain digits — "1.0.0-beta", "v1.0.0" and "1..0" are rejected
    /// whole rather than read as something they don't mean.
    static func parseDottedVersion(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let nums = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        return nums.count == parts.count ? nums : nil
    }

    /// The first capture group of `pattern`'s first match, with `^`/`$`
    /// matching at line boundaries.
    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

/// What this build calls itself: the left-hand side of every comparison.
/// A bundle with no version string reports "" and `isNewerVersion` refuses
/// to compare it, so an unversioned build is never offered anything rather
/// than being offered everything.
enum AppVersion {
    static let current: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
}

enum SystemVersion {
    /// The macOS version this Mac runs, written the way `sw_vers
    /// -productVersion` prints it.
    static let current = string(ProcessInfo.processInfo.operatingSystemVersion)

    /// "27.0" or "26.7.1": major and minor always, the patch only when it is
    /// not zero.
    static func string(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }
}
