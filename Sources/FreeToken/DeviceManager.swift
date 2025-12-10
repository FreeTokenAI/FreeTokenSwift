//
//  DeviceManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 11/16/24.
//

import Foundation
import Metal

extension FreeToken {
    class DeviceManager: @unchecked Sendable {
        var isAICapable: Bool {
            get {
                return sufficientVRAM && sufficientMetalSupport
            }
        }
        
        /// Highlander mode: Only one AI session at a time (iOS only)
        var isHighlanderMode: Bool {
            #if os(iOS)
            return true
            #else
            return false
            #endif
        }
                
        private let sufficientVRAM: Bool
        private let sufficientMetalSupport: Bool
        private let memoryRequirement: Int
        
        init(memoryRequirement: Int) {
            self.memoryRequirement = memoryRequirement

            #if os(macOS)
                // CHeck available memory on macOS
                let device = MTLCreateSystemDefaultDevice()
                let vRAM = device?.recommendedMaxWorkingSetSize ?? 0
            #else
                // Check if this is iOS
                let vRAM = os_proc_available_memory()
            #endif

            if (vRAM < memoryRequirement) {
                let requiredMemory = String (
                    format: "%.1fMB", Double(memoryRequirement) / Double(1 << 20)
                )
                let availableMemory = String (
                    format: "%.1fMB", Double(vRAM) / Double(1 << 20)
                )
                let errorMessage = (
                    "The system cannot provide \(requiredMemory) VRAM (\(availableMemory) available) as requested to the app. The model cannot be initialized on the device."
                )
                FreeToken.shared.logger(errorMessage, .error)
                
                sufficientVRAM = false
            } else {
                sufficientVRAM = true
            }
            
            sufficientMetalSupport = MTLCreateSystemDefaultDevice() != nil
        }

        // Recommend decode & batch thread counts leaving some headroom for UI / system tasks.
        // reserve: number of logical cores to leave unused. Ensures at least 1 decode thread.
        static func recommendedThreadCounts(reserve: Int = 2) -> (decode: Int, batch: Int) {
            let total = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let decode = max(1, total - reserve)
            // Allow batch to match decode, but keep at least one core free if possible
            let batch = min(total - 1, max(1, decode))
            return (decode, batch > 0 ? batch : decode)
        }
        
        func availableMemoryForRequestedSize() -> Bool {
            guard let device = MTLCreateSystemDefaultDevice() else {
                FreeToken.shared.logger("🔴 No Metal device available for GPU memory check", .error)
                return false
            }
            
            let currentAllocated = UInt64(device.currentAllocatedSize)
            let recommendedMax = UInt64(device.recommendedMaxWorkingSetSize)
            let reservedMemory: UInt64 = UInt64(Float(currentAllocated) * 0.2) // Reserve 20% for fluctuations
            
            let available: UInt64
            if recommendedMax > currentAllocated {
                let afterAllocation = recommendedMax - currentAllocated
                available = afterAllocation > reservedMemory ? afterAllocation - reservedMemory : 0
            } else {
                available = 0
            }
            
            FreeToken.shared.logger("🖥️ GPU Memory Check: \(formatBytes(available)) available, \(formatBytes(UInt64(memoryRequirement))) required", .debug)
            
            return available >= memoryRequirement
        }
        
        func isTooHot() -> Bool {
            #if os(iOS)
//                // Check if the device is overheating
//                let thermalState = ProcessInfo.processInfo.thermalState
//                switch thermalState {
//                case .nominal, .fair:
//                    return false
//                case .serious, .critical:
//                    // Device is too hot for AI processing
//                    FreeToken.shared.logger("🔥 Device is too hot for AI processing. Thermal state: \(thermalState)", .warning)
//                    return true
//                @unknown default:
//                    // Handle any future cases
//                    FreeToken.shared.logger("Unknown thermal state: \(thermalState)", .warning)
//                    return false
//                }
                return false // Testing ignoring overheat
            #else
                // Assume this is not a mobile device, heating is not a problem.
                return false
            #endif
        }
        
        // MARK: - GPU Memory Management
        
        /// Check if there's sufficient GPU memory available for a new session
        /// - Parameter threshold: Memory usage threshold (0.0-1.0), defaults to 0.8 (80%)
        /// - Returns: true if GPU memory usage is below threshold
        func hasAvailableGPUMemory(threshold: Double = 0.8) -> Bool {
            guard let device = MTLCreateSystemDefaultDevice() else {
                FreeToken.shared.logger("🔴 No Metal device available for GPU memory check", .error)
                return false
            }
            
            let currentAllocated = UInt64(device.currentAllocatedSize)
            let recommendedMax = UInt64(device.recommendedMaxWorkingSetSize)
            
            guard recommendedMax > 0 else {
                FreeToken.shared.logger("🟡 Unable to determine GPU memory limits", .warning)
                return true // Assume OK if we can't determine limits
            }
            
            let usageRatio = Double(currentAllocated) / Double(recommendedMax)
            let isAvailable = usageRatio < threshold
            
            FreeToken.shared.logger("🖥️ GPU Memory: \(formatBytes(currentAllocated))/\(formatBytes(recommendedMax)) (\(String(format: "%.1f", usageRatio * 100))%) - \(isAvailable ? "Available" : "Full")", .debug)
            
            if !isAvailable {
                FreeToken.shared.logger("⚠️ GPU memory usage at \(String(format: "%.1f", usageRatio * 100))% - threshold exceeded", .warning)
            }
            
            return isAvailable
        }
        
        /// Get current GPU memory statistics
        /// - Returns: (current: bytes used, max: bytes available, percentage: 0.0-1.0)
        func getGPUMemoryStats() -> (current: UInt64, max: UInt64, percentage: Double) {
            guard let device = MTLCreateSystemDefaultDevice() else {
                return (0, 0, 0.0)
            }
            
            let current = UInt64(device.currentAllocatedSize)
            let max = UInt64(device.recommendedMaxWorkingSetSize)
            let percentage = max > 0 ? Double(current) / Double(max) : 0.0
            
            return (current, max, percentage)
        }
        
        /// Force GPU memory cleanup if needed
        func forceGPUMemoryCleanup() {
            guard let device = MTLCreateSystemDefaultDevice() else { return }
            
            let beforeCleanup = UInt64(device.currentAllocatedSize)
            
            // Trigger Metal resource cleanup by creating and destroying a temporary command buffer
            // This encourages Metal to free unused resources
            let commandQueue = device.makeCommandQueue()
            let commandBuffer = commandQueue?.makeCommandBuffer()
            commandBuffer?.commit()
            commandBuffer?.waitUntilCompleted()
            
            let afterCleanup = UInt64(device.currentAllocatedSize)
            let freed = beforeCleanup > afterCleanup ? beforeCleanup - afterCleanup : 0
            
            if freed > 0 {
                FreeToken.shared.logger("🧹 GPU memory cleanup freed \(formatBytes(freed))", .info)
            } else {
                FreeToken.shared.logger("🧹 GPU memory cleanup completed (no memory freed)", .debug)
            }
        }
        
        /// Format bytes for human-readable display
        private func formatBytes(_ bytes: UInt64) -> String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .memory
            return formatter.string(fromByteCount: Int64(bytes))
        }

    }
}
