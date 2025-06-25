//
//  HTTPClient.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/16/24.
//

import Foundation

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
        
        // HTTP Streaming Support
        internal func streamRequest(
            to url: URL,
            method: String = "GET",
            headers: [String: String] = [:],
            body: Data? = nil,
            onDataReceived: @Sendable @escaping (Data) -> Void,
            onComplete: @escaping @Sendable (Result<Data, FreeTokenError>) -> Void
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.allHTTPHeaderFields = headers
            request.httpBody = body
            let semaphore = DispatchSemaphore(value: 0)
            
            let sessionDelegate = HTTPStreamDelegate(
                onDataReceived: onDataReceived,
                onComplete: { result in
                    onComplete(result)
                    semaphore.signal()
                }
            )
            
            let streamingSession = URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: nil)
            let task = streamingSession.dataTask(with: request)
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
        
        internal func streamPost<T: Decodable>(
            to url: URL,
            headers: [String: String] = [:],
            body: Data,
            streamCallback: @escaping @Sendable (String) async -> Void,
            completion: @escaping @Sendable (Result<T, FreeTokenError>) async -> Void
        ) {
            let semaphore = DispatchSemaphore(value: 0)
            streamRequest(to: url, method: "POST", headers: headers, body: body) { data in
                let bodyChunk = String(data: data, encoding: .utf8)!
                Task {
                    await streamCallback(bodyChunk)
                }
            } onComplete: { result in
                switch result {
                case .success(let data):
                    do {
                        let decodedResponse = try self.decoder.decode(T.self, from: data)
                        Task {
                            await completion(.success(decodedResponse))
                            semaphore.signal()
                        }
                    } catch let DecodingError.keyNotFound(key, context) {
                        let decodingError = FreeTokenError.decodingError(message: "Missing key: \(key.stringValue), Context: \(context)")
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
                            message: "Unknown decoding error: \(error)"
                        )
                        Task {
                            await completion(.failure(decodingError))
                            semaphore.signal()
                        }
                    }
                case .failure(let error):
                    let error = FreeTokenError.decodingError(message: error.localizedDescription)
                    Task {
                        await completion(.failure(error))
                        semaphore.signal()
                    }
                }
            }
            semaphore.wait()
        }
    }
    
    
    class HTTPStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let onDataReceived: @Sendable (Data) -> Void
        private let onComplete: @Sendable (Result<Data, FreeTokenError>) -> Void
        private var httpResponse: HTTPURLResponse?
        private var accumulatedData: Data = Data()

        init(
            onDataReceived: @escaping @Sendable (Data) -> Void,
            onComplete: @escaping @Sendable (Result<Data, FreeTokenError>) -> Void
        ) {
            self.onDataReceived = onDataReceived
            self.onComplete = onComplete
        }

        // Capture the HTTP response
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let httpResponse = response as? HTTPURLResponse {
                self.httpResponse = httpResponse
            }
            // Allow the session to continue receiving data
            completionHandler(.allow)
        }

        // Handle received data
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // Append received data to the accumulatedData property
            accumulatedData.append(data)
            // Call the data received closure with the incremental data
            onDataReceived(data)
        }

        // Handle completion and errors
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                // Handle client-side error
                let clientError = FreeTokenError.streamError(
                    message: error.localizedDescription
                )
                onComplete(.failure(clientError))
            } else if let httpResponse = self.httpResponse, !(200...299).contains(httpResponse.statusCode) {
                // Handle non-200...299 status codes
                let serverError = FreeTokenError.httpError(
                    message: "Received HTTP status code \(httpResponse.statusCode)",
                    code: httpResponse.statusCode
                )
                onComplete(.failure(serverError))
            } else {
                // Successful completion, return the full accumulated data
                onComplete(.success(accumulatedData))
            }
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
