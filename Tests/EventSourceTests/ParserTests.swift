import EventSource
import Testing

@Suite("EventSource Parser Tests", .timeLimit(.minutes(1)))
struct ParserTests {
    @Test("Empty stream produces no events")
    func testEmptyStreamProducesNoEvents() async {
        let events = await getEvents(from: "")
        #expect(events.isEmpty)
    }

    @Test("Comment only stream produces no events")
    func testCommentOnlyStreamProducesNoEvents() async {
        let stream = ":comment line 1\n:comment line 2\r\n"
        let events = await getEvents(from: stream)
        #expect(events.isEmpty)
    }

    @Suite("Single Line Event Tests")
    struct SingleLineEventTests {
        @Test("LF line breaks")
        func testSingleLineEventLF() async {
            let stream = "data: test data\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "test data")
            #expect(events.first?.id == nil)
            #expect(events.first?.event == nil)
        }

        @Test("CR line breaks")
        func testSingleLineEventCR() async {
            let stream = "data: test data\r\r"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "test data")
        }

        @Test("CRLF line breaks")
        func testSingleLineEventCRLF() async {
            let stream = "data: test data\r\n\r\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "test data")
        }
    }

    @Test("Multi-line data")
    func testMultiLineData() async {
        let stream = "data: line1\ndata: line2\n\n"
        let events = await getEvents(from: stream)
        #expect(events.count == 1)
        #expect(events.first?.data == "line1\nline2")
    }

    @Suite("Event Field Tests")
    struct EventFieldTests {
        @Test("Event with ID")
        func testEventWithID() async {
            let stream = "id: 123\ndata: test data\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.id == "123")
            #expect(events.first?.data == "test data")
            let parser = EventSource.Parser()
            for byte in "id: 123\n".utf8 {
                await parser.consume(byte)
            }
            #expect(await parser.getLastEventId() == "123")
        }

        @Test("Event with NUL in ID is ignored")
        func testEventWithNULInIDIsIgnoredAndDoesNotSetLastEventID() async {
            let stream = "id: abc\0def\ndata: test\n\n"  // ID with NUL
            let parser = EventSource.Parser()

            // Consume the stream
            for byte in stream.utf8 {
                await parser.consume(byte)
            }
            await parser.finish()

            // Check that lastEventId was not updated with the NUL-containing ID
            #expect(
                await parser.getLastEventId() == "",
                "LastEventId should not be set to a value containing NUL.")

            // Check the dispatched event
            var dispatchedEvents: [EventSource.Event] = []
            while let event = await parser.getNextEvent() {
                dispatchedEvents.append(event)
            }

            #expect(dispatchedEvents.count == 1)
            #expect(
                dispatchedEvents.first?.id == nil,
                "Event's ID field should be nil because the raw ID field contained NUL.")
            #expect(dispatchedEvents.first?.data == "test")
        }

        @Test("ID reset by empty ID line")
        func testIDResetByEmptyIDLine() async {
            let stream = "id: 123\ndata: event1\n\nid: \ndata: event2\n\n"
            let parser = EventSource.Parser()

            for byte in stream.utf8 {
                await parser.consume(byte)
            }
            await parser.finish()

            var events: [EventSource.Event] = []
            while let event = await parser.getNextEvent() {
                events.append(event)
            }

            #expect(events.count == 2)
            #expect(events[0].id == "123", "First event should have id '123'")
            #expect(events[0].data == "event1")

            // After "id: " line, lastEventId should be reset to empty string
            #expect(
                await parser.getLastEventId() == "",
                "lastEventID should be reset to empty string by an 'id:' line.")

            #expect(
                events[1].id == "",  // Changed from nil to empty string
                "Second event's currentEventId should be empty string as 'id:' resets it.")
            #expect(events[1].data == "event2")
        }

        @Test("Event with name")
        func testEventWithName() async {
            let stream = "event: custom\ndata: test data\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.event == "custom")
            #expect(events.first?.data == "test data")
        }

        @Test("Retry field")
        func testRetryField() async {
            let stream = "retry: 5000\ndata: test data\n\n"
            let parser = EventSource.Parser()
            // Manually consume and finish to inspect parser state before getting all events
            for byte in stream.utf8 {
                await parser.consume(byte)
            }
            await parser.finish()

            // Check reconnection time on parser
            #expect(await parser.getReconnectionTime() == 5000)

            var events: [EventSource.Event] = []
            while let event = await parser.getNextEvent() { events.append(event) }

            #expect(events.count == 1)
            #expect(events.first?.data == "test data")
            #expect(
                events.first?.retry == 5000,
                "The retry value should be part of the event if dispatched with it.")
        }

        @Test("Retry field only updates reconnection time")
        func testRetryFieldOnlyUpdatesReconnectionTimeDoesNotDispatchEvent() async {
            let stream = "retry: 1234\n\n"  // Only retry, no data or other fields
            let parser = EventSource.Parser()
            let initialReconnectionTime = await parser.getReconnectionTime()

            let events = await getEvents(from: stream, parser: parser)

            #expect(
                events.isEmpty,
                "A message containing only a 'retry' field should not produce an event.")
            #expect(await parser.getReconnectionTime() == 1234)
            #expect(initialReconnectionTime != 1234)
        }

        @Test("Invalid retry value")
        func testInvalidRetryField() async {
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

    @Test("Multiple events")
    func testMultipleEvents() async {
        let stream = "data: event1\n\nevent: custom\ndata: event2\nid: e2\n\n"
        let events = await getEvents(from: stream)
        #expect(events.count == 2)

        #expect(events[0].data == "event1")
        #expect(events[0].event == nil)
        #expect(events[0].id == nil)

        #expect(events[1].data == "event2")
        #expect(events[1].event == "custom")
        #expect(events[1].id == "e2")
    }

    @Test("Mixed line endings produce correct events")
    func testMixedLineEndingsProduceCorrectEvents() async {
        let stream =
            "data: event1\r\r" + "data: event2\n\n" + "data: event3\r\n\r\n"
            + "id: e4\rdata: event4\r\r"  // `id: e4` is one line, `data: event4` is next, then dispatch
            + "event: custom\ndata: event5\n\n"

        let events = await getEvents(from: stream)
        #expect(events.count == 5)
        #expect(events[0].data == "event1")
        #expect(events[1].data == "event2")
        #expect(events[2].data == "event3")
        #expect(events[3].id == "e4")
        #expect(events[3].data == "event4")
        #expect(events[4].event == "custom")
        #expect(events[4].data == "event5")
    }

    @Suite("Field Parsing Tests")
    struct FieldParsingTests {
        @Test("Colon space parsing")
        func testColonSpaceParsing() async {
            // Case 1: "data:value"
            let stream1 = "data:value1\n\n"
            let events1 = await getEvents(from: stream1)
            #expect(events1.count == 1)
            #expect(events1.first?.data == "value1")

            // Case 2: "data: value" (single leading space after colon)
            let stream2 = "data: value2\n\n"
            let events2 = await getEvents(from: stream2)
            #expect(events2.count == 1)
            #expect(events2.first?.data == "value2")

            // Case 3: "data:  value" (multiple leading spaces after colon)
            let stream3 = "data:  value3\n\n"
            let events3 = await getEvents(from: stream3)
            #expect(events3.count == 1)
            #expect(events3.first?.data == " value3", "Only one leading space should be trimmed.")
        }

        @Test("Unicode in data")
        func testUnicodeInData() async {
            // Adapted from https://github.com/launchdarkly/swift-eventsource/blob/193c097f324666691f71b49b1e70249ef21f9f62/Tests/UTF8LineParserTests.swift#L59
            let unicodeData = "¯\\_(ツ)_/¯0️⃣🇺🇸Z̮̞̠͙͔ͅḀ̗̞͈̻̗Ḷ͙͎̯̹̞͓G̻O̭̗̮𝓯𝓸𝔁✅"
            let stream = "data: \(unicodeData)\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == unicodeData)
        }

        @Test("NUL character in data")
        func testNULCharacterInData() async {
            let dataWithNul = "hello\0world"
            let stream = "data: \(dataWithNul)\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == dataWithNul)
        }

        @Test("Invalid UTF8 sequence becomes replacement character")
        func testInvalidUTF8SequenceBecomesReplacementCharacter() async {
            // Create a byte array with an invalid UTF-8 sequence
            var invalidBytesStream: [UInt8] = []
            // Add "data: test" as raw bytes
            invalidBytesStream.append(contentsOf: [
                0x64, 0x61, 0x74, 0x61, 0x3A, 0x20, 0x74, 0x65, 0x73, 0x74,
            ])
            invalidBytesStream.append(0xFF)  // Invalid UTF-8 byte
            // Add "string" as raw bytes
            invalidBytesStream.append(contentsOf: [0x73, 0x74, 0x72, 0x69, 0x6E, 0x67])
            // Add newlines
            invalidBytesStream.append(contentsOf: [0x0A, 0x0A])

            let parser = EventSource.Parser()
            // Process each byte individually
            for byte in invalidBytesStream {
                await parser.consume(byte)
            }
            await parser.finish()

            var events: [EventSource.Event] = []
            while let event = await parser.getNextEvent() {
                events.append(event)
            }

            #expect(events.count == 1)
            #expect(
                events.first?.data == "test\u{FFFD}string",
                "Invalid UTF-8 byte should be replaced by replacement character.")
        }

        @Test("Field without colon is ignored")
        func testFieldWithoutColonIsIgnored() async {
            let stream = "data test\n\n"
            let events = await getEvents(from: stream)
            #expect(events.isEmpty)
        }

        @Test("Field with empty name is ignored")
        func testFieldWithEmptyNameIsIgnored() async {
            let stream = ": value\n\n"
            let events = await getEvents(from: stream)
            #expect(events.isEmpty)
        }

        @Test("Field with empty value")
        func testFieldWithEmptyValue() async {
            let stream = "data:\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "")
        }

        @Test("Field with only spaces after colon")
        func testFieldWithOnlySpacesAfterColon() async {
            let stream = "data:   \n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "  ")
        }

        @Test("Field with tab after colon")
        func testFieldWithTabAfterColon() async {
            let stream = "data:\tvalue\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "\tvalue")
        }

        @Test("Field with multiple colons")
        func testFieldWithMultipleColons() async {
            let stream = "data:value:with:colons\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "value:with:colons")
        }

        @Test("Field with leading and trailing spaces")
        func testFieldWithLeadingAndTrailingSpaces() async {
            let stream = "data:  value  \n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == " value  ")
        }
    }

    @Suite("Empty Field Tests")
    struct EmptyFieldTests {
        @Test("Empty data field dispatch")
        func testEmptyDataFieldDispatch() async {
            // An event with a "data" field that results in empty string data should still be dispatched.
            // "data" (field name with empty value)
            let stream1 = "data\n\n"
            let events1 = await getEvents(from: stream1)
            #expect(events1.count == 1, "Event should be dispatched for 'data' field.")
            #expect(events1.first?.data == "", "Data should be empty string.")

            // "data:" (field name with explicit empty value)
            let stream2 = "data:\n\n"
            let events2 = await getEvents(from: stream2)
            #expect(events2.count == 1, "Event should be dispatched for 'data:' field.")
            #expect(events2.first?.data == "", "Data should be empty string.")
        }

        @Test("Fields without value are processed correctly")
        func testFieldsWithoutValueAreProcessedCorrectly() async {
            // According to spec:
            // - "event" (no value): event type set to empty string.
            // - "data" (no value): data buffer gets an empty string.
            // - "id" (no value): last event ID set to empty string. (currentEventId for dispatch is empty string)
            // - "retry" (no value or invalid): ignored.
            let stream = "event\ndata\nid\nretry\n\n"
            let parser = EventSource.Parser()
            let initialReconnectTime = await parser.getReconnectionTime()

            let events = await getEvents(from: stream, parser: parser)
            #expect(events.count == 1)
            #expect(events.first?.data == "", "Data from 'data' line without value.")
            #expect(events.first?.event == "", "Event type from 'event' line without value.")
            #expect(
                events.first?.id == "",  // Changed from nil to empty string
                "currentEventId should be empty string as 'id' line had no value.")
            #expect(
                await parser.getLastEventId() == "",
                "LastEventId should be empty string from 'id' line without value.")
            #expect(
                await parser.getReconnectionTime() == initialReconnectTime,
                "Empty 'retry' field should not change reconnection time.")
        }
    }

    @Suite("Comment and Line Tests")
    struct CommentAndLineTests {
        @Test("Only comment lines and empty lines produce no events")
        func testOnlyCommentLinesAndEmptyLinesProduceNoEvents() async {
            let stream = ":comment\n\n:another comment\r\n\r\n"  // Includes dispatch-triggering empty lines but no data fields
            let events = await getEvents(from: stream)
            #expect(
                events.isEmpty,
                "Stream with only comments and blank lines should produce no events if no data fields were processed."
            )
        }

        @Test("Line without colon is ignored")
        func testLineWithoutColonIsIgnored() async {
            let stream = "this is a bogus line\ndata: valid\n\nthis is also bogus\r\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1, "Only one event from the valid 'data: valid' line.")
            #expect(events.first?.data == "valid")
        }

        @Test("Complex mixed comments and events")
        func testMixedCommentsAndEvents() async {
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

        @Test("Final line unterminated is processed by finish")
        func testFinalLineUnterminatedIsProcessedByCurrentFinishLogic() async {
            // This test reflects the current behavior of Parser.finish().
            // As noted, the SSE spec suggests an unterminated final block without a blank line should be discarded.
            // Your parser's finish() method currently dispatches such events.
            let stream = "data: final event"  // No trailing newline or blank line
            let events = await getEvents(from: stream)
            #expect(
                events.count == 1, "Event should be dispatched based on current finish() logic.")
            #expect(events.first?.data == "final event")

            let streamWithID = "id: lastid\ndata: final event with id"
            let events2 = await getEvents(from: streamWithID)
            #expect(events2.count == 1)
            #expect(events2.first?.id == "lastid")
            #expect(events2.first?.data == "final event with id")
        }

        @Test("Empty comment")
        func testEmptyComment() async {
            let stream = ":\ndata: test\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "test")
        }

        @Test("Comment with colon in body")
        func testCommentWithColonInBody() async {
            let stream = ":comment:with:colons\ndata: test\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "test")
        }

        @Test("Comment with leading space")
        func testCommentWithLeadingSpace() async {
            let stream = ": comment with leading space\ndata: test\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "test")
        }

        @Test("Multiple consecutive comments")
        func testMultipleConsecutiveComments() async {
            let stream = ":comment1\n:comment2\n:comment3\ndata: test\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "test")
        }

        @Test("Comment between data lines")
        func testCommentBetweenDataLines() async {
            let stream = "data: line1\n:comment\ndata: line2\n\n"
            let events = await getEvents(from: stream)
            #expect(events.count == 1)
            #expect(events.first?.data == "line1\nline2")
        }
    }

    @Suite("BOM Tests")
    struct BOMTests {
        @Test("UTF8 BOM at stream start is handled")
        func testUtf8BOMAtStreamStartIsHandled() async {
            // Create a byte array with UTF-8 BOM followed by SSE content
            var fullStreamBytes: [UInt8] = []
            // Add UTF-8 BOM
            fullStreamBytes.append(contentsOf: [0xEF, 0xBB, 0xBF])
            // Add SSE message
            fullStreamBytes.append(
                contentsOf: createSSEMessage(fields: [
                    (name: "data", value: "test with bom")
                ]))

            let parser = EventSource.Parser()
            // Process each byte individually
            for byte in fullStreamBytes {
                await parser.consume(byte)
            }
            await parser.finish()

            var events: [EventSource.Event] = []
            while let event = await parser.getNextEvent() {
                events.append(event)
            }

            #expect(events.count == 1, "One event should be parsed.")
            #expect(
                events.first?.data == "test with bom",
                "Data should be correct, implying BOM was handled by UTF-8 decoding before field parsing."
            )
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

        @Test("Retry with no space after colon")
        func testRetryWithNoSpace() async {
            let stream = "retry:7000\ndata: test\n\n"
            let parser = EventSource.Parser()
            for byte in stream.utf8 {
                await parser.consume(byte)
            }
            await parser.finish()
            #expect(await parser.getReconnectionTime() == 7000)
        }

        @Test("Retry with non-numeric value")
        func testRetryWithNonNumericValue() async {
            let stream = "retry: 7000L\ndata: test\n\n"
            let parser = EventSource.Parser()
            let initialReconnectionTime = await parser.getReconnectionTime()
            for byte in stream.utf8 {
                await parser.consume(byte)
            }
            await parser.finish()
            #expect(await parser.getReconnectionTime() == initialReconnectionTime)
        }

        @Test("Empty retry field")
        func testEmptyRetryField() async {
            let stream = "retry\ndata: test\n\n"
            let parser = EventSource.Parser()
            let initialReconnectionTime = await parser.getReconnectionTime()
            for byte in stream.utf8 {
                await parser.consume(byte)
            }
            await parser.finish()
            #expect(await parser.getReconnectionTime() == initialReconnectionTime)
        }

        @Test("Retry with out of bounds value")
        func testRetryWithOutOfBoundsValue() async {
            let stream = "retry: 10000000000000000000000000\ndata: test\n\n"
            let parser = EventSource.Parser()
            let initialReconnectionTime = await parser.getReconnectionTime()
            for byte in stream.utf8 {
                await parser.consume(byte)
            }
            await parser.finish()
            #expect(await parser.getReconnectionTime() == initialReconnectionTime)
        }

        @Test("Retry persists across events")
        func testRetryPersistsAcrossEvents() async {
            let stream = "retry: 7000\ndata: event1\n\nretry: 5000\ndata: event2\n\n"
            let parser = EventSource.Parser()
            for byte in stream.utf8 {
                await parser.consume(byte)
            }
            await parser.finish()
            #expect(await parser.getReconnectionTime() == 5000)
        }
    }
}

// Helper to consume a string and get all dispatched events
private func getEvents(
    from input: String,
    parser: EventSource.Parser = EventSource.Parser()
)
    async -> [EventSource.Event]
{
    for byte in input.utf8 {
        await parser.consume(byte)
    }
    // Call finish to process any buffered line and dispatch pending event based on current parser logic.
    await parser.finish()
    var events: [EventSource.Event] = []
    while let event = await parser.getNextEvent() {
        events.append(event)
    }
    return events
}

// Helper function to create a properly formatted SSE field
private func createSSEField(name: String, value: String) -> [UInt8] {
    var bytes: [UInt8] = []
    // Add field name and colon
    bytes.append(contentsOf: name.utf8)
    bytes.append(0x3A)  // colon
    bytes.append(0x20)  // space
    // Add field value
    bytes.append(contentsOf: value.utf8)
    return bytes
}

// Helper function to create a complete SSE message
private func createSSEMessage(fields: [(name: String, value: String)]) -> [UInt8] {
    var bytes: [UInt8] = []
    for field in fields {
        bytes.append(contentsOf: createSSEField(name: field.name, value: field.value))
        bytes.append(0x0A)  // newline
    }
    bytes.append(0x0A)  // final newline to end the message
    return bytes
}
