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
            "/tmp/home/.aeroshift.toml",
            "/tmp/home/.aerospace.toml",
        ]

        let resolved = resolveCustomConfigUrl(
            explicitConfigLocation: nil,
            home: home,
            xdgConfigHome: xdg,
            fileExists: { existing.contains($0.path) },
        )

        assertEquals(resolved.urlOrNil?.path, "/tmp/home/.aeroshift.toml")
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
            "/tmp/home/.aeroshift.toml",
            "/tmp/xdg/aeroshift/aeroshift.toml",
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

        assertEquals(candidates.map(\.path), ["/tmp/home/.aeroshift.toml", "/tmp/xdg/aeroshift/aeroshift.toml"])
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
