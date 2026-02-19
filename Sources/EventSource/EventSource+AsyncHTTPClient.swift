#if canImport(AsyncHTTPClient)
    import AsyncHTTPClient
    import Foundation
    import NIOCore
    import NIOHTTP1

    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    enum EventSourceAsyncHTTPClientError: Error {
        case invalidRequestURL
        case invalidResponse
    }

    protocol EventSourceByteStreamingBackend: Sendable {
        func execute(_ request: URLRequest, timeout: TimeAmount) async throws -> (
            response: HTTPURLResponse, bytes: AsyncThrowingStream<UInt8, Error>
        )
    }

    actor ShutdownCoordinator {
        private var hasShutdown = false

        func shutdown(client: HTTPClient) async {
            guard !hasShutdown else { return }
            hasShutdown = true
            try? await client.shutdown()
        }
    }

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
                var responseHeaders: [String: String] = [:]
                // HTTPURLResponse requires a [String: String] map, so duplicate header fields
                // (for example, multiple Set-Cookie values) cannot be preserved independently.
                for header in response.headers {
                    if let existing = responseHeaders[header.name] {
                        responseHeaders[header.name] = existing + ", " + header.value
                    } else {
                        responseHeaders[header.name] = header.value
                    }
                }

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
            return false
        }
    }

#endif
