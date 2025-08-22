//  MemoryPressureMonitor.swift
//  FreeToken
//
//  Created by AI assistant on 2025-08-22.
//
//  Darwin-only memory pressure monitoring abstraction using GCD DispatchSource.
//  Simplified: UIKit-specific memory warning observer removed; single source of truth.

import Foundation
import Dispatch

extension FreeToken {
    
    /// Severity levels for memory pressure.
    enum MemoryPressureLevel: Int, Comparable, CustomStringConvertible, Sendable {
        case normal = 0
        case warning = 1
        case critical = 2
        
        static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool { lhs.rawValue < rhs.rawValue }
        
        var description: String {
            switch self {
            case .normal: return "normal"
            case .warning: return "warning"
            case .critical: return "critical"
            }
        }
    }
    
    /// Common interface for memory pressure monitors.
    protocol MemoryPressureMonitoring: AnyObject {
        /// Start producing events (idempotent).
        func start()
        /// Stop producing events (idempotent).
        func stop()
    }
    
    // MARK: - Facade
    
    /// Facade wrapping a single DispatchSource memory pressure monitor.
    final class MemoryPressureMonitor: MemoryPressureMonitoring {
        typealias Handler = @Sendable (_ level: MemoryPressureLevel) -> Void
        
        private let handler: Handler
        private var monitors: [MemoryPressureMonitoring] = []
        private let aggregationQueue = DispatchQueue(label: "MemoryPressureMonitor.Aggregation")
        private var pendingHighest: MemoryPressureLevel = .normal
        private var dispatchWorkScheduled = false
        
        /// Create a monitor facade.
        /// - Parameters:
        ///   - handler: Invoked on main queue (default) with coalesced highest severity for grouped events.
        ///   - deliverOn: Queue on which to deliver the handler (default: `.main`).
        init(deliverOn queue: DispatchQueue = .main, handler: @escaping Handler) {
            // Wrap the user handler so we deliver on the requested queue while keeping @Sendable semantics.
            self.handler = { level in queue.async { handler(level) } }
            monitors.append(DispatchMemoryPressureMonitor { [weak self] lvl in self?.ingest(level: lvl) })
        }
        
        func start() { monitors.forEach { $0.start() } }
        func stop() { monitors.forEach { $0.stop() } }
        
        // Coalesce multiple events arriving close together to avoid duplicate work.
        private func ingest(level: MemoryPressureLevel) {
            aggregationQueue.async { [weak self] in
                guard let self else { return }
                if level > pendingHighest { pendingHighest = level }
                if !dispatchWorkScheduled {
                    dispatchWorkScheduled = true
                    aggregationQueue.asyncAfter(deadline: .now()) { [weak self] in
                        guard let self else { return }
                        let toSend = self.pendingHighest
                        self.pendingHighest = .normal
                        self.dispatchWorkScheduled = false
                        self.handler(toSend)
                    }
                }
            }
        }
        
        deinit { stop() }
    }
    
    // MARK: - Implementation (Darwin)
    
    /// GCD-based monitor providing severity granularity (normal/warning/critical).
    final class DispatchMemoryPressureMonitor: MemoryPressureMonitoring {
        private var source: DispatchSourceMemoryPressure?
        private let queue: DispatchQueue
        private let handler: @Sendable (MemoryPressureLevel) -> Void
        private var running = false
        private let lock = NSLock()
        
        init(queue: DispatchQueue = .global(qos: .utility), handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
            self.queue = queue
            self.handler = handler
        }
        
        func start() {
            lock.lock(); defer { lock.unlock() }
            guard !running else { return }
            let src = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: queue)
            src.setEventHandler { [weak self, weak src] in
                guard let self, let raw = src?.data else { return }
                self.handler(Self.map(raw))
            }
            src.setCancelHandler { [weak self] in self?.running = false }
            source = src
            running = true
            src.resume()
        }
        
        func stop() {
            lock.lock(); defer { lock.unlock() }
            guard running, let s = source else { return }
            s.cancel()
            source = nil
        }
        
        deinit { stop() }
        
        private static func map(_ events: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
            if events.contains(.critical) { return .critical }
            if events.contains(.warning) { return .warning }
            if events.contains(.normal) { return .normal }
            return .warning // conservative fallback
        }
    }
    
    
    
}
// MARK: - Sendable Conformances (Unchecked)

// These classes manage internal mutation via locks or serial queues, allowing us to assert
// thread-safety manually for Sendable closures captured by Dispatch APIs.
extension FreeToken.MemoryPressureMonitor: @unchecked Sendable {}
extension FreeToken.DispatchMemoryPressureMonitor: @unchecked Sendable {}

// Non-Darwin platforms currently unsupported.
