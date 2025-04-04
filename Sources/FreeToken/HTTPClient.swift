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
            completion: @escaping @Sendable (Result<T, Codings.ErrorResponse>) -> Void
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.allHTTPHeaderFields = headers
            request.httpBody = body
            
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    // Handle client-side error
                    let clientError = Codings.ErrorResponse(
                        error: "ClientError",
                        message: error.localizedDescription,
                        code: nil
                    )
                    completion(.failure(clientError))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    // Handle server-side error
                    if let data = data {
                        do {
                            let errorMessage = try self.decoder.decode(Codings.RawErrorResponse.self, from: data)
                            let apiError = Codings.ErrorResponse(error: "RequestFailed", message: errorMessage.message, code: (response as? HTTPURLResponse)?.statusCode)
                            completion(.failure(apiError))
                        } catch {
                            let genericError = Codings.ErrorResponse(
                                error: "ServerError",
                                message: "Unable to parse error response",
                                code: (response as? HTTPURLResponse)?.statusCode
                            )
                            completion(.failure(genericError))
                        }
                    } else {
                        let noDataError = Codings.ErrorResponse(
                            error: "NoDataError",
                            message: "No data received from server",
                            code: (response as? HTTPURLResponse)?.statusCode
                        )
                        completion(.failure(noDataError))
                    }
                    return
                }
                
                guard let data = data else {
                    let noDataError = Codings.ErrorResponse(
                        error: "NoDataError",
                        message: "No data received from server",
                        code: nil
                    )
                    completion(.failure(noDataError))
                    return
                }
                
                do {
                    let decodedResponse = try self.decoder.decode(T.self, from: data)
                    completion(.success(decodedResponse))
                } catch let DecodingError.keyNotFound(key, context) {
                    let decodingError = Codings.ErrorResponse(
                        error: "DecodingError",
                        message: "Missing key: \(key.stringValue), Context: \(context)",
                        code: nil
                    )
                    completion(.failure(decodingError))
                } catch let DecodingError.typeMismatch(type, context) {
                    let decodingError = Codings.ErrorResponse(
                        error: "DecodingError",
                        message: "Type mismatch for \(type): \(context)",
                        code: nil
                    )
                    completion(.failure(decodingError))
                } catch let DecodingError.valueNotFound(type, context) {
                    let decodingError = Codings.ErrorResponse(
                        error: "DecodingError",
                        message: "Missing value for \(type): \(context)",
                        code: nil
                    )
                    completion(.failure(decodingError))
                } catch let DecodingError.dataCorrupted(context) {
                    let decodingError = Codings.ErrorResponse(
                        error: "DecodingError",
                        message: "Corrupt data: \(context)",
                        code: nil
                    )
                    completion(.failure(decodingError))
                } catch {
                    let decodingError = Codings.ErrorResponse(
                        error: "DecodingError",
                        message: "Unknown decoding error: \(error)",
                        code: nil
                    )
                    completion(.failure(decodingError))
                }
            }
            
            task.resume()
        }
        
        // HTTP Streaming Support
        internal func streamRequest(
            to url: URL,
            method: String = "GET",
            headers: [String: String] = [:],
            body: Data? = nil,
            onDataReceived: @Sendable @escaping (Data) -> Void,
            onComplete: @escaping @Sendable (Result<Data, Codings.ErrorResponse>) -> Void
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.allHTTPHeaderFields = headers
            request.httpBody = body
            
            let sessionDelegate = HTTPStreamDelegate(
                onDataReceived: onDataReceived,
                onComplete: onComplete
            )
            
            let streamingSession = URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: nil)
            let task = streamingSession.dataTask(with: request)
            task.resume()
        }
        
        // Convenience methods for GET and POST
        internal func get<T: Decodable>(
            from url: URL,
            headers: [String: String] = [:],
            responseType: T.Type,
            completion: @escaping @Sendable (Result<T, Codings.ErrorResponse>) -> Void
        ) {
            sendRequest(to: url, method: "GET", headers: headers, responseType: responseType, completion: completion)
        }
        
        internal func post<T: Decodable>(
            to url: URL,
            headers: [String: String] = [:],
            body: Data,
            responseType: T.Type,
            completion: @escaping @Sendable (Result<T, Codings.ErrorResponse>) -> Void
        ) {
            sendRequest(to: url, method: "POST", headers: headers, body: body, responseType: responseType, completion: completion)
        }
        
        internal func streamPost<T: Decodable>(
            to url: URL,
            headers: [String: String] = [:],
            body: Data,
            streamCallback: @escaping @Sendable (String) -> Void,
            completion: @escaping @Sendable (Result<T, Codings.ErrorResponse>) -> Void
        ) {
            streamRequest(to: url, method: "POST", headers: headers, body: body) { data in
                let bodyChunk = String(data: data, encoding: .utf8)!
                streamCallback(bodyChunk)
            } onComplete: { result in
                switch result {
                case .success(let data):
                    do {
                        let decodedResponse = try self.decoder.decode(T.self, from: data)
                        completion(.success(decodedResponse))
                    } catch let DecodingError.keyNotFound(key, context) {
                        let decodingError = Codings.ErrorResponse(
                            error: "DecodingError",
                            message: "Missing key: \(key.stringValue), Context: \(context)",
                            code: nil
                        )
                        completion(.failure(decodingError))
                    } catch let DecodingError.typeMismatch(type, context) {
                        let decodingError = Codings.ErrorResponse(
                            error: "DecodingError",
                            message: "Type mismatch for \(type): \(context)",
                            code: nil
                        )
                        completion(.failure(decodingError))
                    } catch let DecodingError.valueNotFound(type, context) {
                        let decodingError = Codings.ErrorResponse(
                            error: "DecodingError",
                            message: "Missing value for \(type): \(context)",
                            code: nil
                        )
                        completion(.failure(decodingError))
                    } catch let DecodingError.dataCorrupted(context) {
                        let decodingError = Codings.ErrorResponse(
                            error: "DecodingError",
                            message: "Corrupt data: \(context)",
                            code: nil
                        )
                        completion(.failure(decodingError))
                    } catch {
                        let decodingError = Codings.ErrorResponse(
                            error: "DecodingError",
                            message: "Unknown decoding error: \(error)",
                            code: nil
                        )
                        completion(.failure(decodingError))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }

        }
    }
    
    
    class HTTPStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let onDataReceived: @Sendable (Data) -> Void
        private let onComplete: @Sendable (Result<Data, Codings.ErrorResponse>) -> Void
        private var httpResponse: HTTPURLResponse?
        private var accumulatedData: Data = Data()

        init(
            onDataReceived: @escaping @Sendable (Data) -> Void,
            onComplete: @escaping @Sendable (Result<Data, Codings.ErrorResponse>) -> Void
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
                let clientError = Codings.ErrorResponse(
                    error: "StreamError",
                    message: error.localizedDescription,
                    code: nil
                )
                onComplete(.failure(clientError))
            } else if let httpResponse = self.httpResponse, !(200...299).contains(httpResponse.statusCode) {
                // Handle non-200...299 status codes
                let serverError = Codings.ErrorResponse(
                    error: "HTTPError",
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

}
