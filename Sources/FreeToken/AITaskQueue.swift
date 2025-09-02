//
//  AITaskQueue.swift
//  FreeToken
//
//  Created by Vince Francesi on 8/21/25.
//
import Foundation

extension FreeToken {
    actor AITaskQueue {
        static let shared = AITaskQueue()

        private init() {}

        // Work item holds metadata and an async body that handles its own continuation.
        private struct WorkItem: Sendable {
            let name: String
            let startTime: DispatchTime
            let runLocation: RunLocation
            let body: @Sendable () async -> Void
            
            func hasExpired() -> Bool {
                if runLocation == .automatic,
                   DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds > 30_000_000_000 {
                    return true
                }
                return false
            }
        }

        private var queue: [WorkItem] = []
        private var isRunning: Bool = false

        func enqueue<T: Sendable>(name: String, runLocation: RunLocation, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let startTime = DispatchTime.now()

                let work = WorkItem(name: name, startTime: startTime, runLocation: runLocation, body: {
                    // Timeout check prior to execution if waited too long.
                    if runLocation == .automatic,
                       DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds > 30_000_000_000 {
                        FreeToken.shared.logger("⏰ AI task queue timeout reached, aborting operation", .error)
                        continuation.resume(throwing: FreeTokenError.aiQueueTimeout)
                        return
                    }
                    do {
                        let result = try await operation()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                })

                queue.append(work)
                Task { await self.processQueueIfNeeded() }
            }
        }

        // Start the next queued work item if not already running.
        private func processQueueIfNeeded() async {
            guard !isRunning, !queue.isEmpty else { return }

            isRunning = true
            
            // Look for expired all tasks and execute them first.
            let expiredIndexes = queue.indices.filter { queue[$0].hasExpired() }
            if !expiredIndexes.isEmpty {
                for expiredIndex in expiredIndexes {
                    let expiredItem = queue.remove(at: expiredIndex)
                    await expiredItem.body()
                }
            }
            
            guard !queue.isEmpty else {
                isRunning = false
                return
            }
                        
            let item = queue.removeFirst()
            FreeToken.shared.logger("🚀 Executing AI task \(item.name) in queue...", .info)
            // Execute body serially inside actor.
            await item.body()
            isRunning = false
            FreeToken.shared.logger("🏁 Finished Executing AI task \(item.name)", .info)
            await processQueueIfNeeded()
        }

        private func markFinishedAndProcessNext() async {
            isRunning = false
            await processQueueIfNeeded()
        }
    }
}
