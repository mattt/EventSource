import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Errors that can occur when using `EventSource`.
public enum EventSourceError: Swift.Error, LocalizedError {
    /// The HTTP response status code is not 200.
    case invalidHTTPStatus(Int)

    /// The Content-Type header is not `text/event-stream`.
    case invalidContentType(String?)

    public var errorDescription: String {
        switch self {
        case .invalidHTTPStatus(let code):
            return "Invalid HTTP response status code: \(code)"
        case .invalidContentType(let contentType):
            if let ct = contentType {
                return "Invalid Content-Type for SSE: \(ct)"
            } else {
                return "Missing Content-Type header in SSE response"
            }
        }
    }
}

#if canImport(FoundationNetworking)
    /// Delegate for handling SSE streaming on Linux
    final class LinuxSSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: EventSource?
        let parser: EventSource.Parser
        private var lastProcessingTask: Task<Void, Never>?

        init(owner: EventSource, parser: EventSource.Parser) {
            self.owner = owner
            self.parser = parser
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                Task { await self.owner?.handleTerminalError(EventSourceError.invalidHTTPStatus(0)) }
                completionHandler(.cancel)
                return
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")
            if http.statusCode != 200 {
                Task {
                    await self.owner?.handleTerminalError(
                        EventSourceError.invalidHTTPStatus(http.statusCode)
                    )
                }
                completionHandler(.cancel)
                return
            }
            if contentType?.lowercased().hasPrefix("text/event-stream") != true {
                Task {
                    await self.owner?.handleTerminalError(
                        EventSourceError.invalidContentType(contentType)
                    )
                }
                completionHandler(.cancel)
                return
            }
            Task { await self.owner?.markOpen() }
            completionHandler(.allow)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            guard let owner = owner else { return }
            let previous = lastProcessingTask
            let next = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                for b in data {
                    if await owner.isClosed { break }
                    await self.parser.consume(b)
                    while let evt = await self.parser.getNextEvent() {
                        await owner.deliver(evt)
                    }
                }
            }
            lastProcessingTask = next
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            let last = lastProcessingTask
            Task { [weak self] in
                guard let self else { return }
                await last?.value
                await parser.finish()
                if let e = error { await owner?.emitError(e) }
                await owner?.resumeLinuxCompletion()
            }
        }
    }
#endif

/// `EventSource` manages a Server-Sent Events (SSE) connection.
///
/// This implementation mirrors the API of JavaScript's EventSource
/// (open upon initialization, auto-reconnect, close behavior).
public actor EventSource {
    /// The ready state of the EventSource.
    public enum ReadyState: Int, Codable, Sendable, CustomStringConvertible {
        /// The connection is being established.
        case connecting = 0

        /// The connection is open and events are being received.
        case open = 1

        /// The connection is closed.
        case closed = 2

        public var description: String {
            switch self {
            case .connecting: return "connecting"
            case .open: return "open"
            case .closed: return "closed"
            }
        }
    }

    /// Represents a single Server-Sent Event, containing its id, event name, data, and optional retry interval.
    public struct Event: Hashable, Identifiable, Codable, Sendable {
        /// The event ID (if provided by the server for this event; used for reconnection).
        public let id: String?

        /// The event type name (if provided via "event:"; `nil` implies the default type `"message"`).
        public let event: String?

        /// The event data payload (concatenation of all `data:` lines, retains internal newlines).
        public let data: String

        /// The reconnection retry interval (in milliseconds) if provided by a "retry:" field in this event.
        public let retry: Int?
    }

    /// `Parser` incrementally parses a stream of bytes into Server-Sent Events.
    public actor Parser {
        // State variables for the current event being parsed
        private var currentEventId: String? = nil
        private var currentEventType: String? = nil
        private var currentData: String = ""
        private var currentRetry: Int? = nil

        // Persistent state
        private var lastEventId: String = ""
        private var reconnectionTime: Int = 3000  // Default 3000ms

        // Line parsing state
        private var lineBuffer: [UInt8] = []
        private var sawCR = false

        // Event queue
        private var eventQueue: [Event] = []

        /// Track whether "data:" field was seen in the current event
        private var seenFields: Set<String> = []

        /// Creates a new parser.
        public init() {}

        private func fieldSeen(_ field: String) -> Bool {
            return seenFields.contains(field)
        }

        /// Process a single byte from the event stream
        public func consume(_ byte: UInt8) {
            if byte == 0x0A {  // LF
                if sawCR {
                    // This is a CR+LF sequence, we already processed the line at CR
                    sawCR = false
                } else {
                    // Stand-alone LF
                    let line = processLineBuffer()
                    handleLine(line)
                }
            } else if byte == 0x0D {  // CR
                let line = processLineBuffer()
                handleLine(line)
                sawCR = true
            } else {
                if sawCR {
                    // The CR wasn't followed by LF
                    sawCR = false
                }
                lineBuffer.append(byte)
            }
        }

        /// Convert the line buffer to a string and clear it
        private func processLineBuffer() -> String {
            // Skip UTF-8 BOM if present at the start of the buffer
            if lineBuffer.count >= 3,
                lineBuffer.prefix(3) == [0xEF, 0xBB, 0xBF]
            {
                lineBuffer.removeFirst(3)
            }

            // Use String(decoding:as:) to handle invalid UTF-8 sequences by replacing them with replacement character
            let line = String(decoding: lineBuffer, as: UTF8.self)
            lineBuffer.removeAll(keepingCapacity: true)
            return line
        }

        /// Handle a line from the event stream
        private func handleLine(_ line: String) {
            // Empty line marks the end of an event
            if line.isEmpty {
                dispatchEvent()
                seenFields.removeAll()
                return
            }

            // Comment line - ignore
            if line.hasPrefix(":") {
                return
            }

            // Parse field name and value
            var fieldName = line
            var fieldValue = ""

            if let colonIndex = line.firstIndex(of: ":") {
                fieldName = String(line[..<colonIndex])
                fieldValue = String(line[line.index(after: colonIndex)...])

                // Remove a single leading space if present
                if fieldValue.hasPrefix(" ") {
                    fieldValue.removeFirst()
                }
            }

            // Process field based on name
            switch fieldName {
            case "event":
                currentEventType = fieldValue
                seenFields.insert("event")
            case "data":
                if !currentData.isEmpty {
                    currentData.append("\n")
                }
                currentData.append(fieldValue)
                seenFields.insert("data")
            case "id":
                if !fieldValue.contains("\0") {
                    currentEventId = fieldValue
                    lastEventId = fieldValue
                }
                seenFields.insert("id")
            case "retry":
                if let milliseconds = Int(fieldValue), milliseconds > 0 {
                    reconnectionTime = milliseconds
                    currentRetry = milliseconds
                }
                seenFields.insert("retry")
            default:
                break
            }
        }

        /// Create an event from the current state and add it to the queue
        private func dispatchEvent() {
            let isDataField = currentData.isEmpty && seenFields.contains("data")
            let isRetryOnly =
                currentData.isEmpty && currentEventId == nil && currentEventType == nil
                && !isDataField

            // Reset the event state for the next event
            defer {
                currentEventType = nil
                currentData = ""
                currentEventId = nil
                currentRetry = nil
            }

            guard !isRetryOnly else {
                return
            }

            // Dispatch events only if they have data or other fields
            let event = Event(
                id: currentEventId,
                event: currentEventType,
                data: currentData,
                retry: currentRetry
            )
            eventQueue.append(event)
        }

        /// Get the next event from the queue
        public func getNextEvent() -> Event? {
            return eventQueue.isEmpty ? nil : eventQueue.removeFirst()
        }

        /// Get the last event ID (for reconnection)
        public func getLastEventId() -> String {
            return lastEventId
        }

        /// Get the reconnection time in milliseconds
        public func getReconnectionTime() -> Int {
            return reconnectionTime
        }

        /// Complete parsing, handling any pending bytes
        public func finish() {
            if sawCR {
                let line = processLineBuffer()
                handleLine(line)
                sawCR = false
            }

            // Process any remaining data in the buffer as a line
            if !lineBuffer.isEmpty {
                let line = processLineBuffer()
                handleLine(line)
            }

            // Send an empty line to trigger event dispatch
            if !currentData.isEmpty || currentEventId != nil || currentEventType != nil {
                handleLine("")
            }
        }
    }

    /// The URL of the event source.
    public var url: URL? { request.url }

    /// The request used for the event source connection.
    public let request: URLRequest

    /// The URL session for the event source connection.
    private let session: URLSession

    /// The task managing the connection loop.
    private var connectionTask: Task<Void, Never>?

    /// The current state of the connection (connecting, open, or closed).
    public private(set) var readyState: ReadyState = .connecting

    /// The maximum number of events to deliver when finalizing parsing.
    ///
    /// This limit prevents unbounded memory growth in edge cases where
    /// a server sends a large burst of events just before closing the connection.
    /// When the limit is reached, remaining events in the parser's queue are discarded.
    ///
    /// The default value of 100 should be sufficient for most use cases.
    /// Increase this value if your application needs to buffer more events
    /// during connection finalization.
    public var maximumFinalizationEventCount: Int = 100

    // Backing storage for callbacks
    private var _onOpenCallback: (@Sendable () async -> Void)?
    private var _onMessageCallback: (@Sendable (Event) async -> Void)?
    private var _onErrorCallback: (@Sendable (Swift.Error?) async -> Void)?

    #if canImport(FoundationNetworking)
        // Linux-specific streaming support
        private var linuxSession: URLSession?
        private var linuxTask: URLSessionDataTask?
        private var linuxCompletion: CheckedContinuation<Void, Never>?
    #endif

    /// The callback to invoke when the connection is opened.
    /// This callback is awaited before proceeding with reconnection or completion.
    nonisolated public var onOpen: (@Sendable () async -> Void)? {
        get { fatalError("onOpen can only be set, not read") }
        set {
            if let newValue {
                Task { await self.setOnOpenCallback(newValue) }
            }
        }
    }

    /// The callback to invoke when a message is received.
    /// This callback is awaited before proceeding with reconnection or completion.
    nonisolated public var onMessage: (@Sendable (Event) async -> Void)? {
        get { fatalError("onMessage can only be set, not read") }
        set {
            if let newValue {
                Task { await self.setOnMessageCallback(newValue) }
            }
        }
    }

    /// The callback to invoke when an error occurs.
    /// This callback is awaited before proceeding with reconnection or completion.
    nonisolated public var onError: (@Sendable (Swift.Error?) async -> Void)? {
        get { fatalError("onError can only be set, not read") }
        set {
            if let newValue {
                Task { await self.setOnErrorCallback(newValue) }
            }
        }
    }

    // Actor-isolated setters
    private func setOnOpenCallback(_ callback: @escaping @Sendable () async -> Void) {
        self._onOpenCallback = callback
    }

    private func setOnMessageCallback(_ callback: @escaping @Sendable (Event) async -> Void) {
        self._onMessageCallback = callback
    }

    private func setOnErrorCallback(_ callback: @escaping @Sendable (Swift.Error?) async -> Void) {
        self._onErrorCallback = callback
    }

    #if canImport(FoundationNetworking)
        // Linux-specific helpers
        fileprivate var isClosed: Bool { readyState == .closed }

        fileprivate func markOpen() async {
            readyState = .open
            await _onOpenCallback?()
        }

        fileprivate func deliver(_ event: Event) async {
            await _onMessageCallback?(event)
        }

        fileprivate func emitError(_ error: Error?) async {
            await _onErrorCallback?(error)
        }

        fileprivate func handleTerminalError(_ error: Error) async {
            await emitError(error)
            readyState = .closed
            linuxTask?.cancel()
            linuxSession?.invalidateAndCancel()
            await resumeLinuxCompletion()
        }

        fileprivate func waitForLinuxCompletion() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                linuxCompletion = cont
            }
        }

        fileprivate func resumeLinuxCompletion() {
            linuxCompletion?.resume()
            linuxCompletion = nil
        }
    #endif

    /// Initializes a new EventSource and begins connecting to the given URL.
    ///
    /// - Parameter url: The URL to open the SSE connection to.
    public init(url: URL) {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        self.init(request: request)
    }

    /// Initializes a new EventSource with a custom URL request and configuration,
    /// and begins connecting.
    ///
    /// - Parameters:
    ///   - request: The URLRequest to use for the SSE connection.
    ///              The request must have "Accept" and "Cache-Control" headers set appropriately,
    ///              and must point to an SSE endpoint.
    ///   - configuration: The URLSessionConfiguration to use for the SSE connection.
    ///                    Defaults to `.default`.
    public init(
        request: URLRequest,
        configuration: URLSessionConfiguration = .default
    ) {
        self.session = URLSession(configuration: configuration)
        self.request = request
        Task { [weak self] in
            await self?.open()
        }
    }

    private func open() {
        self.connectionTask = Task.detached { [weak self] in
            await self?.connect()
        }
    }

    /// Closes the SSE connection and prevents any further reconnection attempts.
    public func close() {
        // Set state to closed and cancel the background connection task.
        readyState = .closed
        connectionTask?.cancel()
        connectionTask = nil
        #if canImport(FoundationNetworking)
            linuxTask?.cancel()
            linuxSession?.invalidateAndCancel()
        #endif
    }

    /// Continuously handles connecting and reconnecting to the SSE stream.
    private func connect() async {
        let parser = Parser()
        var isFirstAttempt = true

        repeat {
            // If the EventSource was closed, exit loop.
            if Task.isCancelled || readyState == .closed {
                break
            }

            do {
                // If not the first attempt,
                // wait for the reconnection delay before retrying.
                if !isFirstAttempt {
                    let delay = await parser.getReconnectionTime()  // in milliseconds
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                }

                isFirstAttempt = false

                // Update state to `.connecting`
                readyState = .connecting

                // Prepare the request, including Last-Event-ID header if we have one.
                var currentRequest = self.request
                let lastEventId = await parser.getLastEventId()
                if !lastEventId.isEmpty {
                    currentRequest.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
                }

                // Perform the HTTP request with streaming support
                #if canImport(FoundationNetworking)
                    // Linux: Use URLSessionDataTask with delegate for streaming
                    let delegate = LinuxSSEDelegate(owner: self, parser: parser)
                    let delegateQueue = OperationQueue()
                    delegateQueue.maxConcurrentOperationCount = 1
                    let linuxSession = URLSession(
                        configuration: session.configuration,
                        delegate: delegate,
                        delegateQueue: delegateQueue
                    )
                    self.linuxSession = linuxSession
                    let task = linuxSession.dataTask(with: currentRequest)
                    self.linuxTask = task
                    task.resume()

                    // Wait until the stream completes (server closed or error)
                    await waitForLinuxCompletion()
                #else
                    // Apple platforms: Use URLSession.bytes for true streaming
                    let (byteStream, response) = try await session.bytes(
                        for: currentRequest,
                        delegate: nil
                    )

                    // Validate HTTP response (status code and content type).
                    if let httpResponse = response as? HTTPURLResponse {
                        let status = httpResponse.statusCode
                        if status != 200 {
                            throw EventSourceError.invalidHTTPStatus(status)
                        }
                        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
                        if contentType?.lowercased().hasPrefix("text/event-stream") != true {
                            throw EventSourceError.invalidContentType(contentType)
                        }
                    } else {
                        throw EventSourceError.invalidHTTPStatus(0)
                    }

                    // Connection is established and content type is correct.
                    readyState = .open
                    if let onOpen = _onOpenCallback {
                        await onOpen()
                    }

                    // Read the incoming byte stream and parse events.
                    for try await byte in byteStream {
                        if Task.isCancelled || readyState == .closed {
                            break
                        }

                        await parser.consume(byte)

                        while let event = await parser.getNextEvent() {
                            if let onMessage = _onMessageCallback {
                                await onMessage(event)
                            }
                        }
                    }
                #endif

                // End of stream reached (server closed connection).
                await parser.finish()  // finalize parsing, delivers any pending events to queue

                // Deliver any events that were queued during finish()
                var eventsDelivered = 0
                let maxEvents = maximumFinalizationEventCount
                while let event = await parser.getNextEvent(), eventsDelivered < maxEvents {
                    eventsDelivered += 1
                    await _onMessageCallback?(event)
                }

                // If not cancelled and still open, treat as a disconnection to reconnect.
                if !Task.isCancelled && readyState != .closed {
                    // Notify an error event due to unexpected close, then loop to reconnect.
                    await _onErrorCallback?(nil)  // stream closed without error (will attempt reconnect)
                } else {
                    // If cancelled or closed intentionally, break without reconnecting.
                    break
                }
            } catch {
                // Handle all errors (connection-level, stream reading, or cancellation)
                if (error as? CancellationError) != nil || readyState == .closed {
                    // If cancelled or closed during connect, break.
                    break
                }

                // Notify error event.
                await _onErrorCallback?(error)

                // For HTTP status/content-type errors, break out (do not reconnect as per spec).
                if error is EventSourceError {
                    readyState = .closed
                    break
                }

                // Otherwise (e.g., network error establishing connection), try to reconnect.
                // Loop will continue after delay.
            }
        } while true

        // Update state to `.closed`.
        readyState = .closed
    }
}

/// A type alias for `EventSource.Event`.
public typealias SSE = EventSource.Event
