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
        public var isAICapable: Bool {
            get {
                return sufficientVRAM && sufficientMetalSupport
            }
        }
        private let sufficientVRAM: Bool
        private let sufficientMetalSupport: Bool
        
        public init(memoryRequirement: Int) {
            let vRAM = os_proc_available_memory()

            if (vRAM < memoryRequirement) {
                let requiredMemory = String (
                    format: "%.1fMB", Double(memoryRequirement) / Double(1 << 20)
                )
                let availableMemory = String (
                    format: "%.1fMB", Double(vRAM) / Double(1 << 20)
                )
                let errorMessage = (
                    "[FreeToken] The system cannot provide \(requiredMemory) VRAM (\(availableMemory) available) as requested to the app. The model cannot be initialized on the device."
                )
                FreeToken.shared.logger(errorMessage, .error)
                
                sufficientVRAM = false
            } else {
                sufficientVRAM = true
            }
            
            sufficientMetalSupport = MTLCreateSystemDefaultDevice() != nil
        }

    }
}
