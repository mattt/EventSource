#if canImport(AsyncHTTPClient)
    import Foundation
    import Testing

    @testable import EventSource

    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    @Suite("AsyncHTTPClient Trait Tests")
    struct AsyncHTTPClientTraitTests {
        @Test("AsyncHTTPClient backend conforms to streaming backend protocol")
        func backendProtocolConformance() {
            func acceptsBackend(_: some EventSourceByteStreamingBackend) {}
            acceptsBackend(AsyncHTTPClientBackend())
        }

        @Test("Falls back for retryable URL errors")
        func fallbackForRetryableURLError() {
            let shouldFallback = EventSourceFallbackPolicy.shouldFallback(
                useAsyncHTTPClientOnLinux: false,
                error: URLError(.cannotConnectToHost)
            )
            #expect(shouldFallback)
        }

        @Test("Does not fall back for non-retryable URL errors")
        func noFallbackForNonRetryableURLError() {
            let shouldFallback = EventSourceFallbackPolicy.shouldFallback(
                useAsyncHTTPClientOnLinux: false,
                error: URLError(.unsupportedURL)
            )
            #expect(!shouldFallback)
        }

        @Test("Does not fall back for EventSource errors")
        func noFallbackForEventSourceError() {
            let shouldFallback = EventSourceFallbackPolicy.shouldFallback(
                useAsyncHTTPClientOnLinux: false,
                error: EventSourceError.invalidHTTPStatus(500)
            )
            #expect(!shouldFallback)
        }

        @Test("Does not fall back when AsyncHTTPClient is already active")
        func noFallbackWhenAlreadyUsingAsyncHTTPClient() {
            let shouldFallback = EventSourceFallbackPolicy.shouldFallback(
                useAsyncHTTPClientOnLinux: true,
                error: URLError(.cannotConnectToHost)
            )
            #expect(!shouldFallback)
        }
    }
#endif
