import XCTest

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubProtocol.lastRequest = request
        let (status, body) = StubProtocol.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MutualTLSTests: XCTestCase {
    private let record: [String: Any] = ["type": "cbg", "time": "2024-10-07T12:34:56Z", "value": 121]
    private let statusBody = Data(#"{"mode":"mtls-required","upload_enabled":true,"client":{"presented":true,"authorized":true,"common_name":"mfs-client"}}"#.utf8)

    private func connection(base: String = "https://digitalme.example:8443/") -> ServiceConnection {
        var connection = ServiceConnection(name: "DigitalMe", baseURL: base, auth: .mutualTLS)
        connection.identityLabel = "MFS.mtls.test"
        return connection
    }

    private func client(_ connection: ServiceConnection? = nil) -> DigitalMeUploadClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return DigitalMeUploadClient(connection: connection ?? self.connection(), session: URLSession(configuration: configuration))
    }

    private func stub(upload: Int = 201, status: Int = 200) {
        let body = statusBody
        StubProtocol.handler = { request in
            if request.url?.path == "/security/status" { return (status, body) }
            return (upload, Data(#"{"inserted_count":1}"#.utf8))
        }
    }

    func testUploadURLAppendsPath() {
        XCTAssertEqual(client().uploadURL?.absoluteString, "https://digitalme.example:8443/data/upload")
        XCTAssertNil(client(connection(base: "http://digitalme.example")).uploadURL)
    }

    func testNeverUploadsWithoutConfirmation() async {
        StubProtocol.lastRequest = nil
        do {
            _ = try await client().upload(records: [record], userConfirmed: false)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? DigitalMeUploadError, .notConfirmed)
        }
        XCTAssertNil(StubProtocol.lastRequest)
    }

    func testRejectsRecordsWithoutTypeOrTime() async {
        do {
            _ = try await client().upload(records: [record, ["value": 1]], userConfirmed: true)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? DigitalMeUploadError, .invalidRecord(1))
        }
    }

    func testSuccessChecksSecurityFirstAndReturnsSnapshot() async throws {
        stub()
        let result = try await client().upload(records: [record], userConfirmed: true)
        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.snapshot.level, .mtls)
        XCTAssertEqual(result.change, .first)
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/data/upload")
    }

    func testRefusesToUploadBelowRequiredSecurity() async {
        StubProtocol.handler = { _ in (200, Data(#"{"mode":"tls","client":{"presented":false,"authorized":false}}"#.utf8)) }
        StubProtocol.lastRequest = nil
        do {
            _ = try await client().upload(records: [record], userConfirmed: true)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? DigitalMeUploadError, .securityBelowRequired(actual: .tls, required: .mtls))
        }
        XCTAssertNotEqual(StubProtocol.lastRequest?.url?.path, "/data/upload")
    }

    func testUnacknowledgedDowngradeBlocksUntilAccepted() async throws {
        stub()
        var previous = connection()
        previous.lastSnapshot = SecuritySnapshot(level: .mtls, serverFingerprint: "aa", serverMode: "mtls-required",
                                                 clientCommonName: nil, checkedAt: Date())
        // Delegate-less test sessions report no fingerprint, so weaken the server mode instead.
        let body = Data(#"{"mode":"mtls-optional","upload_enabled":true,"client":{"presented":true,"authorized":true,"common_name":"mfs-client"}}"#.utf8)
        StubProtocol.handler = { request in
            request.url?.path == "/security/status" ? (200, body) : (201, Data(#"{"inserted_count":1}"#.utf8))
        }
        do {
            _ = try await client(previous).upload(records: [record], userConfirmed: true)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? DigitalMeUploadError, .securityChanged(.serverPolicyWeakened(from: "mtls-required", to: "mtls-optional")))
        }
        let accepted = try await client(previous).upload(records: [record], userConfirmed: true, acknowledgedChange: true)
        XCTAssertEqual(accepted.inserted, 1)
    }

    func testRetryableClassification() async {
        for (status, retryable) in [(401, false), (403, false), (400, false), (503, true), (429, true)] {
            stub(upload: status)
            do {
                _ = try await client().upload(records: [record], userConfirmed: true)
                XCTFail("expected error")
            } catch {
                let failure = error as? DigitalMeUploadError
                XCTAssertEqual(failure, .server(status))
                XCTAssertEqual(failure?.isRetryable, retryable, "status \(status)")
            }
        }
    }

    func testClientCertificateChallengeCancelledWithoutIdentity() {
        let delegate = MutualTLSDelegate(host: "digitalme.example", identity: nil, anchors: [])
        let space = URLProtectionSpace(host: "digitalme.example", port: 8443, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                   failureResponse: nil, error: nil, sender: StubSender())
        let done = expectation(description: "challenge")
        delegate.urlSession(.shared, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
    }

    func testBiometricsGoToTheirOwnEndpointAndNeverCarryGlucose() async throws {
        stub()
        let biometric: [String: Any] = ["type": "biometric", "time": "2024-10-07T12:34:56Z", "metric": "heartRate", "amount": ["value": 72, "units": "bpm"]]
        _ = try await client().upload(records: [biometric], to: .biometrics, userConfirmed: true)
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/biometrics/upload")

        do {
            _ = try await client().upload(records: [record], to: .biometrics, userConfirmed: true)
            XCTFail("glucose must not be uploaded as a biometric")
        } catch {
            XCTAssertEqual(error as? DigitalMeUploadError, .invalidRecord(0))
        }
    }
}

private final class StubSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
