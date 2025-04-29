import Foundation
import Testing

@testable import EventSource

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Request Handler Storage

/// Stores and manages handlers for MockURLProtocol's request handling.
actor RequestHandlerStorage {
    private var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    func setHandler(
        _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) async {
        requestHandler = handler
    }

    func clearHandler() async {
        requestHandler = nil
    }

    func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        guard let handler = requestHandler else {
            throw NSError(
                domain: "MockURLProtocolError",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No request handler set"]
            )
        }
        return try await handler(request)
    }
}

// MARK: - Mock URL Protocol

/// Custom URLProtocol for testing network requests
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Storage for request handlers
    static let requestHandlerStorage = RequestHandlerStorage()

    /// Set a handler to process mock requests
    static func setHandler(
        _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) async {
        await requestHandlerStorage.setHandler(handler)
    }

    /// Execute the stored handler for a request
    func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        return try await Self.requestHandlerStorage.executeHandler(for: request)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Task {
            do {
                let (response, data) = try await self.executeHandler(for: request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        // No-op
    }
}

#if swift(>=6.1)
    // MARK: - Mock URL Session Test Trait

    /// A test trait to set up and clean up mock URL protocol handlers
    struct MockURLSessionTestTrait: TestTrait, TestScoping {
        func provideScope(
            for test: Test, testCase: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            // Clear handler before test
            await MockURLProtocol.requestHandlerStorage.clearHandler()

            // Execute the test
            try await function()

            // Clear handler after test
            await MockURLProtocol.requestHandlerStorage.clearHandler()
        }
    }

    extension Trait where Self == MockURLSessionTestTrait {
        static var mockURLSession: Self { Self() }
    }

#endif  // swift(>=6.1)
