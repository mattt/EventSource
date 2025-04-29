import Testing

@testable import EventSource

@Suite("Parser Tests", .timeLimit(.minutes(1)))
struct ParserTests {
    @Test("Basic event parsing")
    func testSimpleEvent() async throws {
        let parser = EventSource.Parser()
        // Test a simple event with data
        let bytes = "data: hello\n\n".utf8
        for byte in bytes {
            await parser.consume(byte)
        }
        await parser.finish()

        let event = await parser.getNextEvent()
        #expect(event != nil)
        #expect(event?.data == "hello")
        #expect(event?.id == nil)
        #expect(event?.event == nil)
        #expect(event?.retry == nil)
    }

    @Test("Event with all fields")
    func testEventWithAllFields() async throws {
        let parser = EventSource.Parser()
        // Test an event with all possible fields
        let bytes = """
            id: 123
            event: test
            data: hello
            retry: 5000

            """.utf8

        for byte in bytes {
            await parser.consume(byte)
        }
        await parser.finish()

        let event = await parser.getNextEvent()
        #expect(event != nil)
        #expect(event?.id == "123")
        #expect(event?.event == "test")
        #expect(event?.data == "hello")
        #expect(event?.retry == 5000)
    }

    @Suite("Line Break Handling")
    struct LineBreakTests {
        @Test("CRLF line breaks")
        func testCRLFLineBreaks() async throws {
            let parser = EventSource.Parser()
            let bytes = "data: hello\r\n\r\n".utf8
            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event = await parser.getNextEvent()
            #expect(event != nil)
            #expect(event?.data == "hello")
        }

        @Test("CR line breaks")
        func testCRLineBreaks() async throws {
            let parser = EventSource.Parser()
            let bytes = "data: hello\r\r".utf8
            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event = await parser.getNextEvent()
            #expect(event != nil)
            #expect(event?.data == "hello")
        }

        @Test("LF line breaks")
        func testLFLineBreaks() async throws {
            let parser = EventSource.Parser()
            let bytes = "data: hello\n\n".utf8
            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event = await parser.getNextEvent()
            #expect(event != nil)
            #expect(event?.data == "hello")
        }
    }

    @Suite("Multiple Events")
    struct MultipleEventsTests {
        @Test("Sequential events")
        func testMultipleEvents() async throws {
            let parser = EventSource.Parser()
            let bytes = """
                data: event1

                data: event2

                """.utf8

            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event1 = await parser.getNextEvent()
            #expect(event1 != nil)
            #expect(event1?.data == "event1")

            let event2 = await parser.getNextEvent()
            #expect(event2 != nil)
            #expect(event2?.data == "event2")

            let event3 = await parser.getNextEvent()
            #expect(event3 == nil)
        }
    }

    @Suite("Data Field Tests")
    struct DataFieldTests {
        @Test("Multi-line data")
        func testMultiLineData() async throws {
            let parser = EventSource.Parser()
            let bytes = """
                data: line1
                data: line2

                """.utf8

            for byte in bytes {
                await parser.consume(byte)
            }

            // Force completion to ensure all data is processed
            await parser.finish()

            let event = await parser.getNextEvent()
            #expect(event != nil)
            #expect(event?.data == "line1\nline2")
        }

        @Test("Empty data")
        func testEmptyData() async throws {
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

    @Suite("Comment Tests")
    struct CommentTests {
        @Test("Comment handling")
        func testComments() async throws {
            let parser = EventSource.Parser()
            let bytes = """
                :comment
                data: hello
                :another comment

                """.utf8

            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event = await parser.getNextEvent()
            #expect(event != nil)
            #expect(event?.data == "hello")
        }

        @Test("Only comments")
        func testOnlyComments() async throws {
            let parser = EventSource.Parser()
            let bytes = """
                :comment line 1
                :comment line 2
                :comment line 3

                """.utf8

            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event = await parser.getNextEvent()
            #expect(event == nil)
        }

        @Test("Complex mixed comments and events")
        func testMixedCommentsAndEvents() async throws {
            let parser = EventSource.Parser()
            let bytes = """
                :initial comment
                data: first line
                :comment between data
                data: second line
                :final comment

                :comment before second event
                id: 123
                :comment between fields
                event: custom
                :comment before data
                data: hello

                """.utf8

            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event1 = await parser.getNextEvent()
            #expect(event1 != nil)
            #expect(event1?.data == "first line\nsecond line")

            let event2 = await parser.getNextEvent()
            #expect(event2 != nil)
            #expect(event2?.id == "123")
            #expect(event2?.event == "custom")
            #expect(event2?.data == "hello")

            let event3 = await parser.getNextEvent()
            #expect(event3 == nil)
        }
    }

    @Suite("Retry Field Tests")
    struct RetryFieldTests {
        @Test("Valid retry value")
        func testRetryField() async throws {
            let parser = EventSource.Parser()
            let bytes = "retry: 1000\n\n".utf8
            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            // A "retry" field alone should not dispatch an event object.
            let event = await parser.getNextEvent()
            #expect(event == nil)
            // It should, however, update the internal reconnection time.
            #expect(await parser.getReconnectionTime() == 1000)
        }

        @Test("Invalid retry value")
        func testInvalidRetryField() async throws {
            let parser = EventSource.Parser()
            let bytes = "retry: invalid\n\n".utf8
            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event = await parser.getNextEvent()
            #expect(event == nil)
            #expect(await parser.getReconnectionTime() == 3000)  // Default value
        }
    }

    @Suite("Last Event ID Tests")
    struct LastEventIDTests {
        @Test("Setting last event ID")
        func testLastEventID() async throws {
            let parser = EventSource.Parser()
            let bytes = """
                id: 123
                data: hello

                """.utf8

            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            _ = await parser.getNextEvent()
            #expect(await parser.getLastEventId() == "123")
        }

        @Test("Empty event ID")
        func testEmptyEventID() async throws {
            let parser = EventSource.Parser()
            let bytes = """
                id:
                data: hello

                """.utf8

            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            _ = await parser.getNextEvent()
            #expect(await parser.getLastEventId() == "")
        }
    }

    @Suite("Event Type Tests")
    struct EventTypeTests {
        @Test("Default event type")
        func testDefaultEventType() async throws {
            let parser = EventSource.Parser()
            let bytes = "data: hello\n\n".utf8
            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event = await parser.getNextEvent()
            #expect(event != nil)
            #expect(event?.event == nil)  // Should be nil for default "message" type
        }

        @Test("Custom event type")
        func testCustomEventType() async throws {
            let parser = EventSource.Parser()
            let bytes = """
                event: custom
                data: hello

                """.utf8

            for byte in bytes {
                await parser.consume(byte)
            }
            await parser.finish()

            let event = await parser.getNextEvent()
            #expect(event != nil)
            #expect(event?.event == "custom")
        }
    }
}
