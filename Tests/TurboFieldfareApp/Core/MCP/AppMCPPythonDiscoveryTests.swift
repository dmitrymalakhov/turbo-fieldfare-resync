#if os(macOS)
import Foundation
import Testing
@testable import TurboFieldfareAppCore

@Suite(.serialized) @MainActor
struct AppMCPPythonDiscoveryTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("python-discovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func executable(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }
    private func info(_ version: String, path: String, venv: Bool = true) -> AppMCPPythonInfo {
        AppMCPPythonInfo(executable: path, version: version, major: 3,
                         minor: Int(version.split(separator: ".")[1])!, hasVenv: venv, hasEnsurepip: true)
    }
    private func settle(_ discovery: AppMCPPythonDiscovery) async throws {
        for _ in 0..<700 where discovery.isSearching { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!discovery.isSearching)
    }

    @Test func scansInstallLayoutsAndDeduplicatesAliasesWithoutRecursingIntoProjects() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin"), brew = root.appendingPathComponent("opt")
        let versions = root.appendingPathComponent("versions")
        let base = brew.appendingPathComponent("python@3.13/bin/python3.13")
        try executable(base)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("python3"), withDestinationURL: base)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("python3.13"), withDestinationURL: base)
        try executable(versions.appendingPathComponent("3.12.9/bin/python3.12"))
        try executable(bin.appendingPathComponent("project/.venv/bin/python3"))
        try executable(bin.appendingPathComponent("python3-config"))
        try executable(brew.appendingPathComponent("other-package/bin/python3.11"))
        try FileManager.default.createDirectory(at: bin.appendingPathComponent("python3.99"), withIntermediateDirectories: true)
        let candidates = AppMCPPythonDiscovery.candidates(in: [
            .init(directory: bin, source: "PATH"), .init(directory: brew, source: "Homebrew", layout: .homebrew),
            .init(directory: versions, source: "pyenv", layout: .versions)
        ])
        #expect(candidates.count == 2)
        #expect(candidates[0].path == bin.appendingPathComponent("python3").path,
                "The stable alias should be kept, while symlinks are deduplicated")
        #expect(candidates[1].source == "pyenv")
    }

    @Test func searchFindsUsableVersionsAndExplainsRejectedCandidates() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["python3.9", "python3.12", "python3.13", "python3.14", "python3.15"] {
            try executable(root.appendingPathComponent(name))
        }
        let discovery = AppMCPPythonDiscovery(locations: [.init(directory: root, source: "Fixture")]) { path in
            let version = URL(fileURLWithPath: path).lastPathComponent.replacingOccurrences(of: "python", with: "") + ".0"
            if version == "3.15.0" { throw AppMCPError.configuration("This interpreter cannot start") }
            return self.info(version, path: path, venv: version != "3.12.0")
        }
        discovery.search(); try await settle(discovery)
        #expect(discovery.installations.filter(\.isCompatible).map { $0.info?.version } == ["3.13.0", "3.14.0"])
        #expect(discovery.installations.first { $0.info?.version == "3.9.0" }?.issue?.contains("3.10") == true)
        #expect(discovery.installations.first { $0.info?.version == "3.12.0" }?.issue?.contains("venv") == true)
        #expect(discovery.installations.last { $0.path.hasSuffix("python3.15") }?.issue?.contains("cannot start") == true)
    }

    @Test func cancellingSearchCannotOverwriteTheNextSearchWithLateResults() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try executable(root.appendingPathComponent("python3.13"))
        var calls = 0
        let discovery = AppMCPPythonDiscovery(locations: [.init(directory: root, source: "Fixture")]) { path in
            calls += 1
            let first = calls == 1
            if first { try? await Task.sleep(for: .seconds(10)) }
            return self.info(first ? "3.10.0" : "3.13.0", path: path)
        }
        discovery.search()
        for _ in 0..<100 where calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls == 1)
        discovery.cancel(); discovery.search(); try await settle(discovery)
        #expect(discovery.installations.map { $0.info?.version } == ["3.13.0"])
        #expect(discovery.notice == nil)
    }

    @Test func emptySearchAndCommonVersionManagerPathsAreHandled() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let discovery = AppMCPPythonDiscovery(locations: [.init(directory: root, source: "Empty")]) { _ in
            Issue.record("An empty search must not execute a process")
            throw CancellationError()
        }
        discovery.search(); try await settle(discovery)
        #expect(discovery.hasSearched && discovery.installations.isEmpty)
        let locations = AppMCPPythonDiscovery.defaultLocations(home: root,
            environment: ["PATH": "/custom/bin:.:/custom/pyenv/shims::/custom/bin", "PYENV_ROOT": "/custom/pyenv", "CONDA_PREFIX": "/custom/conda"])
        #expect(locations.contains { $0.directory.path == "/custom/pyenv/versions" })
        #expect(locations.contains { $0.directory.path == "/custom/conda/bin" })
        #expect(locations.filter { $0.directory.path == "/custom/bin" }.count == 1)
        #expect(!locations.contains { $0.directory.lastPathComponent == "shims" })
        #expect(!locations.contains { $0.directory.path == FileManager.default.currentDirectoryPath })
    }

    @Test func installedPythonDiscoverySmokeTest() async throws {
        let discovery = AppMCPPythonDiscovery()
        discovery.search(); try await settle(discovery)
        #expect(discovery.hasSearched)
        for installation in discovery.installations {
            print("Python discovery: \(installation.title) · \(installation.isCompatible ? "compatible" : "unavailable") · \(installation.path)")
            #expect(installation.info != nil || installation.issue != nil)
        }
    }
}
#endif
