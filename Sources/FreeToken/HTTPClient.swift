//
//  HTTPClient.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/16/24.
//

import Foundation
import LDSwiftEventSource

extension FreeToken {
    class HTTPClient: @unchecked Sendable {
        private let session: URLSession
        private let decoder: JSONDecoder
        private let etagCache = ETagCache()
        
        init() {
            let configuration = URLSessionConfiguration.default
            self.session = URLSession(configuration: configuration)
            self.decoder = JSONDecoder()

            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: dateString) {
                    return date
                } else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
                }
            }
        }
        
        // Send HTTP Requests
        internal func sendRequest<T: Decodable>(
            to url: URL,
            method: String = "GET",
            headers: [String: String] = [:],
            body: Data? = nil,
            responseType: T.Type,
            useETagCaching: Bool = false,
            completion: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
        ) {
            var requestHeaders = headers

            // Add If-None-Match header if we have a cached ETag and caching is enabled
            if useETagCaching && method == "GET", let cachedETag = etagCache.getETag(for: url) {
                requestHeaders["If-None-Match"] = cachedETag
            }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.allHTTPHeaderFields = requestHeaders
            request.httpBody = body
            let semaphore = DispatchSemaphore(value: 0)

            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    // Handle client-side error
                    FreeToken.shared.logger("🔴🌎 HTTP request failed: \(error.localizedDescription)", .error)
                    let semaphore = DispatchSemaphore(value: 0)
                    Task {
                        await completion(.failure(FreeTokenError.requestFailed))
                        semaphore.signal()
                    }
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    FreeToken.shared.logger("🔴📞 No response from server", .error)
                    Task {
                        await completion(.failure(FreeTokenError.noResponse))
                        semaphore.signal()
                    }
                    return
                }

                // Handle 304 Not Modified for ETag caching
                if httpResponse.statusCode == 304 && useETagCaching {
                    if let cachedData = self.etagCache.getCachedData(for: url) {
                        do {
                            let decodedResponse = try self.decoder.decode(T.self, from: cachedData)
                            Task {
                                await completion(.success(decodedResponse))
                                semaphore.signal()
                            }
                        } catch {
                            FreeToken.shared.logger("🔴📃 Error decoding cached data: \(error.localizedDescription)", .error)
                            self.etagCache.flushCacheData(for: url)
                            FreeToken.shared.logger("🚽 Flushed cache on non-decoding URL: \(url)", .error)
                            Task {
                                await completion(.failure(FreeTokenError.decodingError(message: error.localizedDescription)))
                                semaphore.signal()
                            }
                        }
                    } else {
                        Task {
                            await completion(.failure(FreeTokenError.noCachedDataAvailable))
                            semaphore.signal()
                        }
                    }
                    
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    // Handle server-side error
                    if let data = data {
                        do {
                            let errorMessage = try self.decoder.decode(
                                Codings.RawErrorResponse.self, from: data)
                            let apiError = FreeTokenError.httpFailureResponse(message: errorMessage.message, code: httpResponse.statusCode)
                            
                            Task {
                                await completion(.failure(apiError))
                                semaphore.signal()
                            }
                        } catch {
                            Task {
                                await completion(.failure(FreeTokenError.unableToParseServerError(code: httpResponse.statusCode)))
                                semaphore.signal()
                            }
                        }
                    } else {
                        let noDataError = FreeTokenError.noDataError(code: httpResponse.statusCode)
                        Task {
                            await completion(.failure(noDataError))
                            semaphore.signal()
                        }
                    }
                    return
                }

                guard let data = data else {
                    let noDataError = FreeTokenError.noDataError(code: httpResponse.statusCode)
                    Task {
                        await completion(.failure(noDataError))
                        semaphore.signal()
                    }
                    return
                }

                // Cache the ETag and data if present and caching is enabled
                if useETagCaching && method == "GET",
                    let etag = httpResponse.allHeaderFields["ETag"] as? String
                {
                    self.etagCache.store(etag: etag, data: data, for: url)
                }

                do {
                    let decodedResponse = try self.decoder.decode(T.self, from: data)
                    Task {
                        await completion(.success(decodedResponse))
                        semaphore.signal()
                    }
                } catch let DecodingError.keyNotFound(key, context) {
                    let decodingError = FreeTokenError.decodingError(
                        message: "Missing key: \(key.stringValue), Context: \(context)"
                    )
                    Task {
                        await completion(.failure(decodingError))
                        semaphore.signal()
                    }
                } catch let DecodingError.typeMismatch(type, context) {
                    let decodingError = FreeTokenError.decodingError(
                        message: "Type mismatch for \(type): \(context)"
                    )
                    Task {
                        await completion(.failure(decodingError))
                        semaphore.signal()
                    }
                } catch let DecodingError.valueNotFound(type, context) {
                    let decodingError = FreeTokenError.decodingError(
                        message: "Missing value for \(type): \(context)"
                    )
                    Task {
                        await completion(.failure(decodingError))
                        semaphore.signal()
                    }
                } catch let DecodingError.dataCorrupted(context) {
                    let decodingError = FreeTokenError.decodingError(
                        message: "Corrupt data: \(context)"
                    )
                    Task {
                        await completion(.failure(decodingError))
                        semaphore.signal()
                    }
                } catch {
                    let decodingError = FreeTokenError.decodingError(
                        message: "Unknown decoding error: \(error.localizedDescription)"
                    )
                    Task {
                        await completion(.failure(decodingError))
                        semaphore.signal()
                    }
                }
            }

            task.resume()
            semaphore.wait()
        }
        
        
        // Convenience methods for GET and POST
        internal func get<T: Decodable>(
            from url: URL,
            headers: [String: String] = [:],
            responseType: T.Type,
            useETagCaching: Bool = false,
            completion: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
        ) async {
            sendRequest(
                to: url, method: "GET", headers: headers, responseType: responseType,
                useETagCaching: useETagCaching, completion: completion)
        }
        
        internal func post<T: Decodable>(
            to url: URL,
            headers: [String: String] = [:],
            body: Data,
            responseType: T.Type,
            completion: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
        ) async {
            sendRequest(to: url, method: "POST", headers: headers, body: body, responseType: responseType, completion: completion)
        }
        
        internal func postMultipart<T: Decodable>(
            to url: URL,
            headers: [String: String] = [:],
            jsonData: [String: Any],
            attachments: [MessageAttachment],
            responseType: T.Type,
            completion: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
        ) async {
            // Debug logging for multipart upload
            FreeToken.shared.logger("🔍 HTTP DEBUG: Posting multipart data with \(attachments.count) attachments", .info)
            for (index, attachment) in attachments.enumerated() {
                FreeToken.shared.logger("🔍 HTTP DEBUG: Attachment \(index): \(attachment.data.count) bytes, type: \(attachment.contentType)", .info)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            
            // Set up headers
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            
            // Create multipart form data
            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            
            var body = Data()
            
            // Add JSON fields to multipart body
            for (key, value) in jsonData {
                body.appendMultipartField(boundary: boundary, name: key, value: value)
            }
            
            // Add image attachments
            for (index, attachment) in attachments.enumerated() where attachment.type == .image {
                let filename = attachment.filename ?? "image_\(index).png"
                FreeToken.shared.logger("🔍 MULTIPART DEBUG: Adding image \(index) to multipart body: name=images[], filename=\(filename), size=\(attachment.data.count) bytes, mimeType=\(attachment.contentType)", .info)
                body.appendMultipartFile(
                    boundary: boundary,
                    name: "images[]",
                    filename: filename,
                    data: attachment.data,
                    mimeType: attachment.contentType
                )
            }
            
            FreeToken.shared.logger("🔍 MULTIPART DEBUG: Final multipart body size: \(body.count) bytes", .info)
            
            body.appendMultipartEnd(boundary: boundary)
            request.httpBody = body
            
            // Use URLSession to send the request
            do {
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    let serverError = FreeTokenError.httpError(
                        message: "HTTP error \((response as? HTTPURLResponse)?.statusCode ?? 0)",
                        code: (response as? HTTPURLResponse)?.statusCode
                    )
                    await completion(.failure(serverError))
                    return
                }
                
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    if let date = formatter.date(from: dateString) {
                        return date
                    } else {
                        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
                    }
                }
                
                let decodedResponse = try decoder.decode(responseType, from: data)
                await completion(.success(decodedResponse))
                
            } catch {
                let clientError = FreeTokenError.clientError(message: error.localizedDescription)
                await completion(.failure(clientError))
            }
        }
        
        internal func delete(
            from url: URL,
            headers: [String: String] = [:],
            completion: @escaping @Sendable (Result<Void, FreeTokenError>) -> Void
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.allHTTPHeaderFields = headers
            let semaphore = DispatchSemaphore(value: 0)
            
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    // Handle client-side error
                    let clientError = FreeTokenError.clientError(
                        message: error.localizedDescription
                    )
                    completion(.failure(clientError))
                    semaphore.signal()
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    // Handle server-side error
                    let serverError = FreeTokenError.httpError(
                        message: "Received HTTP status code \(String(describing: (response as? HTTPURLResponse)?.statusCode))",
                        code: (response as? HTTPURLResponse)?.statusCode
                    )
                    completion(.failure(serverError))
                    semaphore.signal()
                    return
                }
                
                completion(.success(()))
                semaphore.signal()
            }
            
            task.resume()
            semaphore.wait()
        }
        
        internal func streamPost<T: Decodable & Sendable>(
            to url: URL,
            headers: [String: String] = [:],
            body: Data,
            streamCallback: @escaping @Sendable (String) async -> Void,
            completion: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
        ) {
            let semaphore = DispatchSemaphore(value: 0)
            let sseClient = SSEClient<T>(
                url: url,
                headers: headers,
                body: body,
                onMessageChunk: streamCallback,
                onComplete: { @Sendable result in
                    Task { @Sendable in
                        await completion(result)
                        semaphore.signal()
                    }
                }
            )
            
            sseClient.start()
            semaphore.wait()
        }
    }
}

// MARK: - Data Extension for Multipart Form Data
extension Data {
    mutating func appendMultipartField(boundary: String, name: String, value: Any) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        
        if let stringValue = value as? String {
            append(stringValue.data(using: .utf8)!)
        } else if let intValue = value as? Int {
            append("\(intValue)".data(using: .utf8)!)
        } else if let boolValue = value as? Bool {
            append(boolValue ? "true".data(using: .utf8)! : "false".data(using: .utf8)!)
        }
        append("\r\n".data(using: .utf8)!)
    }
    
    mutating func appendMultipartFile(boundary: String, name: String, filename: String, data: Data, mimeType: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
    
    mutating func appendMultipartEnd(boundary: String) {
        append("--\(boundary)--\r\n".data(using: .utf8)!)
    }
}

extension FreeToken {
    class SSEClient<T: Decodable & Sendable>: @unchecked Sendable, EventHandler {
        private let url: URL
        private let headers: [String: String]
        private let body: Data
        private let onMessageChunk: @Sendable (String) async -> Void
        private let onComplete: @Sendable (Result<T, FreeTokenError>) async -> Void
        private var eventSource: EventSource?
        private var finalResponseData: [String: Any] = [:]
        private let decoder = JSONDecoder()
        private let sessionId = UUID().uuidString.prefix(8)
        
        // Sequential processing queue for message chunks
        private let messageProcessingQueue = DispatchQueue(label: "message-chunk-processing", qos: .userInitiated)
        
        init(
            url: URL,
            headers: [String: String],
            body: Data,
            onMessageChunk: @escaping @Sendable (String) async -> Void,
            onComplete: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
        ) {
            self.url = url
            self.headers = headers
            self.body = body
            self.onMessageChunk = onMessageChunk
            self.onComplete = onComplete
            
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                if let date = formatter.date(from: dateString) {
                    return date
                } else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
                }
            }
        }
        
        func start() {
            FreeToken.shared.logger("🚀[\(sessionId)] Starting SSE connection to \(url)", .info)
            
            var config = EventSource.Config(handler: self, url: url)
            config.method = "POST"
            config.body = body
            config.headers = headers
            
            eventSource = EventSource(config: config)
            eventSource?.start()
        }
        
        private func buildFinalResponse() -> Result<T, FreeTokenError> {
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: finalResponseData)
                let decodedResponse = try decoder.decode(T.self, from: jsonData)
                return .success(decodedResponse)
            } catch {
                FreeToken.shared.logger("🔴[\(sessionId)] Failed to build final response: \(error)", .error)
                let fallbackResponse = ["message": ["role": "assistant", "content": ""]]
                if let fallbackData = try? JSONSerialization.data(withJSONObject: fallbackResponse),
                   let fallbackDecoded = try? decoder.decode(T.self, from: fallbackData) {
                    return .success(fallbackDecoded)
                }
                return .failure(FreeTokenError.decodingError(message: "Failed to decode final response: \(error.localizedDescription)"))
            }
        }
        
        // MARK: - EventHandler Protocol
        func onOpened() {
            FreeToken.shared.logger("🟢[\(sessionId)] SSE connection opened", .info)
        }
        
        func onClosed() {
            FreeToken.shared.logger("🔴[\(sessionId)] SSE connection closed", .info)
        }
        
        func onMessage(eventType: String, messageEvent: MessageEvent) {
            FreeToken.shared.logger("🟠[\(sessionId)] Received event: \(eventType)", .debug)
            
            switch eventType {
            case "message_chunk":
                FreeToken.shared.logger("🟢[\(sessionId)] Processing message_chunk", .debug)
                let messageData = messageEvent.data
                messageProcessingQueue.sync {
                    // Process synchronously on the queue to maintain strict ordering
                    let semaphore = DispatchSemaphore(value: 0)
                    Task {
                        await onMessageChunk(messageData)
                        semaphore.signal()
                    }
                    semaphore.wait()
                }
                
            case "token_usage":
                FreeToken.shared.logger("🟢[\(sessionId)] Processing token_usage", .debug)
                if let jsonData = messageEvent.data.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    finalResponseData["token_usage"] = json
                    FreeToken.shared.logger("🟢[\(sessionId)] Token usage stored", .debug)
                }
                
            case "complete":
                FreeToken.shared.logger("🟢[\(sessionId)] Processing complete event", .debug)
                if let jsonData = messageEvent.data.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    finalResponseData["message"] = json
                    FreeToken.shared.logger("🟢[\(sessionId)] Complete message stored", .debug)
                }
                
                // Build and return final response
                let result = buildFinalResponse()
                Task { @Sendable in
                    await onComplete(result)
                }
                eventSource?.stop()
                
            case "error":
                FreeToken.shared.logger("🔴[\(sessionId)] Processing error event", .error)
                if let jsonData = messageEvent.data.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    finalResponseData["error"] = json
                    FreeToken.shared.logger("🔴[\(sessionId)] Error stored", .error)
                }
                
                // Build and return final response with error
                let result = buildFinalResponse()
                Task { @Sendable in
                    await onComplete(result)
                }
                eventSource?.stop()
                
            default:
                FreeToken.shared.logger("🟡[\(sessionId)] Unknown event type: \(eventType)", .warning)
            }
        }
        
        func onComment(comment: String) {
            FreeToken.shared.logger("💬[\(sessionId)] SSE comment: \(comment)", .debug)
        }
        
        func onError(error: Error) {
            FreeToken.shared.logger("🔴[\(sessionId)] SSE error: \(error.localizedDescription)", .error)
            let streamError = FreeTokenError.streamError(message: error.localizedDescription)
            Task { @Sendable in
                await onComplete(.failure(streamError))
            }
            eventSource?.stop()
        }
    }
    
    // ETag Cache implementation
    private class ETagCache: @unchecked Sendable {
        private let cache = NSCache<NSString, CacheEntry>()
        private let queue = DispatchQueue(label: "etag-cache", attributes: .concurrent)
        
        init() {
            cache.countLimit = 100 // Limit cache size
        }
        
        func store(etag: String, data: Data, for url: URL) {
            queue.async(flags: .barrier) {
                let entry = CacheEntry(etag: etag, data: data, timestamp: Date())
                self.cache.setObject(entry, forKey: url.absoluteString as NSString)
            }
        }
        
        func getETag(for url: URL) -> String? {
            queue.sync {
                guard let entry = cache.object(forKey: url.absoluteString as NSString),
                      !entry.isExpired else {
                    cache.removeObject(forKey: url.absoluteString as NSString)
                    return nil
                }
                return entry.etag
            }
        }
        
        func getCachedData(for url: URL) -> Data? {
            queue.sync {
                guard let entry = cache.object(forKey: url.absoluteString as NSString),
                      !entry.isExpired else {
                    cache.removeObject(forKey: url.absoluteString as NSString)
                    return nil
                }
                return entry.data
            }
        }
        
        func flushCacheData(for url: URL) -> Void {
            queue.async(flags: .barrier) {
                self.cache.removeObject(forKey: url.absoluteString as NSString)
            }
        }
        
        private class CacheEntry {
            let etag: String
            let data: Data
            let timestamp: Date
            
            init(etag: String, data: Data, timestamp: Date) {
                self.etag = etag
                self.data = data
                self.timestamp = timestamp
            }
            
            var isExpired: Bool {
                // Cache entries expire after 1 hour
                Date().timeIntervalSince(timestamp) > 3600
            }
        }
    }
}
