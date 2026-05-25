import XCTest

final class BlinkAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testAuthenticateSuccessSetsProperties() async throws {
        let expectedAccountID = 12345
        let expectedClientID = 98765
        let expectedToken = "auth-token-abc123"

        MockURLProtocol.setHandler { request in
            let response = httpResponse(request.url!, 200)
            let body = """
            {
                "account": {
                    "id": \(expectedAccountID),
                    "client_id": \(expectedClientID)
                },
                "auth": {
                    "token": "\(expectedToken)"
                }
            }
            """
            return (response, Data(body.utf8))
        }

        let client = BlinkAPIClient(session: .mocked())

        try await client.authenticate(email: "test@example.com", password: "password")

        let authToken = await client.authToken
        let accountID = await client.accountID
        let clientID = await client.clientID

        XCTAssertEqual(authToken, expectedToken)
        XCTAssertEqual(accountID, String(expectedAccountID))
        XCTAssertEqual(clientID, String(expectedClientID))
    }

    func testAuthenticateMFARequiredThrows() async {
        MockURLProtocol.setHandler { request in
            let response = httpResponse(request.url!, 202)
            return (response, Data())
        }

        let client = BlinkAPIClient(session: .mocked())

        do {
            try await client.authenticate(email: "test@example.com", password: "password")
            XCTFail("Expected .mfaRequired error")
        } catch BlinkAPIError.mfaRequired {
            // Test passes
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGetEventsParsesTwoEvents() async throws {
        MockURLProtocol.setHandler { request in
            let response = httpResponse(request.url!, 200)
            let body = """
            {
                "event": [
                    {
                        "id": 1001,
                        "created_at": "2023-10-05T14:30:00Z",
                        "camera_id": 5,
                        "network_id": 1,
                        "type": "motion",
                        "media_url": "https://example.com/media1.mp4"
                    },
                    {
                        "id": 1002,
                        "created_at": "2023-10-05T15:45:00Z",
                        "camera_id": 6,
                        "network_id": 1,
                        "type": "doorbell",
                        "media_url": null
                    }
                ]
            }
            """
            return (response, Data(body.utf8))
        }

        let client = BlinkAPIClient(session: .mocked())

        let events = try await client.getEvents(networkID: "1")

        XCTAssertEqual(events.count, 2)

        let firstEvent = events[0]
        XCTAssertEqual(firstEvent.id, 1001)
        XCTAssertEqual(firstEvent.created_at, "2023-10-05T14:30:00Z")
        XCTAssertEqual(firstEvent.camera_id, 5)
        XCTAssertEqual(firstEvent.network_id, 1)
        XCTAssertEqual(firstEvent.type, "motion")
        XCTAssertEqual(firstEvent.media_url, "https://example.com/media1.mp4")

        let secondEvent = events[1]
        XCTAssertEqual(secondEvent.id, 1002)
        XCTAssertEqual(secondEvent.created_at, "2023-10-05T15:45:00Z")
        XCTAssertEqual(secondEvent.camera_id, 6)
        XCTAssertEqual(secondEvent.network_id, 1)
        XCTAssertEqual(secondEvent.type, "doorbell")
        XCTAssertNil(secondEvent.media_url)
    }

    func testDownloadMedia403ThrowsUnexpectedStatusCode() async {
        MockURLProtocol.setHandler { request in
            let response = httpResponse(request.url!, 403)
            return (response, Data("Forbidden".utf8))
        }

        let client = BlinkAPIClient(session: .mocked())
        let testURL = URL(string: "https://example.com/media.mp4")!

        do {
            _ = try await client.downloadMedia(url: testURL)
            XCTFail("Expected .unexpectedStatusCode(403) error")
        } catch BlinkAPIError.unexpectedStatusCode(403) {
            // Test passes
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
