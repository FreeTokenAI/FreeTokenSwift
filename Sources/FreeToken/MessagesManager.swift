//
//  MessagesManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/20/25.
//
import Foundation

extension FreeToken {
    class MessagesManager: @unchecked Sendable {
        var client: FreeToken? = nil
        let encryptionManager: EncryptionManager
        let cacheManager: CacheManager = CacheManager()
        
        /// A cache of messages indexed by message thread ID.
        actor CacheManager {
            var messages: [String: MessagesCache] = [:]
            
            func getMessagesCacheForThread(_ messageThreadID: String) -> MessagesCache? {
                return messages[messageThreadID]
            }
            
            func setMessagesCacheForThread(_ messageThreadID: String, cache: MessagesCache) {
                messages[messageThreadID] = cache
            }
            
            func getLastMessageForMessageThread(_ messageThreadID: String) -> Message? {
                return messages[messageThreadID]?.lastMessage
            }
            
            func getAllMessages() -> [Message] {
                return messages.values.flatMap { $0.messages }
            }
        }
        
        class MessagesCache: @unchecked Sendable {
            var messageThreadID: String {
                get {
                    return messageThread.id
                }
            }
            var lastMessageId: String? {
                return messages.last?.id
            }
            var lastMessage: Message? {
                return messages.last
            }
            
            let messageThread: MessageThread
            var messages: [Message] = []
            
            init(messageThread: MessageThread, messages: [Message]) {
                self.messageThread = messageThread
                self.messages = messages
            }
            
            func getMessageThread() -> MessageThread {
                return MessageThread(id: messageThread.id, messages: messages, createdAt: messageThread.createdAt, updatedAt: messageThread.updatedAt)
            }
            
            func append(_ message: Message) {
                messages.append(message)
            }
        }
        
        init(encryptionManager: EncryptionManager) {
            self.encryptionManager = encryptionManager
        }
        
        func getMessageThread(id messageThreadID: String, success successCompletion: @escaping @Sendable (_ messageThread: MessageThread, _ outOfSync: Bool) async -> Void, failure failureCompletion: @escaping @Sendable (FreeTokenError) async -> Void) async -> Void {
            if let messagesCache = await cacheManager.getMessagesCacheForThread(messageThreadID) {
                // Verify the last message in the cache matches the server
                await lastMessage(messageThreadID: messageThreadID) { result in
                    switch result {
                    case .success(let lastMessage):
                        if messagesCache.lastMessageId != lastMessage.id {
                            // Messages were out of sync with the server, fetch from server and report.
                            FreeToken.shared.logger("☁️ Messages out of sync with server for thread \(messageThreadID)", .debug)
                            await self.fetchMessages(messageThreadID: messageThreadID) { fetchResult in
                                switch fetchResult {
                                case .success(let messages):
                                    await successCompletion(messages, true)
                                case .failure(let error):
                                    await failureCompletion(error)
                                }
                            }
                        } else {
                            // Messages are in sync, return cached messages
                            FreeToken.shared.logger("📥 Returning cached messages for thread \(messageThreadID)", .debug)
                            await successCompletion(messagesCache.messageThread, false)
                        }
                    case .failure:
                        // If there's an error, fetch messages from server
                        await self.fetchMessages(messageThreadID: messageThreadID, result: { fetchResult in
                            switch fetchResult {
                            case .success(let messages):
                                await successCompletion(messages, false)
                            case .failure(let error):
                                await failureCompletion(error)
                            }
                        })
                    }
                }

            } else {
                // No messages cached, fetch from server
                await fetchMessages(messageThreadID: messageThreadID, result: { result in
                    switch result {
                    case .success(let messages):
                        await successCompletion(messages, false)
                    case .failure(let error):
                        await failureCompletion(error)
                    }
                })
            }
        }
        
        func createMessageThread(systemMessage: Message, result handler: @escaping @Sendable (Result<MessageThread, FreeTokenError>) async -> Void) async {
            guard let client = client else {
                FreeToken.shared.logger("🔴 MessagesManager not initialized with a FreeToken client", .error)
                await handler(.failure(FreeTokenError.clientNotInitialized))
                return
            }
            
            let messageRequest = Codings.CreateMessageRequest(messageThreadID: nil, role: systemMessage.role.rawValue, content: systemMessage.content, encryptionEnabled: false, lastMessageID: nil, encryptedImages: nil)
            
            let request = Codings.CreateMessageThreadRequest(messages: [messageRequest])
            
            let profiler = Profiler()
            await client.postData(path: "message_threads", data: request, responseType: Codings.ShowMessageThreadResponse.self) { result in
                switch result {
                case .success(let response):
                    profiler.end(eventType: Profiler.EventType.createMessageThread, eventTypeID: response.id, isSuccess: true)
                    FreeToken.shared.logger("Message thread created successfully: \(response.id)", .info)
                    
                    do {
                        let messageThread = try await MessageThread.fromServerResponse(response)
                        
                        // Cache the new message thread
                        let cache = MessagesCache(messageThread: messageThread, messages: messageThread.messages)
                        await self.cacheManager.setMessagesCacheForThread(messageThread.id, cache: cache)
                        
                        await handler(.success(messageThread))
                    } catch {
                        let freeTokenError = FreeTokenError.httpError(message: "Failed to create message thread: \(error.localizedDescription)", code: nil)
                        FreeToken.shared.logger("🔴 Error creating message thread from response: \(error)", .error)
                        await handler(.failure(freeTokenError))
                    }
                case .failure(let error):
                    profiler.end(eventType: .createMessageThread, isSuccess: false, errorMessage: error.message)
                    FreeToken.shared.logger("Failed to create message thread: \(error)", .error)
                    await handler(.failure(error))
                }
            }
        }
        
        func addMessage(message: Message, messageThreadID: String, result handler: @escaping @Sendable (Result<Message, FreeTokenError>) async -> Void) async {
            guard let client = client else {
                FreeToken.shared.logger("🔴 MessagesManager not initialized with a FreeToken client", .error)
                await handler(.failure(FreeTokenError.clientNotInitialized))
                return
            }
            
            // Add a message to the thread and cache it
            let lastMessage = await cacheManager.getLastMessageForMessageThread(messageThreadID)
            
            // Handle message based on encryption mode and attachments
            let hasImageAttachments = message.attachments?.contains { $0.type == .image } == true
            
            // Debug logging for image attachments
            if hasImageAttachments {
                FreeToken.shared.logger("🔍 MESSAGE DEBUG: Message has \(message.attachments?.count ?? 0) total attachments", .info)
                let imageCount = message.attachments?.filter { $0.type == .image }.count ?? 0
                FreeToken.shared.logger("🔍 MESSAGE DEBUG: Message has \(imageCount) image attachments", .info)
                
                for (index, attachment) in (message.attachments ?? []).enumerated() {
                    if attachment.type == .image {
                        FreeToken.shared.logger("🔍 MESSAGE DEBUG: Image \(index): \(attachment.data.count) bytes, type: \(attachment.contentType)", .info)
                    }
                }
            } else {
                FreeToken.shared.logger("🔍 MESSAGE DEBUG: Message has NO image attachments", .info)
            }
            
            if encryptionManager.isEncryptionEnabled {
                // Encrypted mode: use encrypted request (handles both content and images)
                let request = message.toEncryptedRequest(
                    messageThreadID: messageThreadID,
                    lastMessageID: lastMessage?.id,
                    encryptionManager: encryptionManager
                )
                
                await client.postData(path: "messages", data: request, responseType: Codings.ShowMessageResponse.self, completion: { result in
                    await self.handleMessageResponse(result, messageThreadID: messageThreadID, handler: handler)
                })
            } else if hasImageAttachments {
                // Unencrypted mode with images: use multipart form data
                let (jsonData, imageAttachments) = message.toUnencryptedMultipartData(
                    messageThreadID: messageThreadID,
                    lastMessageID: lastMessage?.id
                )
                
                await client.postMultipartData(path: "messages", jsonData: jsonData, attachments: imageAttachments, responseType: Codings.ShowMessageResponse.self, completion: { result in
                    await self.handleMessageResponse(result, messageThreadID: messageThreadID, handler: handler)
                })
            } else {
                // Unencrypted mode without images: use regular JSON request
                let request = message.toUnencryptedRequest(
                    messageThreadID: messageThreadID,
                    lastMessageID: lastMessage?.id
                )
                
                await client.postData(path: "messages", data: request, responseType: Codings.ShowMessageResponse.self, completion: { result in
                    await self.handleMessageResponse(result, messageThreadID: messageThreadID, handler: handler)
                })
            }
        }
        
        private func handleMessageResponse(_ result: Result<Codings.ShowMessageResponse, FreeTokenError>, messageThreadID: String, handler: @escaping @Sendable (Result<Message, FreeTokenError>) async -> Void) async {
            switch result {
            case .success(let response):
                do {
                    // Create message, fetching any URL-based images asynchronously
                    let message = try await Message.fromServerResponse(response)
                    
                    if let messageCache = await self.cacheManager.getMessagesCacheForThread(messageThreadID) {
                        let newMessages = messageCache.messages + [message]
                        let existingMessageThread = messageCache.getMessageThread()
                        let newMessageThread = MessageThread(id: existingMessageThread.id, messages: newMessages, createdAt: existingMessageThread.createdAt, updatedAt: message.createdAt ?? Date())
                        let updatedCache = MessagesCache(messageThread: newMessageThread, messages: newMessages)
                        
                        await self.cacheManager.setMessagesCacheForThread(messageThreadID, cache: updatedCache)
                        
                        await handler(.success(message))
                    } else {
                        // Somehow a message was added to an thread without ever fetching the thread.
                    // Potentially the app is caching all messages and threads in their own datastore
                    // -> Fetch to update our cache which should include the new message
                    await self.fetchMessages(messageThreadID: messageThreadID) { result in
                        switch result {
                        case .success(_):
                            await handler(.success(message))
                        case .failure(let error):
                            await handler(.failure(error))
                        }
                    }
                }
                } catch {
                    // Handle errors from creating message (e.g., image fetch failures)
                    let freeTokenError = FreeTokenError.httpError(message: error.localizedDescription, code: nil)
                    FreeToken.shared.logger("🔴 Error creating message from server response: \(error)", .error)
                    await handler(.failure(freeTokenError))
                }
            case .failure(let error):
                FreeToken.shared.logger("🔴 Error adding message to thread \(messageThreadID): \(error.message)", .error)
                await handler(.failure(error))
            }
        }
        
        func getMessage(id: String, result handler: @escaping @Sendable (Result<Message, FreeTokenError>) async -> Void) async {
            guard let client = client else {
                FreeToken.shared.logger("🔴 MessagesManager not initialized with a FreeToken client", .error)
                await handler(.failure(FreeTokenError.clientNotInitialized))
                return
            }
            
            // Look over the cache first since messages are immutable
            let cachedMessages = await cacheManager.getAllMessages()
            if let cachedMessage = cachedMessages.first(where: { $0.id == id }) {
                await handler(.success(cachedMessage))
                return
            }
            
            // Fetch a single message by ID
            await client.fetchResource(path: "messages/\(id)", responseType: Codings.ShowMessageResponse.self) { result in
                switch result {
                case .success(let response):
                    do {
                        let message = try await Message.fromServerResponse(response)
                        await handler(.success(message))
                    } catch {
                        let freeTokenError = FreeTokenError.httpError(message: "Failed to create message: \(error.localizedDescription)", code: nil)
                        FreeToken.shared.logger("🔴 Error creating message from response: \(error)", .error)
                        await handler(.failure(freeTokenError))
                    }
                case .failure(let error):
                    FreeToken.shared.logger("🔴 Error fetching message \(id): \(error.message)", .error)
                    await handler(.failure(error))
                }
            }
        }
        
        func lastMessage(messageThreadID: String, result handler: @escaping @Sendable (Result<Codings.ShowMessageResponse, FreeTokenError>) async -> Void) async {
            guard let client = client else {
                FreeToken.shared.logger("🔴 MessagesManager not initialized with a FreeToken client", .error)
                await handler(.failure(FreeTokenError.clientNotInitialized))
                return
            }
            // verify the last message in the thread matches the last message on the server
            await client.fetchResource(path: "message_threads/\(messageThreadID)/last_message", responseType: Codings.ShowMessageResponse.self) { result in
                await handler(result)
            }
        }
        
        private func encrypt(content: String) -> String {
            return encryptionManager.encrypt(content)
        }
        
        private func decrypt(content: String) -> String {
            return encryptionManager.decrypt(content)
        }
        
        private func fetchMessages(messageThreadID: String, result handler: @escaping @Sendable (Result<MessageThread, FreeTokenError>) async -> Void) async {
            guard let client = client else {
                FreeToken.shared.logger("🔴 MessagesManager not initialized with a FreeToken client", .error)
                await handler(.failure(FreeTokenError.clientNotInitialized))
                return
            }
            
            // Fetch messages from server and cache them
            await client.fetchResource(path: "message_threads/\(messageThreadID)", responseType: Codings.ShowMessageThreadResponse.self) { result in
                switch result {
                case .success(let response):
                    do {
                        let messageThread = try await MessageThread.fromServerResponse(response)
                        let cache = MessagesCache(messageThread: messageThread, messages: messageThread.messages)
                        
                        await self.cacheManager.setMessagesCacheForThread(messageThreadID, cache: cache)
                        FreeToken.shared.logger("📩 Fetched \(messageThread.messages.count) messages for thread \(messageThreadID)", .info)
                        await handler(.success(messageThread))
                    } catch {
                        let freeTokenError = FreeTokenError.httpError(message: "Failed to create message thread: \(error.localizedDescription)", code: nil)
                        FreeToken.shared.logger("🔴 Error creating message thread from response: \(error)", .error)
                        await handler(.failure(freeTokenError))
                    }
                case .failure(let error):
                    FreeToken.shared.logger("🔴 Error fetching messages for thread \(messageThreadID): \(error.message)", .error)
                    await handler(.failure(error))
                }
            }
        }
    }
}
