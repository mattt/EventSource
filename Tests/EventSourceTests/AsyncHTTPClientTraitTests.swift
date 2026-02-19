#if canImport(AsyncHTTPClient)
    import AsyncHTTPClient
    import Foundation
    import NIOCore
    import NIOHTTP1
    #if canImport(NIOPosix)
        import NIOPosix
    #endif
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

        @Test("AsyncHTTPClient backend surfaces execution errors")
        func executionError() async {
            let backend = AsyncHTTPClientBackend()
            let request = URLRequest(url: URL(string: "ftp://127.0.0.1/unavailable")!)
            do {
                _ = try await backend.execute(request, timeout: .seconds(1))
                Issue.record("Expected backend.execute to throw for unreachable host")
            } catch {
                // expected
            }
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

        @Test("Does not fall back for non-URL errors")
        func noFallbackForNonURLError() {
            struct SomeError: Error {}
            let shouldFallback = EventSourceFallbackPolicy.shouldFallback(
                useAsyncHTTPClientOnLinux: false,
                error: SomeError()
            )
            #expect(!shouldFallback)
        }

        #if canImport(NIOPosix)
            @Test("AsyncHTTPClient backend executes request and streams bytes")
            func backendExecutionAndStreaming() async throws {
                let server = try await LocalSSEHTTPServer(
                    responseBody: "data: hello\n\ndata: world\n\n",
                    headers: [
                        ("Content-Type", "text/event-stream"),
                        ("Set-Cookie", "a=1"),
                        ("Set-Cookie", "b=2"),
                    ]
                )
                defer {
                    Task {
                        try? await server.shutdown()
                    }
                }

                var request = URLRequest(url: server.url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let backend = AsyncHTTPClientBackend()
                let (response, bytes) = try await backend.execute(request, timeout: .seconds(5))

                #expect(response.statusCode == 200)
                #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
                #expect(response.value(forHTTPHeaderField: "Set-Cookie")?.contains("a=1") == true)
                #expect(response.value(forHTTPHeaderField: "Set-Cookie")?.contains("b=2") == true)

                var collected: [UInt8] = []
                for try await byte in bytes {
                    collected.append(byte)
                }
                let payload = String(decoding: collected, as: UTF8.self)
                #expect(payload == "data: hello\n\ndata: world\n\n")
            }
        #endif
    }

    #if canImport(NIOPosix)
        private final class StaticResponseHandler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            private let responseBody: String
            private let headers: [(String, String)]

            init(responseBody: String, headers: [(String, String)]) {
                self.responseBody = responseBody
                self.headers = headers
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let part = unwrapInboundIn(data)
                switch part {
                case .end:
                    var httpHeaders = HTTPHeaders()
                    for (name, value) in headers {
                        httpHeaders.add(name: name, value: value)
                    }
                    let head = HTTPResponseHead(
                        version: .http1_1,
                        status: .ok,
                        headers: httpHeaders
                    )
                    context.write(wrapOutboundOut(.head(head)), promise: nil)
                    var buffer = context.channel.allocator.buffer(capacity: responseBody.utf8.count)
                    buffer.writeString(responseBody)
                    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                default:
                    break
                }
            }
        }

        private struct LocalSSEHTTPServer {
            let url: URL

            private let group: MultiThreadedEventLoopGroup
            private let channel: Channel

            init(responseBody: String, headers: [(String, String)]) async throws {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                let bootstrap = ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.backlog, value: 256)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        channel.pipeline.configureHTTPServerPipeline().flatMap {
                            channel.pipeline.addHandler(
                                StaticResponseHandler(
                                    responseBody: responseBody,
                                    headers: headers
                                )
                            )
                        }
                    }
                    .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

                let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
                guard let port = channel.localAddress?.port else {
                    try? await channel.close().get()
                    try? await group.shutdownGracefully()
                    throw URLError(.cannotFindHost)
                }

                self.group = group
                self.channel = channel
                self.url = URL(string: "http://127.0.0.1:\(port)/events")!
            }

            func shutdown() async throws {
                try await channel.close().get()
                try await group.shutdownGracefully()
            }
        }
    #endif
#endif
