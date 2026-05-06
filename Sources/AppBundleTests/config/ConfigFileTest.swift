@testable import AppBundle
import Foundation
import XCTest

final class ConfigFileTest: XCTestCase {
    func testExplicitConfigPathWins() {
        let home = URL(filePath: "/tmp/home")
        let xdg = URL(filePath: "/tmp/xdg")

        let resolved = resolveCustomConfigUrl(
            explicitConfigLocation: "/tmp/custom.toml",
            home: home,
            xdgConfigHome: xdg,
            fileExists: { _ in true },
        )

        assertEquals(resolved.urlOrNil?.path, "/tmp/custom.toml")
    }

    func testAeroshiftConfigWinsOverAerospaceFallback() {
        let home = URL(filePath: "/tmp/home")
        let xdg = URL(filePath: "/tmp/xdg")
        let existing: Set<String> = [
            "/tmp/home/.config/.aeroshift.toml",
            "/tmp/home/.aerospace.toml",
        ]

        let resolved = resolveCustomConfigUrl(
            explicitConfigLocation: nil,
            home: home,
            xdgConfigHome: xdg,
            fileExists: { existing.contains($0.path) },
        )

        assertEquals(resolved.urlOrNil?.path, "/tmp/home/.config/.aeroshift.toml")
    }

    func testInitialConfigPathIsReturnedWhenNoCustomConfigExists() {
        let home = URL(filePath: "/tmp/home")
        let xdg = URL(filePath: "/tmp/xdg")

        guard case .noCustomConfigExists(let initialConfigUrl) = resolveCustomConfigUrl(
            explicitConfigLocation: nil,
            home: home,
            xdgConfigHome: xdg,
            fileExists: { _ in false },
        ) else {
            return XCTFail("Expected missing config")
        }

        assertEquals(initialConfigUrl.path, "/tmp/home/.config/.aeroshift.toml")
    }

    func testCreateInitialConfigFileCopiesDefaultIntoParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "default-config.toml")
        let target = root.appending(path: ".config").appending(path: ".aeroshift.toml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "config-version = 2\n".write(to: source, atomically: true, encoding: .utf8)

        assertSucc(createInitialConfigFile(at: target, from: source))
        assertEquals(try String(contentsOf: target, encoding: .utf8), "config-version = 2\n")
    }

    func testAerospaceFallbackLoadsWhenNoAeroshiftConfigExists() {
        let home = URL(filePath: "/tmp/home")
        let xdg = URL(filePath: "/tmp/xdg")

        let resolved = resolveCustomConfigUrl(
            explicitConfigLocation: nil,
            home: home,
            xdgConfigHome: xdg,
            fileExists: { $0.path == "/tmp/xdg/aerospace/aerospace.toml" },
        )

        assertEquals(resolved.urlOrNil?.path, "/tmp/xdg/aerospace/aerospace.toml")
    }

    func testMultipleAeroshiftConfigsAreAmbiguous() {
        let home = URL(filePath: "/tmp/home")
        let xdg = URL(filePath: "/tmp/xdg")
        let existing: Set<String> = [
            "/tmp/home/.config/.aeroshift.toml",
            "/tmp/home/.aeroshift.toml",
            "/tmp/home/.aerospace.toml",
        ]

        guard case .ambiguousConfigError(let candidates) = resolveCustomConfigUrl(
            explicitConfigLocation: nil,
            home: home,
            xdgConfigHome: xdg,
            fileExists: { existing.contains($0.path) },
        ) else {
            return XCTFail("Expected ambiguity")
        }

        assertEquals(candidates.map(\.path), ["/tmp/home/.config/.aeroshift.toml", "/tmp/home/.aeroshift.toml"])
    }

    func testMultipleAerospaceFallbackConfigsAreAmbiguousOnlyWithoutAeroshiftConfig() {
        let home = URL(filePath: "/tmp/home")
        let xdg = URL(filePath: "/tmp/xdg")
        let existing: Set<String> = [
            "/tmp/home/.aerospace.toml",
            "/tmp/xdg/aerospace/aerospace.toml",
        ]

        guard case .ambiguousConfigError(let candidates) = resolveCustomConfigUrl(
            explicitConfigLocation: nil,
            home: home,
            xdgConfigHome: xdg,
            fileExists: { existing.contains($0.path) },
        ) else {
            return XCTFail("Expected ambiguity")
        }

        assertEquals(candidates.map(\.path), ["/tmp/home/.aerospace.toml", "/tmp/xdg/aerospace/aerospace.toml"])
    }
}
