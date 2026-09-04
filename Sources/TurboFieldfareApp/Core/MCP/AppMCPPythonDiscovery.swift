#if os(macOS)
import Foundation
import Observation

public struct AppMCPPythonInstallation: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let source: String
    public var info: AppMCPPythonInfo?
    public var issue: String?
    public var isCompatible: Bool { info != nil && issue == nil }
    public var title: String { info.map { "Python \($0.version) · \(source)" } ?? "\(URL(fileURLWithPath: path).lastPathComponent) · \(source)" }
}

struct AppMCPPythonSearchLocation: Sendable {
    enum Layout: Sendable { case binaries, versions, homebrew }
    var directory: URL
    var source: String
    var layout: Layout = .binaries
}

/// Searches bounded, known installation locations. Never invokes a shell or package manager.
@MainActor @Observable
public final class AppMCPPythonDiscovery {
    public private(set) var installations: [AppMCPPythonInstallation] = []
    public private(set) var isSearching = false
    public private(set) var hasSearched = false
    public private(set) var progress = ""
    public private(set) var notice: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let locations: [AppMCPPythonSearchLocation]
    private let inspect: @MainActor (String) async throws -> AppMCPPythonInfo

    public convenience init() {
        self.init(locations: Self.defaultLocations())
    }
    init(locations: [AppMCPPythonSearchLocation],
         inspect: @escaping @MainActor (String) async throws -> AppMCPPythonInfo = { path in
             try await AppMCPExchangeInstaller().inspectPython(path, timeout: .seconds(3))
         }) {
        self.locations = locations; self.inspect = inspect
    }

    public func search() {
        guard !isSearching else { return }
        let launch = UUID(); generation = launch
        installations = []; notice = nil; isSearching = true; hasSearched = true
        progress = "Looking for installed Python…"
        operation = Task { [weak self, locations] in
            let candidates = await Task.detached(priority: .utility) { Self.candidates(in: locations) }.value
            guard let self, self.generation == launch, !Task.isCancelled else { return }
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            for (index, candidate) in candidates.prefix(32).enumerated() {
                if ContinuousClock.now >= deadline {
                    self.notice = "Search time limit reached. Some installations were not checked; use Find Python to retry or choose a file."
                    break
                }
                self.progress = "Checking Python \(index + 1) of \(min(candidates.count, 32))…"
                var result = candidate
                do {
                    let info = try await self.inspect(candidate.path)
                    result.info = info; result.issue = info.compatibilityIssue
                } catch is CancellationError { break }
                catch { result.issue = AppMCPDiagnosticText.clean(error.localizedDescription) }
                guard self.generation == launch, !Task.isCancelled else { return }
                self.installations.append(result)
            }
            guard self.generation == launch, !Task.isCancelled else { return }
            self.installations.sort {
                if $0.isCompatible != $1.isCompatible { return $0.isCompatible }
                // The bundled connector has been verified with Python 3.13.
                let leftPreferred = $0.info?.minor == 13, rightPreferred = $1.info?.minor == 13
                if leftPreferred != rightPreferred { return leftPreferred }
                let order = ($0.info?.version ?? "").compare($1.info?.version ?? "", options: .numeric)
                return order == .orderedSame ? $0.path < $1.path : order == .orderedDescending
            }
            if candidates.count > 32, self.notice == nil {
                self.notice = "Checked the first 32 installations. Choose a file to use another Python."
            }
            self.progress = "Found \(self.installations.filter(\.isCompatible).count) compatible Python installations."
            self.isSearching = false; self.operation = nil
        }
    }
    public func cancel() {
        guard isSearching else { return }
        generation = UUID(); operation?.cancel(); operation = nil; isSearching = false
        notice = "Search cancelled. Completed checks remain available."
    }

    nonisolated static func defaultLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                            environment: [String: String] = ProcessInfo.processInfo.environment) -> [AppMCPPythonSearchLocation] {
        var locations: [AppMCPPythonSearchLocation] = []
        func add(_ path: String, _ source: String, _ layout: AppMCPPythonSearchLocation.Layout = .binaries) {
            guard path.hasPrefix("/"), !locations.contains(where: { $0.directory.path == path }) else { return }
            locations.append(.init(directory: URL(fileURLWithPath: path), source: source, layout: layout))
        }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            add(prefix + "/bin", "Homebrew / local")
            add(prefix + "/opt", "Homebrew", .homebrew)
        }
        for path in ["/Library/Frameworks/Python.framework/Versions", home.appendingPathComponent("Library/Frameworks/Python.framework/Versions").path] {
            add(path, "Python.org", .versions)
        }
        add((environment["PYENV_ROOT"] ?? home.appendingPathComponent(".pyenv").path) + "/versions", "pyenv", .versions)
        add(home.appendingPathComponent(".asdf/installs/python").path, "asdf", .versions)
        add(home.appendingPathComponent(".local/share/uv/python").path, "uv", .versions)
        for root in ["/opt/anaconda3", "/opt/miniconda3"] + ["anaconda3", "miniconda3", "miniforge3", "mambaforge"].map({ home.appendingPathComponent($0).path }) {
            add(root + "/bin", "Conda")
            add(root + "/envs", "Conda environment", .versions)
        }
        if let prefix = environment["CONDA_PREFIX"] { add(prefix + "/bin", "Conda") }
        add("/usr/bin", "macOS")
        for path in (environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            // Do not execute version-manager shims or project-relative commands.
            guard URL(fileURLWithPath: path).lastPathComponent != "shims" else { continue }
            add(path, "PATH")
        }
        return locations
    }

    nonisolated static func candidates(in locations: [AppMCPPythonSearchLocation]) -> [AppMCPPythonInstallation] {
        let fm = FileManager.default
        var seen = Set<String>(), results: [AppMCPPythonInstallation] = []
        func scan(_ directory: URL, source: String) {
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
            for entry in files.sorted(by: { $0.path < $1.path }) {
                // FileManager may resolve a symlink in the parent directory.
                // Keep the original installation alias, including opt/python@…/bin.
                let file = directory.appendingPathComponent(entry.lastPathComponent)
                guard file.lastPathComponent.range(of: #"^python(?:3(?:\.\d+)?t?)?$"#, options: .regularExpression) != nil else { continue }
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      fm.isExecutableFile(atPath: file.path) else { continue }
                let canonical = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                // Resolve only for deduplication; retain stable installation aliases for selection.
                results.append(.init(path: file.path, source: source))
            }
        }
        for location in locations {
            if results.count >= 128 { break }
            switch location.layout {
            case .binaries: scan(location.directory, source: location.source)
            case .versions, .homebrew:
                guard let versions = try? fm.contentsOfDirectory(at: location.directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for entry in versions.sorted(by: { $0.path > $1.path }).prefix(128) {
                    let version = location.directory.appendingPathComponent(entry.lastPathComponent)
                    if version.lastPathComponent == "Current" { continue }
                    if location.layout == .homebrew, !version.lastPathComponent.hasPrefix("python") { continue }
                    scan(version.appendingPathComponent("bin"), source: location.source)
                }
            }
        }
        return results
    }
}
#endif
