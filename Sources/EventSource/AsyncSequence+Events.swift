extension AsyncSequence where Element == UInt8 {
    /// Returns an asynchronous sequence of `EventSource.Event` / `SSE` values
    /// parsed from a stream of bytes (interpreted as SSE data).
    public var events: AsyncServerSentEventsSequence<Self> {
        return AsyncServerSentEventsSequence(base: self)
    }
}
