import Foundation
import Testing

@testable import EventSource

@Suite("AsyncEventsSequence Tests", .timeLimit(.minutes(1)))
struct AsyncEventsSequenceTests {
    @Test("Basic event parsing from byte sequence")
    func testBasicEventParsing() async throws {
        // Create a simple SSE data string
        let sseData = "data: hello\n\n"

        // Convert to async sequence of bytes
        let byteSequence = AsyncBytes(sseData.utf8)

        // Use the events extension to get AsyncServerSentEventsSequence
        let eventsSequence = byteSequence.events

        // Collect all events to verify there's exactly one
        var events = [EventSource.Event]()
        for try await event in eventsSequence {
            events.append(event)
        }

        #expect(events.count == 1)
        #expect(events[0].data == "hello")
        #expect(events[0].id == nil)
        #expect(events[0].event == nil)
    }

    @Test("Multiple events parsing")
    func testMultipleEventsParsing() async throws {
        // Create a string with multiple SSE events
        let sseData = """
            data: event1

            data: event2

            """

        // Convert to async sequence of bytes
        let byteSequence = AsyncBytes(sseData.utf8)

        // Use the events extension
        let eventsSequence = byteSequence.events

        // Collect all events
        var events: [EventSource.Event] = []
        for try await event in eventsSequence {
            events.append(event)
        }

        #expect(events.count == 2)
        #expect(events[0].data == "event1")
        #expect(events[1].data == "event2")
    }

    @Test("Event with all fields")
    func testEventWithAllFields() async throws {
        let sseData = """
            id: 123
            event: test
            data: hello
            retry: 5000

            """

        var iterator = AsyncBytes(sseData.utf8).events.makeAsyncIterator()
        let event = try await iterator.next()

        #expect(event != nil)
        #expect(event?.id == "123")
        #expect(event?.event == "test")
        #expect(event?.data == "hello")
        #expect(event?.retry == 5000)
    }

    @Test("Empty sequence")
    func testEmptySequence() async throws {
        let emptySequence = AsyncBytes("".utf8).events
        var iterator = emptySequence.makeAsyncIterator()
        let event = try await iterator.next()
        #expect(event == nil)
    }

    @Suite("Line Break Handling")
    struct LineBreakTests {
        @Test("CRLF line breaks")
        func testCRLFLineBreaks() async throws {
            let sseData = "data: hello\r\n\r\n"
            var iterator = AsyncBytes(sseData.utf8).events.makeAsyncIterator()
            let event = try await iterator.next()

            #expect(event != nil)
            #expect(event?.data == "hello")
        }

        @Test("CR line breaks")
        func testCRLineBreaks() async throws {
            let sseData = "data: hello\r\r"
            var iterator = AsyncBytes(sseData.utf8).events.makeAsyncIterator()
            let event = try await iterator.next()

            #expect(event != nil)
            #expect(event?.data == "hello")
        }
    }

    @Suite("Comment Handling")
    struct CommentTests {
        @Test("Comments in event stream")
        func testComments() async throws {
            let sseData = """
                :comment line
                data: hello
                :another comment

                """

            var iterator = AsyncBytes(sseData.utf8).events.makeAsyncIterator()
            let event = try await iterator.next()

            #expect(event != nil)
            #expect(event?.data == "hello")
        }

        @Test("Only comments")
        func testOnlyComments() async throws {
            let sseData = """
                :comment line 1
                :comment line 2

                """

            var iterator = AsyncBytes(sseData.utf8).events.makeAsyncIterator()
            let event = try await iterator.next()
            #expect(event == nil)
        }
    }

    @Suite("Multi-line Data")
    struct MultilineDataTests {
        @Test("Multiple data lines")
        func testMultipleDataLines() async throws {
            let sseData = """
                data: line1
                data: line2
                data: line3

                """

            var iterator = AsyncBytes(sseData.utf8).events.makeAsyncIterator()
            let event = try await iterator.next()

            #expect(event != nil)
            #expect(event?.data == "line1\nline2\nline3")
        }

        @Test("Empty data line")
        func testEmptyDataLine() async throws {
            // The SSE spec states that if there's a data: field with no value,
            // it should be treated as an empty string value, not as absent data
            let parser = EventSource.Parser()
            let bytes = "data:\n\n".utf8
            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event = await parser.getNextEvent()
            #expect(event != nil)
            #expect(event?.data == "")
        }
    }

    @Suite("Retry Field")
    struct RetryFieldTests {
        @Test("Only retry field - no event")
        func testOnlyRetryField() async throws {
            let sseData = "retry: 1000\n\n"

            var iterator = AsyncBytes(sseData.utf8).events.makeAsyncIterator()
            let event = try await iterator.next()
            #expect(event == nil)
        }

        @Test("Retry with data")
        func testRetryWithData() async throws {
            let sseData = """
                retry: 1000
                data: hello

                """

            var iterator = AsyncBytes(sseData.utf8).events.makeAsyncIterator()
            let event = try await iterator.next()
            #expect(event != nil)
            #expect(event?.data == "hello")
            #expect(event?.retry == 1000)
        }
    }

    @Suite("Chunked Data")
    struct ChunkedDataTests {
        @Test("Chunked delivery simulation")
        func testChunkedDelivery() async throws {
            // Simulate chunked SSE data delivery
            let eventData = "id: 123\nevent: update\ndata: partial content\ndata: more content\n\n"

            // Break the event data into smaller chunks
            let allBytes = Array(eventData.utf8)
            let chunkSize = 8
            var chunks: [[UInt8]] = []

            for i in stride(from: 0, to: allBytes.count, by: chunkSize) {
                let end = min(i + chunkSize, allBytes.count)
                chunks.append(Array(allBytes[i..<end]))
            }

            let chunkedSequence = ChunkedAsyncBytes(chunks)

            // Collect all events
            var events: [EventSource.Event] = []
            for try await event in chunkedSequence.events {
                events.append(event)
            }

            #expect(events.count == 1)
            #expect(events[0].id == "123")
            #expect(events[0].event == "update")
            #expect(events[0].data == "partial content\nmore content")
        }

        @Test("Event spanning multiple chunks")
        func testEventSpanningChunks() async throws {
            // Create events with fixed size, non-recursive approach
            let eventData = "data: first event\n\ndata: second event\n\ndata: third event\n\n"

            // Break into fixed chunks for testing
            let allBytes = Array(eventData.utf8)
            let chunkSize = 10
            var chunks: [[UInt8]] = []

            for i in stride(from: 0, to: allBytes.count, by: chunkSize) {
                let end = min(i + chunkSize, allBytes.count)
                chunks.append(Array(allBytes[i..<end]))
            }

            let chunkedSequence = ChunkedAsyncBytes(chunks)

            // Collect all events
            var events: [EventSource.Event] = []
            for try await event in chunkedSequence.events {
                events.append(event)
            }

            #expect(events.count == 3)
            #expect(events[0].data == "first event")
            #expect(events[1].data == "second event")
            #expect(events[2].data == "third event")
        }
    }

    @Test("Integration with AsyncSequence operators")
    func testAsyncSequenceIntegration() async throws {
        let sseData = "data: event1\n\ndata: event2\n\ndata: event3\n\n"

        // Convert to async sequence of bytes
        let byteSequence = AsyncBytes(sseData.utf8)

        // Create a fresh events sequence for each test to avoid issues
        var events: [EventSource.Event] = []
        for try await event in byteSequence.events {
            events.append(event)
        }
        
        // Verify we got all three events
        #expect(events.count == 3)
        #expect(events[0].data == "event1")
        #expect(events[1].data == "event2")
        #expect(events[2].data == "event3")
    }
}
