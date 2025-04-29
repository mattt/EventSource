// Helper for testing chunked delivery - simulates data arriving in chunks
struct ChunkedAsyncBytes: AsyncSequence {
    typealias Element = UInt8

    let chunks: [[UInt8]]

    init(_ chunks: [[UInt8]]) {
        self.chunks = chunks
    }

    func makeAsyncIterator() -> ChunkedAsyncBytesIterator {
        return ChunkedAsyncBytesIterator(chunks: chunks)
    }

    struct ChunkedAsyncBytesIterator: AsyncIteratorProtocol {
        let chunks: [[UInt8]]
        var chunkIndex = 0
        var byteIndex = 0

        mutating func next() async throws -> UInt8? {
            while chunkIndex < chunks.count {
                let currentChunk = chunks[chunkIndex]

                if byteIndex < currentChunk.count {
                    let byte = currentChunk[byteIndex]
                    byteIndex += 1
                    return byte
                } else {
                    // Move to next chunk
                    chunkIndex += 1
                    byteIndex = 0
                }
            }

            return nil
        }
    }
}
