/// An `AsyncSequence` that transforms a sequence of bytes
/// into a sequence of `EventSource.Event` / `SSE` values.
public struct AsyncServerSentEventsSequence<Base: AsyncSequence>: AsyncSequence
where Base.Element == UInt8 {
    /// The type of elements in the sequence.
    public typealias Element = EventSource.Event

    /// The type of the iterator for the sequence.
    public typealias AsyncIterator = Iterator

    let base: Base

    /// Creates a new `AsyncServerSentEventsSequence` from a base sequence of bytes.
    public init(base: Base) {
        self.base = base
    }

    /// Creates an iterator for the sequence.
    public func makeAsyncIterator() -> Iterator {
        return Iterator(base: base.makeAsyncIterator())
    }

    /// An iterator for the sequence.
    public struct Iterator: AsyncIteratorProtocol {
        var baseIterator: Base.AsyncIterator
        let parser = EventSource.Parser()

        init(base: Base.AsyncIterator) {
            self.baseIterator = base
        }

        public mutating func next() async throws -> EventSource.Event? {
            // Check if parser already has a complete event queued.
            if let event = await parser.getNextEvent() {
                return event
            }

            // Process bytes until we get an event or run out of input
            while let byte = try await baseIterator.next() {
                await parser.consume(byte)
                if let event = await parser.getNextEvent() {
                    return event
                }
            }

            // Base sequence ended; finalize parsing and return any last event if available.
            await parser.finish()
            return await parser.getNextEvent()
        }
    }
}
