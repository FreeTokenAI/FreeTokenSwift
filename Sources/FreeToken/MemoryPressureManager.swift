//  MemoryPressureManager.swift
//  FreeToken
//
//  Created by AI assistant on 2025-08-22.
//
//  Singleton manager that centralizes memory pressure handling and lets subsystems
//  register staged cleanup tasks. It wraps a single `MemoryPressureMonitor` to avoid
//  redundant DispatchSources and coordinates callbacks by severity.

import Foundation

extension FreeToken {

    /// A central manager for memory pressure cleanup tasks.
    /// Usage:
    /// ```swift
    /// FreeToken.MemoryPressureManager.shared.register(minLevel: .warning) { level in
    ///     ImageCache.shared.trim()
    /// }
    /// ```
    /// The manager starts automatically on first access. You can call `start()` early
    /// (e.g. during app initialization) if you need earlier registration.
    final class MemoryPressureManager: @unchecked Sendable {
        static let shared = MemoryPressureManager()

        struct CleanupTask: Sendable {
            let id: UUID
            let minLevel: MemoryPressureLevel
            let action: @Sendable (MemoryPressureLevel) -> Void
        }

        private let queue = DispatchQueue(label: "MemoryPressureManager.Queue")
        private var tasks: [UUID: CleanupTask] = [:]
        private var monitorStarted = false
        private lazy var monitor: MemoryPressureMonitor = {
            // Deliver on a background queue for fastest reaction; we run task actions on `queue`.
            let m = MemoryPressureMonitor(deliverOn: .global(qos: .userInitiated)) { [weak self] level in
                self?.handle(level: level)
            }
            return m
        }()

        private init() {}

        /// Begin monitoring (idempotent). Called automatically on first registration if not already started.
        func start() {
            queue.async { [weak self] in
                guard let self, !self.monitorStarted else { return }
                self.monitorStarted = true
                self.monitor.start()
            }
        }

        /// Stop monitoring (idempotent). Tasks remain registered; call `start()` to resume.
        func stop() {
            queue.async { [weak self] in
                guard let self, self.monitorStarted else { return }
                self.monitor.stop()
                self.monitorStarted = false
            }
        }

        /// Register a cleanup task that will run when a memory pressure level >= `minLevel` occurs.
        /// - Parameters:
        ///   - minLevel: Minimum severity at which to invoke the task (default: `.warning`).
        ///   - action: Cleanup closure (keep it fast, idempotent, and non-blocking if possible).
        /// - Returns: A token (UUID) for later unregistration.
        @discardableResult
        func register(minLevel: MemoryPressureLevel = .warning,
                      action: @escaping @Sendable (MemoryPressureLevel) -> Void) -> UUID {
            let id = UUID()
            let task = CleanupTask(id: id, minLevel: minLevel, action: action)
            queue.async { [weak self] in
                guard let self else { return }
                self.tasks[id] = task
                if !self.monitorStarted { self.monitorStarted = true; self.monitor.start() }
            }
            return id
        }

        /// Unregister a previously registered task.
        func unregister(_ id: UUID) {
            queue.async { [weak self] in
                self?.tasks.removeValue(forKey: id)
            }
        }

        /// Remove all registered tasks (monitor continues running).
        func unregisterAll() {
            queue.async { [weak self] in
                self?.tasks.removeAll()
            }
        }

        /// Current number of registered tasks (snapshot; may be slightly stale if called concurrently).
        var taskCount: Int {
            queue.sync { tasks.count }
        }

        private func handle(level: MemoryPressureLevel) {
            // Execute staged cleanup serially on manager queue to avoid contention.
            queue.async { [weak self] in
                guard let self else { return }
                for task in self.tasks.values where level >= task.minLevel {
                    task.action(level)
                }
            }
        }
    }
}
