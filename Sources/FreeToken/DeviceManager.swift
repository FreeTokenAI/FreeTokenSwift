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
                
        private let sufficientVRAM: Bool
        private let sufficientMetalSupport: Bool
        
        init(memoryRequirement: Int) {
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
        
        func isTooHot() -> Bool {
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) || os(ipadOS)
                // Check if the device is overheating
                let thermalState = ProcessInfo.processInfo.thermalState
                switch thermalState {
                case .nominal, .fair:
                    return false
                case .serious, .critical:
                    // Device is too hot for AI processing
                    FreeToken.shared.logger("🔥 Device is too hot for AI processing. Thermal state: \(thermalState)", .warning)
                    return true
                @unknown default:
                    // Handle any future cases
                    FreeToken.shared.logger("Unknown thermal state: \(thermalState)", .warning)
                    return false
                }
            #else
                // Assume this is not a mobile device, or heating is not a problem.
                return false
            #endif
        }

    }
}
