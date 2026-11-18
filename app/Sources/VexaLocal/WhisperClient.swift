import Foundation
import VexaCore

/// Talks to the project's own Whisper server (whisper-server/server.py). No Vexa involved.
struct WhisperClient: Sendable {
    struct Health: Decodable, Sendable { var status: String; var model: String? }

    struct Failure: LocalizedError, Sendable {
        var status: Int        // 0 = no HTTP reply
        var message: String
        var retryAfter: TimeInterval?
        var errorDescription: String? { status == 0 ? message : "Whisper replied \(status): \(message)" }
        /// Worth one more try (busy, still loading, network blip). A bad token is not.
        var isRetryable: Bool { status == 0 || status == 408 || status == 429 || status >= 500 }
    }

    var endpoint: WhisperEndpoint
    var session: URLSession = .shared
    var timeout: TimeInterval = 180

    /// The server's health, or nil when it can't be reached.
    func health() async -> Health? {
        var req = URLRequest(url: endpoint.healthURL, timeoutInterval: 3)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Health.self, from: data)
    }

    /// Sends one WAV file; `language` nil lets Whisper detect it.
    func transcribe(wav: Data, language: String?) async throws -> WhisperVerboseResponse {
        var form = MultipartForm()
        form.addFile("file", filename: "chunk.wav", mimeType: "audio/wav", data: wav)
        form.addField("model", "whisper-1")
        form.addField("response_format", "verbose_json")
        form.addField("temperature", "0")
        if let language, !language.isEmpty { form.addField("language", language) }

        var req = URLRequest(url: endpoint.transcriptionsURL, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        if !endpoint.token.isEmpty { req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = form.finished

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure(status: 0, message: "Could not reach Whisper at \(endpoint.baseURL.absoluteString): \(error.localizedDescription)")
        }
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Detail: Decodable { var detail: String? }
            let detail = (try? JSONDecoder().decode(Detail.self, from: data))?.detail
                ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw Failure(status: status, message: detail.isEmpty ? "no details" : detail, retryAfter: retry)
        }
        do {
            return try JSONDecoder().decode(WhisperVerboseResponse.self, from: data)
        } catch {
            throw Failure(status: status, message: "Unexpected reply from Whisper: \(error.localizedDescription)")
        }
    }
}

/// One chunk of speech waiting to be transcribed.
struct TranscriptionJob: Sendable {
    var lane: RecordingLane
    var speaker: String
    var start: Date
    var duration: TimeInterval
    var wav: Data
}

enum TranscriptionOutcome: Sendable {
    case done(TranscriptionJob, [TranscriptLine])
    case failed(TranscriptionJob, String)
}

/// Sends a recording's chunks to Whisper one at a time, in the order they were made.
/// `enqueue` never blocks (capture keeps going); a failed chunk is retried once.
final class TranscriptionQueue: Sendable {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
        func add(_ n: Int) { lock.withLock { value += n } }
        var current: Int { lock.withLock { value } }
    }

    private let continuation: AsyncStream<TranscriptionJob>.Continuation
    private let worker: Task<Void, Never>
    private let counter = Counter()

    /// Chunks enqueued and not yet finished.
    var pending: Int { counter.current }

    init(client: WhisperClient, language: String?, retryDelay: TimeInterval = 1,
         onResult: @escaping @Sendable (TranscriptionOutcome) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionJob.self)
        self.continuation = continuation
        let counter = counter
        worker = Task.detached {
            for await job in stream {
                // After cancel(), whatever is still queued is reported as failed so its audio can be saved.
                let outcome = Task.isCancelled ? .failed(job, Self.notSent)
                    : await Self.run(job, client: client, language: language, retryDelay: retryDelay)
                await onResult(outcome)
                counter.add(-1)
            }
        }
    }

    func enqueue(_ job: TranscriptionJob) {
        counter.add(1)
        if case .terminated = continuation.yield(job) { counter.add(-1) }
    }

    /// Stops taking chunks and waits until the ones already queued are done.
    func finish() async {
        continuation.finish()
        await worker.value
    }

    /// Stops sending: the request in flight is cancelled and everything still queued is
    /// reported as failed (used when quitting without waiting).
    func cancel() {
        worker.cancel()
        continuation.finish()
    }

    static let notSent = "stopped before Whisper got to it"

    private static func run(_ job: TranscriptionJob, client: WhisperClient, language: String?,
                            retryDelay: TimeInterval) async -> TranscriptionOutcome {
        var lastError = ""
        for attempt in 0..<2 {
            do {
                let reply = try await client.transcribe(wav: job.wav, language: language)
                let lines = LocalTranscript.lines(from: reply, chunkStart: job.start, chunkDuration: job.duration,
                                                  lane: job.lane, speaker: job.speaker)
                return .done(job, lines)
            } catch is CancellationError {
                return .failed(job, notSent)
            } catch let f as WhisperClient.Failure {
                lastError = f.localizedDescription
                guard f.isRetryable, attempt == 0 else { break }
                let wait = min(max(f.retryAfter ?? retryDelay, 0), 10)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                lastError = error.localizedDescription
                break
            }
        }
        return .failed(job, lastError)
    }
}
