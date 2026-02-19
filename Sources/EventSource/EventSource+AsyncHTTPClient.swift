#if canImport(AsyncHTTPClient)
    import AsyncHTTPClient
    import Foundation
    import NIOHTTP1

    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    enum EventSourceAsyncHTTPClientError: Error {
        case invalidRequestURL
        case invalidResponse
    }

    protocol EventSourceByteStreamingBackend: Sendable {
        func execute(_ request: URLRequest) async throws -> (
            response: HTTPURLResponse, bytes: AsyncThrowingStream<UInt8, Error>
        )
    }

    struct AsyncHTTPClientBackend: EventSourceByteStreamingBackend {
        func execute(_ request: URLRequest) async throws -> (
            response: HTTPURLResponse, bytes: AsyncThrowingStream<UInt8, Error>
        ) {
            guard let url = request.url else {
                throw EventSourceAsyncHTTPClientError.invalidRequestURL
            }

            let client = HTTPClient()
            var clientRequest = HTTPClientRequest(url: url.absoluteString)

            if let method = request.httpMethod {
                clientRequest.method = HTTPMethod(rawValue: method)
            }

            for (name, value) in request.allHTTPHeaderFields ?? [:] {
                clientRequest.headers.add(name: name, value: value)
            }

            if let body = request.httpBody {
                clientRequest.body = .bytes(body)
            }

            let response = try await client.execute(clientRequest, timeout: .seconds(300))
            let responseHeaders = Dictionary(
                uniqueKeysWithValues: response.headers.map { ($0.name, $0.value) }
            )
            guard
                let httpResponse = HTTPURLResponse(
                    url: url,
                    statusCode: Int(response.status.code),
                    httpVersion: nil,
                    headerFields: responseHeaders
                )
            else {
                throw EventSourceAsyncHTTPClientError.invalidResponse
            }

            let bytes = AsyncThrowingStream<UInt8, Error> { continuation in
                let task = Task {
                    do {
                        for try await chunk in response.body {
                            for byte in chunk.readableBytesView {
                                continuation.yield(byte)
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    try? await client.shutdown()
                }
                continuation.onTermination = { _ in task.cancel() }
            }

            return (httpResponse, bytes)
        }
    }

    enum EventSourceFallbackPolicy {
        static func shouldFallback(
            useAsyncHTTPClientOnLinux: Bool,
            error: Error
        ) -> Bool {
            guard !useAsyncHTTPClientOnLinux else { return false }
            guard error is EventSourceError == false else { return false }
            if let urlError = error as? URLError {
                let nonRetryableCodes: Set<URLError.Code> = [
                    .badURL, .unsupportedURL, .userAuthenticationRequired,
                ]
                return !nonRetryableCodes.contains(urlError.code)
            }
            return true
        }
    }

#endif
