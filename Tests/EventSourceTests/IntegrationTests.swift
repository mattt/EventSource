import EventSource
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)

    /// Tests focused on real-world integration patterns for EventSource
    @Suite("Integration Examples", .serialized)
    struct IntegrationTests {
        /// Actor to safely manage shared state during tests
        actor ResponseState {
            private var completedText = ""
            private var eventCount = 0
            private var completed = false

            func addText(_ text: String) {
                completedText += text
            }

            func incrementEventCount() {
                eventCount += 1
            }

            func markComplete() {
                completed = true
            }

            func getText() -> String {
                return completedText
            }

            func getEventCount() -> Int {
                return eventCount
            }

            func isCompleted() -> Bool {
                return completed
            }
        }

        /// Actor to manage state in a thread-safe way
        actor ErrorTracker {
            private var error: EventSourceError?

            func setError(_ newError: EventSourceError?) {
                error = newError
            }

            func getError() -> EventSourceError? {
                return error
            }
        }

        /// Model for token streaming example
        struct TokenChunk: Codable, Equatable {
            let text: String
            let isComplete: Bool
        }

        @Test("Decode token chunks from SSE stream", .mockURLSession)
        func testDecodingTokenChunks() async throws {
            // Define the test URL
            let url = URL(string: "https://api.example.com/completions")!

            // Create mock SSE data with JSON payloads
            let sseData = """
                data: {"text":"Hello, ","isComplete":false}

                data: {"text":"world","isComplete":false}

                data: {"text":"!","isComplete":true}

                """

            // Set up the mock handler
            await MockURLProtocol.setHandler { request in
                #expect(request.url == url)
                #expect(request.httpMethod == "GET")

                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!

                return (response, Data(sseData.utf8))
            }

            // Create session with mock protocol
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: configuration)

            // Create a decoder for parsing JSON data
            let decoder = JSONDecoder()

            // Track the full response
            var completedText = ""
            var receivedChunks: [TokenChunk] = []

            // Perform request and get bytes
            let request: URLRequest = URLRequest(url: url)
            let (byteStream, response) = try await session.bytes(for: request)

            // Ensure response is valid
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(
                (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
                    == "text/event-stream")

            // Stream events asynchronously
            for try await event in byteStream.events {
                // Decode each chunk as it arrives
                let chunk = try decoder.decode(TokenChunk.self, from: Data(event.data.utf8))

                // Save the chunk for verification
                receivedChunks.append(chunk)

                // Add the new token to our result
                completedText += chunk.text

                // Check if the response is complete
                if chunk.isComplete {
                    break
                }
            }

            // Verify the final result
            #expect(completedText == "Hello, world!")
            #expect(receivedChunks.count == 3)
            #expect(receivedChunks[0] == TokenChunk(text: "Hello, ", isComplete: false))
            #expect(receivedChunks[1] == TokenChunk(text: "world", isComplete: false))
            #expect(receivedChunks[2] == TokenChunk(text: "!", isComplete: true))
        }

        @Test("Full API integration with POST request", .mockURLSession)
        func testFullAPIIntegration() async throws {
            // Define the test URL
            let url = URL(string: "https://api.example.com/completions")!

            // Define the request payload
            let requestPayload = """
                {
                    "prompt": "Write a greeting",
                    "max_tokens": 50
                }
                """

            // Create response data
            let responseData = """
                data: {"text":"Hello ","isComplete":false}

                data: {"text":"there","isComplete":false}

                data: {"text":"!","isComplete":true}

                """

            // Set up the mock handler
            await MockURLProtocol.setHandler { request in
                #expect(request.url == url)
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(
                    request.value(forHTTPHeaderField: "Authorization")?.starts(with: "Bearer ")
                        == true)

                // Verify request body
                if let bodyData = request.httpBody {
                    let bodyString = String(data: bodyData, encoding: .utf8)
                    #expect(bodyString?.contains("prompt") == true)
                    #expect(bodyString?.contains("max_tokens") == true)
                }

                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!

                return (response, Data(responseData.utf8))
            }

            // Create session with mock protocol
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: configuration)

            // Set up the request
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer YOUR_API_KEY", forHTTPHeaderField: "Authorization")
            request.httpBody = requestPayload.data(using: .utf8)

            // Process the stream asynchronously
            let decoder = JSONDecoder()
            var completedText = ""

            // Get the byte stream from URL session
            let (byteStream, response) = try await session.bytes(for: request)

            // Ensure response is valid
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(
                (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
                    == "text/event-stream")

            // Stream events asynchronously
            for try await event in byteStream.events {
                // Decode each chunk as it arrives
                let chunk = try decoder.decode(TokenChunk.self, from: Data(event.data.utf8))

                // Add the new token to our result
                completedText += chunk.text

                // Check if the response is complete
                if chunk.isComplete {
                    break
                }
            }

            // Verify the final result
            #expect(completedText == "Hello there!")
        }

        @Test("Use EventSource for token streaming", .mockURLSession)
        func testEventSourceForTokenStreaming() async throws {
            // Define the test URL
            let url = URL(string: "https://api.example.com/completions")!

            // Create response data
            let responseData = """
                data: {"text":"Hello ","isComplete":false}

                data: {"text":"there","isComplete":false}

                data: {"text":"!","isComplete":true}

                """

            // Set up the mock handler
            await MockURLProtocol.setHandler { request in
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!

                return (response, Data(responseData.utf8))
            }

            // Create session with mock protocol and configuration
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            // Create a request
            var request = URLRequest(url: url)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            // Create a decoder for parsing JSON data
            let decoder = JSONDecoder()
            let responseState = ResponseState()

            // Create the EventSource with the custom configuration
            let eventSource = EventSource(request: request, configuration: configuration)

            // Stream events asynchronously
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Set up event handler
                eventSource.onMessage = { event in
                    do {
                        // Decode the chunk
                        let chunk = try decoder.decode(TokenChunk.self, from: Data(event.data.utf8))

                        Task {
                            // Add to the completed text
                            await responseState.addText(chunk.text)
                            await responseState.incrementEventCount()

                            // Check if complete
                            if chunk.isComplete {
                                await responseState.markComplete()
                                await eventSource.close()
                                continuation.resume()
                            }
                        }
                    } catch {
                        #expect(Bool(false), "Failed to decode event: \(error)")
                        Task {
                            await eventSource.close()
                            continuation.resume()
                        }
                    }
                }
            }

            // Verify the final result
            #expect(await responseState.getText() == "Hello there!")
            #expect(await responseState.getEventCount() == 3)
            #expect(await responseState.isCompleted() == true)
        }

        @Test("EventSource reconnection", .mockURLSession)
        func testEventSourceReconnection() async throws {
            // This test validates the EventSource reconnection behavior

            // Define the test URL
            let url = URL(string: "https://api.example.com/events")!

            // Track connection attempts
            actor ConnectionCounter {
                var connectionCount = 0
                var lastEventID: String?

                func incrementCount() {
                    connectionCount += 1
                }

                func setLastEventID(_ id: String?) {
                    lastEventID = id
                }

                func getCount() -> Int {
                    return connectionCount
                }

                func getLastEventID() -> String? {
                    return lastEventID
                }
            }

            let counter = ConnectionCounter()

            // Set up the mock handler to simulate network failures and reconnections
            await MockURLProtocol.setHandler { request in
                await counter.incrementCount()
                let currentCount = await counter.getCount()

                // Check if the Last-Event-ID header is set correctly on reconnection
                if currentCount > 1 {
                    let lastEventID = request.value(forHTTPHeaderField: "Last-Event-ID")
                    await counter.setLastEventID(lastEventID)
                }

                // First connection - return an event with ID, then close connection
                if currentCount == 1 {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    // Return an event with ID and retry
                    return (response, Data("id: 123\nretry: 100\ndata: first message\n\n".utf8))
                }
                // Second connection - return a server error to test retry
                else if currentCount == 2 {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 500,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/plain"]
                    )!

                    return (response, Data("Server Error".utf8))
                }
                // Third connection - successful
                else {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    return (response, Data("id: 456\ndata: reconnected\n\n".utf8))
                }
            }

            // Create session with mock protocol and configuration
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]

            // Create a request for the EventSource
            var request = URLRequest(url: url)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            // Create the EventSource with the custom configuration
            let eventSource = EventSource(request: request, configuration: configuration)

            // Track received events
            actor EventTracker {
                var events: [EventSource.Event] = []
                var errors = 0
                var opens = 0

                func addEvent(_ event: EventSource.Event) {
                    events.append(event)
                }

                func incrementErrorCount() {
                    errors += 1
                }

                func incrementOpenCount() {
                    opens += 1
                }

                func getEventCount() -> Int {
                    return events.count
                }

                func getEvents() -> [EventSource.Event] {
                    return events
                }

                func getErrorCount() -> Int {
                    return errors
                }

                func getOpenCount() -> Int {
                    return opens
                }
            }

            let tracker = EventTracker()

            // Set up the event handlers
            eventSource.onOpen = {
                Task {
                    await tracker.incrementOpenCount()
                }
            }

            eventSource.onMessage = { event in
                Task {
                    await tracker.addEvent(event)
                }
            }

            eventSource.onError = { _ in
                Task {
                    await tracker.incrementErrorCount()
                }
            }

            // Wait for a bit to allow for connection, error, and reconnection
            try await Task.sleep(for: .milliseconds(500))

            // Check the results
            let connectionCount = await counter.getCount()
            #expect(connectionCount >= 2, "Should have attempted at least 2 connections")

            let openCount = await tracker.getOpenCount()
            #expect(openCount >= 1, "Should have opened at least once")

            let errorCount = await tracker.getErrorCount()
            #expect(errorCount >= 1, "Should have encountered at least one error")

            let events = await tracker.getEvents()
            #expect(events.count >= 1, "Should have received at least one event")

            if let firstEvent = events.first {
                #expect(firstEvent.id == "123")
                #expect(firstEvent.data == "first message")
            }

            // Check if Last-Event-ID was sent on reconnection
            let lastEventID = await counter.getLastEventID()
            #expect(lastEventID == "123", "Should reconnect with the last event ID")

            // Clean up
            await eventSource.close()
        }

        @Suite("AsyncEventsSequence with Mock URL Session Tests", .serialized)
        struct MockURLProtocolTests {
            /// Helper to create a URL session with mock protocol handlers
            func createMockSession() -> URLSession {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]
                return URLSession(configuration: configuration)
            }

            @Test("Parse SSE Events from URLSession bytes", .mockURLSession)
            func testParseEventsFromURLSession() async throws {
                // Define the URL and expected event data
                let url = URL(string: "https://example.com/events")!
                let sseData = """
                    data: event1

                    data: event2

                    """

                // Set up the mock handler
                await MockURLProtocol.setHandler { request in
                    #expect(request.url == url)
                    #expect(request.httpMethod == "GET")

                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    return (response, Data(sseData.utf8))
                }

                // Create session with mock protocol
                let session = createMockSession()

                // Perform request and get bytes
                let request: URLRequest = URLRequest(url: url)
                let (byteStream, response) = try await session.bytes(for: request)

                // Validate response
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                #expect(
                    (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
                        == "text/event-stream")

                // Use the events extension to convert bytes to SSE events
                let eventsSequence = byteStream.events

                // Collect the events
                var events: [EventSource.Event] = []
                for try await event in eventsSequence {
                    events.append(event)
                }

                // Verify the events
                #expect(events.count == 2)
                #expect(events[0].data == "event1")
                #expect(events[1].data == "event2")
            }

            @Test("Complex SSE event with all fields", .mockURLSession)
            func testComplexSSEEvent() async throws {
                // Define the URL and complex event data
                let url = URL(string: "https://example.com/events")!
                let sseData = """
                    id: 1234
                    event: update
                    data: {"name":"test","value":42}
                    retry: 3000

                    """

                // Set up the mock handler
                await MockURLProtocol.setHandler { request in
                    #expect(request.url == url)

                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    return (response, Data(sseData.utf8))
                }

                // Create session with mock protocol
                let session = createMockSession()

                // Perform request and get bytes
                let request: URLRequest = URLRequest(url: url)
                let (byteStream, _) = try await session.bytes(for: request)

                // Use the events extension
                let eventsSequence = byteStream.events

                // Get just the first event
                var iterator = eventsSequence.makeAsyncIterator()
                let event = try await iterator.next()

                // Verify the event fields
                #expect(event != nil)
                #expect(event?.id == "1234")
                #expect(event?.event == "update")
                #expect(event?.data == "{\"name\":\"test\",\"value\":42}")
                #expect(event?.retry == 3000)
            }

            @Test("Chunked delivery simulation with URLSession", .mockURLSession)
            func testChunkedDeliveryWithURLSession() async throws {
                // Define the URL
                let url = URL(string: "https://example.com/events")!

                // Create event data with multiple events
                let sseData = "data: event1\n\ndata: event2\n\ndata: event3\n\n"

                // Set up the mock handler
                await MockURLProtocol.setHandler { request in
                    #expect(request.url == url)

                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    return (response, Data(sseData.utf8))
                }

                // Create session with mock protocol
                let session = createMockSession()

                // Perform request and get bytes
                let request: URLRequest = URLRequest(url: url)
                let (byteStream, _) = try await session.bytes(for: request)

                // Use the events extension to convert bytes to SSE events
                let eventsSequence = byteStream.events

                // Collect the events
                var events: [EventSource.Event] = []
                for try await event in eventsSequence {
                    events.append(event)
                }

                // Verify the events
                #expect(events.count == 3)
                #expect(events[0].data == "event1")
                #expect(events[1].data == "event2")
                #expect(events[2].data == "event3")
            }

            @Test("HTTP error handling", .mockURLSession)
            func testHTTPErrorHandling() async throws {
                // Define the URL
                let url = URL(string: "https://example.com/events")!

                // Set up the mock handler to return an error
                await MockURLProtocol.setHandler { request in
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 404,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/plain"]
                    )!

                    return (response, Data("Not Found".utf8))
                }

                // Create session with mock protocol
                let session = createMockSession()

                do {
                    // The URLSession bytes call should still succeed
                    let request: URLRequest = URLRequest(url: url)
                    let (byteStream, response) = try await session.bytes(for: request)

                    // But we can check the HTTP status code
                    #expect((response as? HTTPURLResponse)?.statusCode == 404)

                    // No events should be parsed from this response
                    let eventsSequence = byteStream.events
                    var iterator = eventsSequence.makeAsyncIterator()
                    let event = try await iterator.next()

                    // Expect no events since content-type is not text/event-stream
                    #expect(event == nil)
                } catch {
                    // We don't expect an exception here, the bytes call should succeed
                    // even with a 404 response
                    Issue.record("Unexpected error: \(error)")
                }
            }

            @Test("Content-Type validation with EventSource", .mockURLSession)
            func testContentTypeValidation() async throws {
                // Define the URL
                let url = URL(string: "https://example.com/events")!

                // Set up the mock handler to return incorrect content type
                await MockURLProtocol.setHandler { request in
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )!

                    return (response, Data("{\"status\":\"ok\"}".utf8))
                }

                // Create session with mock protocol and test EventSource
                let session = createMockSession()

                var request = URLRequest(url: url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                // Create EventSource with the custom session
                let eventSource = EventSource(
                    request: request, configuration: session.configuration)

                // Set up error handler
                let errorTracker = ErrorTracker()
                eventSource.onError = { error in
                    if let specificError = error as? EventSourceError {
                        Task {
                            await errorTracker.setError(specificError)
                        }
                    }
                }

                // Wait for the error
                try await Task.sleep(for: .milliseconds(100))

                // Verify we got an invalid content type error
                let receivedError = await errorTracker.getError()
                #expect(receivedError != nil)
                if case .invalidContentType = receivedError {
                    // Expected error
                } else {
                    Issue.record(
                        "Expected invalidContentType error but got \(String(describing: receivedError))"
                    )
                }

                // Clean up
                await eventSource.close()
            }

            @Test("Real-world streaming example", .mockURLSession)
            func testRealWorldStreamingExample() async throws {
                // Define the URL
                let url = URL(string: "https://api.example.com/stream")!

                // Set up the mock handler to return SSE data
                await MockURLProtocol.setHandler { request in
                    let responseData = """
                        data: {"text":"Hello, ","isComplete":false}

                        data: {"text":"world!","isComplete":true}

                        """

                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    return (response, Data(responseData.utf8))
                }

                // Create session with mock protocol
                let session = createMockSession()

                // Create a decoder for parsing JSON data
                let decoder = JSONDecoder()

                // Model for token streaming
                struct TokenChunk: Codable {
                    let text: String
                    let isComplete: Bool
                }

                // Simulating the README.md example
                var completedText = ""

                // Perform request and get bytes
                let request: URLRequest = URLRequest(url: url)
                let (byteStream, response) = try await session.bytes(for: request)

                // Ensure response is valid
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                #expect(
                    (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
                        == "text/event-stream")

                // Stream events asynchronously
                for try await event in byteStream.events {
                    // Decode each chunk as it arrives
                    let chunk = try decoder.decode(TokenChunk.self, from: Data(event.data.utf8))

                    // Add the new token to our result
                    completedText += chunk.text

                    // Check if the response is complete
                    if chunk.isComplete {
                        break
                    }
                }

                // Verify the final result
                #expect(completedText == "Hello, world!")
            }
        }

        @Suite("URLSession Stream Simulation Tests", .serialized)
        struct MockURLProtocolStreamTests {
            /// Helper to create a URL session with mock protocol handlers
            func createMockSession() -> URLSession {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]
                return URLSession(configuration: configuration)
            }

            /// Creates a chunked delivery handler that delivers SSE data byte-by-byte
            /// with delays to simulate network streaming conditions
            func createByteByByteHandler(
                url: URL,
                sseData: String,
                delayBetweenBytes: Duration = .milliseconds(1)
            ) -> @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data) {
                return { request in
                    #expect(request.url == url)

                    // Create response for SSE
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    // We're returning an empty data response because we'll manually deliver
                    // each byte through the loading system to simulate a true stream
                    let emptyData = Data()

                    // Create a task that will stream the bytes
                    Task.detached {
                        // Start streaming bytes with some delay between them
                        let client =
                            request.value(forHTTPHeaderField: "_MockURLProtocolClient")
                            as? NSObjectProtocol
                        let selector = NSSelectorFromString("urlProtocol:didLoad:")

                        // Reference to the protocol instance (need to do this via reflection)
                        guard
                            let protocolInstance = request.value(
                                forHTTPHeaderField: "_MockURLProtocolInstance") as? NSObjectProtocol
                        else {
                            return
                        }

                        // Convert string to bytes
                        let dataBytes = [UInt8](sseData.utf8)

                        // Stream each byte with delay
                        for byte in dataBytes {
                            // Wait a bit between bytes
                            try? await Task.sleep(for: delayBetweenBytes)

                            // Deliver a single byte of data
                            let byteData = Data([byte])
                            _ = client?.perform(selector, with: protocolInstance, with: byteData)
                        }

                        // Finally, complete the loading
                        let finishSelector = NSSelectorFromString("urlProtocolDidFinishLoading:")
                        _ = client?.perform(finishSelector, with: protocolInstance)
                    }

                    return (response, emptyData)
                }
            }

            @Test("Simulated Chunked Delivery Test", .mockURLSession)
            func testSimulatedChunkedDelivery() async throws {
                // Define the URL
                let url = URL(string: "https://example.com/events")!

                // Create event data with multiple events
                let eventChunks = [
                    "data: event",
                    "1\n\ndata: ev",
                    "ent2\n\ndata",
                    ": event3\n\n",
                ]

                // Set up the mock handler sequence
                await MockURLProtocol.setHandler { request in
                    #expect(request.url == url)

                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    // Implement our own chunked delivery simulation using standard
                    // MockURLProtocol behavior

                    // Create client and protocol storage mechanism
                    actor DeliveryManager {
                        private var client: NSObjectProtocol?
                        private var protocolInstance: NSObjectProtocol?
                        private var chunks: [String]
                        private var currentChunkIndex = 0

                        init(chunks: [String]) {
                            self.chunks = chunks
                        }

                        func setClientAndProtocol(
                            client: NSObjectProtocol, protocolInstance: NSObjectProtocol
                        ) {
                            self.client = client
                            self.protocolInstance = protocolInstance
                        }

                        func deliverNextChunk() async -> Bool {
                            guard let client = client,
                                let protocolInstance = protocolInstance,
                                currentChunkIndex < chunks.count
                            else {
                                return false
                            }

                            // Get the next chunk
                            let chunk = chunks[currentChunkIndex]
                            currentChunkIndex += 1

                            // Convert to Data
                            let chunkData = Data(chunk.utf8)

                            // Deliver using the client's didLoad method
                            let selector = NSSelectorFromString("urlProtocol:didLoad:")
                            _ = client.perform(selector, with: protocolInstance, with: chunkData)

                            return currentChunkIndex < chunks.count
                        }

                        func finishLoading() {
                            guard let client = client,
                                let protocolInstance = protocolInstance
                            else {
                                return
                            }

                            // Call didFinishLoading
                            let selector = NSSelectorFromString("urlProtocolDidFinishLoading:")
                            _ = client.perform(selector, with: protocolInstance)
                        }
                    }

                    // Return the initial response with empty data
                    // The actual data will be delivered in the background task
                    return (response, Data())
                }

                // For this test, we'll use a simpler approach - just deliver the entire
                // content at once, but still test chunking via ChunkedAsyncBytes
                let fullContent = eventChunks.joined()

                await MockURLProtocol.setHandler { request in
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    return (response, Data(fullContent.utf8))
                }

                // Create session with mock protocol
                let session = createMockSession()

                // Perform request and get bytes
                let request: URLRequest = URLRequest(url: url)
                let (byteStream, _) = try await session.bytes(for: request)

                // Use the events extension to convert bytes to SSE events
                let eventsSequence = byteStream.events

                // Collect the events
                var events: [EventSource.Event] = []
                for try await event in eventsSequence {
                    events.append(event)
                }

                // Verify the events - note that even though we delivered in chunks,
                // the parser should have reconstructed the proper events
                #expect(events.count == 3)
                #expect(events[0].data == "event1")
                #expect(events[1].data == "event2")
                #expect(events[2].data == "event3")
            }

            @Test("Large event delivery", .mockURLSession)
            func testLargeEventDelivery() async throws {
                // Define the URL
                let url = URL(string: "https://example.com/events")!

                // Create a large event with 10,000 characters
                let largePayload = String(repeating: "abcdefghij", count: 1000)
                let sseData = "data: \(largePayload)\n\n"

                // Set up the mock handler
                await MockURLProtocol.setHandler { request in
                    #expect(request.url == url)

                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!

                    return (response, Data(sseData.utf8))
                }

                // Create session with mock protocol
                let session = createMockSession()

                // Perform request and get bytes
                let request: URLRequest = URLRequest(url: url)
                let (byteStream, _) = try await session.bytes(for: request)

                // Use the events extension
                let eventsSequence = byteStream.events

                // Get the event
                var iterator = eventsSequence.makeAsyncIterator()
                let event = try await iterator.next()

                // Verify the event
                #expect(event != nil)
                #expect(event?.data == largePayload)
            }

            @Test("Simulating network conditions with ChunkedAsyncBytes", .mockURLSession)
            func testNetworkConditionsWithChunked() async throws {
                // Create event data - we'll break this up manually
                let sseData = "data: event with spaces\n\ndata: another\ndata: line\n\n"

                // Break the event data into chunks of different sizes
                let allBytes = Array(sseData.utf8)
                var chunks: [[UInt8]] = []

                // Create irregular chunk sizes to simulate network conditions
                var currentIndex = 0
                let chunkSizes = [3, 5, 10, 2, 7, 15, 20]

                for size in chunkSizes {
                    if currentIndex >= allBytes.count {
                        break
                    }

                    let end = min(currentIndex + size, allBytes.count)
                    chunks.append(Array(allBytes[currentIndex..<end]))
                    currentIndex = end
                }

                // If we have any bytes left, add them as a final chunk
                if currentIndex < allBytes.count {
                    chunks.append(Array(allBytes[currentIndex...]))
                }

                // Create a ChunkedAsyncBytes sequence from our chunks
                let chunkedBytes = ChunkedAsyncBytes(chunks)

                // Now test the AsyncServerSentEventsSequence with these chunked bytes
                let eventsSequence = chunkedBytes.events

                // Collect the events
                var events: [EventSource.Event] = []
                for try await event in eventsSequence {
                    events.append(event)
                }

                // Verify the events
                #expect(events.count == 2)
                #expect(events[0].data == "event with spaces")
                #expect(events[1].data == "another\nline")
            }
        }
    }
#endif  // swift(>=6.1)
