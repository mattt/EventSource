// Helper to create an AsyncSequence from a sequence of bytes
struct AsyncBytes: AsyncSequence {
    typealias Element = UInt8

    let bytes: [UInt8]

    init(_ bytes: some Sequence<UInt8>) {
        self.bytes = Array(bytes)
    }

    func makeAsyncIterator() -> AsyncBytesIterator {
        return AsyncBytesIterator(bytes: bytes)
    }

    struct AsyncBytesIterator: AsyncIteratorProtocol {
        let bytes: [UInt8]
        var index = 0

        mutating func next() async throws -> UInt8? {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            return byte
        }
    }
}
