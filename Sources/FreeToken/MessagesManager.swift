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
        
        func createMessageThread(agentScope: Optional<String> = nil, result handler: @escaping @Sendable (Result<MessageThread, FreeTokenError>) async -> Void) async {
            guard let client = client else {
                FreeToken.shared.logger("🔴 MessagesManager not initialized with a FreeToken client", .error)
                await handler(.failure(FreeTokenError.clientNotInitialized))
                return
            }
            
            let request = Codings.CreateMessageThreadRequest(agentScope: agentScope, encryptionEnabled: encryptionManager.isEncryptionEnabled)
            
            let profiler = Profiler()
            await client.postData(path: "message_threads", data: request, responseType: Codings.ShowMessageThreadResponse.self) { result in
                switch result {
                case .success(let response):
                    profiler.end(eventType: Profiler.EventType.createMessageThread, eventTypeID: response.id, isSuccess: true)
                    FreeToken.shared.logger("Message thread created successfully: \(response.id)", .info)
                    let messageThread = MessageThread(from: response)
                    
                    // Cache the new message thread
                    let cache = MessagesCache(messageThread: messageThread, messages: messageThread.messages)
                    await self.cacheManager.setMessagesCacheForThread(messageThread.id, cache: cache)
                    
                    await handler(.success(messageThread))
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
            
            let request = Codings.CreateMessageRequest(messageThreadID: messageThreadID, role: message.role.rawValue, content:  encryptionManager.encrypt(message.content), encryptionEnabled: encryptionManager.isEncryptionEnabled, lastMessageID: lastMessage?.id)
            
            await client.postData(path: "messages", data: request, responseType: Codings.ShowMessageResponse.self, completion: { result in
                switch result {
                case .success(let response):
                    // Update the cache with the new message
                    let message = Message(from: response)
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
                case .failure(let error):
                    FreeToken.shared.logger("🔴 Error adding message to thread \(messageThreadID): \(error.message)", .error)
                    await handler(.failure(error))
                }
            })
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
                    let message = Message(from: response)
                    await handler(.success(message))
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
                    let messageThread = MessageThread(from: response)
                    let cache = MessagesCache(messageThread: messageThread, messages: messageThread.messages)
                    
                    await self.cacheManager.setMessagesCacheForThread(messageThreadID, cache: cache)
                    FreeToken.shared.logger("📩 Fetched \(messageThread.messages.count) messages for thread \(messageThreadID)", .info)
                    await handler(.success(messageThread))
                case .failure(let error):
                    FreeToken.shared.logger("🔴 Error fetching messages for thread \(messageThreadID): \(error.message)", .error)
                    await handler(.failure(error))
                }
            }
        }
    }
}
