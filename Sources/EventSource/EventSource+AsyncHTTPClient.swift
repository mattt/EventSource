#if canImport(AsyncHTTPClient)
    import AsyncHTTPClient
    import Foundation
    import NIOCore
    import NIOHTTP1

    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    /// Errors thrown by the AsyncHTTPClient transport adapter.
    enum EventSourceAsyncHTTPClientError: Error {
        /// The request does not contain a valid URL.
        case invalidRequestURL
        /// The AsyncHTTPClient response cannot be converted to ``HTTPURLResponse``.
        case invalidResponse
    }

    /// Executes EventSource requests and returns a byte stream with response metadata.
    protocol EventSourceByteStreamingBackend: Sendable {
        /// Executes the given request with the provided timeout.
        ///
        /// - Parameters:
        ///   - request: The request to execute.
        ///   - timeout: The request timeout.
        /// - Returns: A converted HTTP response and a streaming byte sequence.
        /// - Throws: An error if the request fails or response conversion is invalid.
        func execute(_ request: URLRequest, timeout: TimeAmount) async throws -> (
            response: HTTPURLResponse, bytes: AsyncThrowingStream<UInt8, Error>
        )
    }

    /// Coordinates one-time shutdown for a shared ``HTTPClient`` instance.
    actor ShutdownCoordinator {
        private var hasShutdown = false

        /// Shuts down the client once, and ignores subsequent calls.
        func shutdown(client: HTTPClient) async {
            guard !hasShutdown else { return }
            hasShutdown = true
            try? await client.shutdown()
        }
    }

    /// AsyncHTTPClient-backed implementation of ``EventSourceByteStreamingBackend``.
    struct AsyncHTTPClientBackend: EventSourceByteStreamingBackend {
        func execute(_ request: URLRequest, timeout: TimeAmount) async throws -> (
            response: HTTPURLResponse, bytes: AsyncThrowingStream<UInt8, Error>
        ) {
            guard let url = request.url else {
                throw EventSourceAsyncHTTPClientError.invalidRequestURL
            }

            let client = HTTPClient()
            let shutdownCoordinator = ShutdownCoordinator()
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

            do {
                let response = try await client.execute(clientRequest, timeout: timeout)

                // HTTPURLResponse requires a [String: String] map, so duplicate header fields
                // (for example, multiple Set-Cookie values) cannot be preserved independently.
                var responseHeaders: [String: String] = [:]
                for header in response.headers {
                    if let existing = responseHeaders[header.name] {
                        responseHeaders[header.name] = existing + ", " + header.value
                    } else {
                        responseHeaders[header.name] = header.value
                    }
                }

                // Convert the response to an HTTPURLResponse.
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

                // Convert the response body to a stream of bytes.
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
                        await shutdownCoordinator.shutdown(client: client)
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                        Task {
                            await shutdownCoordinator.shutdown(client: client)
                        }
                    }
                }

                return (httpResponse, bytes)
            } catch {
                await shutdownCoordinator.shutdown(client: client)
                throw error
            }
        }
    }

    /// Decides when Linux URLSession failures should fall back to AsyncHTTPClient.
    enum EventSourceFallbackPolicy {
        /// Returns whether fallback should occur for the given error.
        ///
        /// - Parameters:
        ///   - useAsyncHTTPClientOnLinux: Whether this instance already uses AsyncHTTPClient.
        ///   - error: The failure from the current connection attempt.
        /// - Returns: `true` when fallback should switch transports, otherwise `false`.
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
            return false
        }
    }

#endif
