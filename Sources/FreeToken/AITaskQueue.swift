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
            let startTime: DispatchTime
            let runLocation: RunLocation
            let body: @Sendable () async -> Void
        }

        private var queue: [WorkItem] = []
        private var isRunning: Bool = false

        func enqueue<T: Sendable>(runLocation: RunLocation, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let startTime = DispatchTime.now()

                let work = WorkItem(startTime: startTime, runLocation: runLocation) {
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
                }

                queue.append(work)
                Task { await self.processQueueIfNeeded() }
            }
        }

        // Start the next queued work item if not already running.
        private func processQueueIfNeeded() async {
            guard !isRunning, !queue.isEmpty else { return }

            isRunning = true
            let item = queue.removeFirst()
            FreeToken.shared.logger("🚀 Executing AI task in queue...", .info)
            // Execute body serially inside actor.
            await item.body()
            isRunning = false
            await processQueueIfNeeded()
        }

        private func markFinishedAndProcessNext() async {
            isRunning = false
            await processQueueIfNeeded()
        }
    }
}
