# EventSource

A lightweight, spec-compliant Server-Sent Events (SSE) client for Swift.

## Features

- [x] Full implementation of the [Server-Sent Events specification][spec]
- [x] Automatic connection management and reconnection with configurable retry intervals
- [x] Event parsing that handles all standard fields (`id`, `event`, `data`, `retry`)
- [x] Support for different line break formats (`LF`, `CR`, `CRLF`)
- [x] Multi-line data aggregation
- [x] `AsyncSequence` support for streaming events
- [x] Works on all Apple platforms and Linux

## Requirements

- Swift 6.0+ / Xcode 16+

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/mattt/EventSource.git", from: "1.3.0")
]
```

## Usage

### Connecting to an EventSource

Create an `EventSource` with a URL to establish
a persistent connection to an SSE endpoint.
The API mirrors the JavaScript [EventSource interface][mdn]
with event handlers for connection lifecycle management.

```swift
import EventSource
import Foundation

// Initialize with SSE endpoint URL
let sse = EventSource(url: URL(string: "https://example.com/events")!)

// Create an EventSource with the URL
let sse = EventSource(url: url)

// Set up event handlers
sse.onOpen = {
    print("Connection established")
}

sse.onMessage = { e in
    print("Received event: \(e.event): \(e.data)")
}

sse.onError = { error in
    if let error = error {
        print("Error: \(error)")
    } else {
        print("Connection closed")
    }
}

// Later, when done
Task {
    await sse.close()
}
```

### Processing an AsyncSequence of Server-Sent Events

Alternatively, you can process server-sent event data with
Swift's modern `AsyncSequence` API for greater flexibility and control.
Use this approach when you need custom request configuration
or direct integration with existing async / URL Loading System code.

```swift
import EventSource
import Foundation

Task {
    // Create a request to the SSE endpoint
    let url = URL(string: "https://example.com/events")!
    let request = URLRequest(url: url)

    do {
        let (stream, _) = try await URLSession.shared.bytes(for: request)

        // Iterate through events as they arrive
        for try await event in stream.events {
            switch event.event {
            case "update":
                handleUpdate(event.data)
            case "error":
                handleError(event.data)
            default:
                print("Received: \(event.data)")
            }
        }
    } catch {
        print("Stream error: \(error.localizedDescription)")
    }
}
```

### Parsing Server-Sent Events Directly

Use the low-level parser directly to process raw SSE data.
This approach is ideal for custom networking stacks, testing,
or scenarios where you need precise control over state management.

```swift
import EventSource
import Foundation

// Create a parser instance
let parser = EventSource.Parser()

// Process raw SSE data byte-by-byte
let rawData = """
    id: 123
    event: update
    data: {"key": "value"}

    data: Another message

    """.utf8

// Parse the data
Task {
    // Feed bytes to the parser
    for byte in rawData { await parser.consume(byte) }
    await parser.finish()

    // Extract all parsed events
    while let event = await parser.getNextEvent() {
        handleEvent(event)
    }

    // Access state for reconnection logic
    print("Last Event ID: \(await parser.getLastEventId())")
    print("Reconnection time: \(await parser.getReconnectionTime())ms")
}
```

## Examples

### Working with Streaming APIs

Inference providers like Anthropic and OpenAI offer APIs
with endpoints that stream tokens as they're generated.
Here's a simplified example of how you might consume server-sent events
for such an API:

```swift
import EventSource
import Foundation

// Simple model for LLM token streaming
struct TokenChunk: Codable {
    let text: String
    let isComplete: Bool
}

// Create a request to the LLM streaming endpoint
let url = URL(string: "https://api.example.com/completions")!
var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue("Bearer YOUR_API_KEY", forHTTPHeaderField: "Authorization")

// Track the full response
var completedText = ""

// Process the stream asynchronously
Task {
    do {
        // Get a byte stream from URLSession
        let (byteStream, response) = try await URLSession.shared.bytes(for: request)

        // Ensure response is valid
        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200,
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
            contentType.contains("text/event-stream")
        else {
            throw NSError(domain: NSURLErrorDomain,
                        code: NSURLErrorBadServerResponse,
                        userInfo: nil)
        }

        let decoder = JSONDecoder()

        // Stream events asynchronously
        for try await event in byteStream.events {
            // Decode each chunk as it arrives
            let chunk = try decoder.decode(TokenChunk.self,
                                           from: Data(event.data.utf8))

            // Add the new token to our result
            completedText += chunk.text
            print("Text so far: \(completedText)")

            // Check if the response is complete
            if chunk.isComplete {
                print("Final response: \(completedText)")
                break
            }
        }
    } catch {
        print("Stream error: \(error.localizedDescription)")
    }
}
```

## License

This project is available under the MIT license.
See the LICENSE file for more info.

[mdn]: https://developer.mozilla.org/en-US/docs/Web/API/EventSource
[spec]: https://html.spec.whatwg.org/multipage/server-sent-events.html#the-eventsource-interface