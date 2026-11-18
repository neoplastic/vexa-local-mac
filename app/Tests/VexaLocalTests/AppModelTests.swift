import XCTest
@testable import VexaLocal

/// AppModel reads (never writes) UserDefaults.standard in init. These tests only
/// mutate `env`, which is not persisted, so the app's real defaults stay untouched.
@MainActor
final class AppModelTests: XCTestCase {
    func testDefaultPorts() {
        let m = AppModel()
        m.env = [:]
        XCTAssertEqual(m.gatewayURL.absoluteString, "http://localhost:18056")
        XCTAssertEqual(m.adminURL.absoluteString, "http://localhost:18057")
        XCTAssertEqual(m.webAppURL.absoluteString, "http://localhost:13000")
        XCTAssertEqual(m.whisperURL.absoluteString, "http://127.0.0.1:8083")
    }

    func testPortsFromEnv() {
        let m = AppModel()
        m.env = ["API_GATEWAY_HOST_PORT": "1111", "ADMIN_API_PORT": "2222",
                 "TERMINAL_PORT": "3333", "WHISPER_PORT": "4444"]
        XCTAssertEqual(m.gatewayURL.port, 1111)
        XCTAssertEqual(m.adminURL.port, 2222)
        XCTAssertEqual(m.webAppURL.port, 3333)
        XCTAssertEqual(m.whisperURL.port, 4444)
    }

    func testEmptyEnvPortFallsBackToDefault() {
        let m = AppModel()
        m.env = ["API_GATEWAY_HOST_PORT": ""]
        XCTAssertEqual(m.gatewayURL.port, 18056)
    }

    func testClientUsesEnvAndKey() {
        let m = AppModel()
        m.env = ["ADMIN_TOKEN": "tok", "API_GATEWAY_HOST_PORT": "1111"]
        let c = m.client
        XCTAssertEqual(c.adminToken, "tok")
        XCTAssertEqual(c.gateway.port, 1111)
    }

    func testConfiguredModelDefault() {
        let m = AppModel()
        m.env = [:]
        XCTAssertEqual(m.configuredModel, "mlx-community/whisper-large-v3-turbo")
        m.env = ["WHISPER_MODEL": "x/y"]
        XCTAssertEqual(m.configuredModel, "x/y")
    }

    func testGuessProjectPathReturnsAbsolutePath() {
        let p = AppModel.guessProjectPath()
        XCTAssertTrue(p.hasPrefix("/"))
    }
}
