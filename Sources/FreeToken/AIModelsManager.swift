//
//  AIModelsManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 7/15/25.
//
import Foundation

extension FreeToken {
    class AIModelsManager: @unchecked Sendable {
        static let shared = AIModelsManager()
        
        private var aiModelManagers: [AIModelManagerWrapper] = []
        var defaultManager: AIModelManager? {
            get {
                return aiModelManagers.first(where: { $0.isDefault })?.aiModelManager
            }
        }
        var defaultDeviceManager: DeviceManager? {
            get {
                return aiModelManagers.first(where: { $0.isDefault })?.deviceManager
            }
        }
        
        struct AIModelManagerWrapper {
            let aiModelManager: AIModelManager
            let modelCode: String
            let isDefault: Bool
            let initializeOptions: AIModelInitializeOptions
            let deviceManager: DeviceManager
        }
        
        struct AIModelInitializeOptions {
            let modelConfig: Codings.AiModelResponse
            let clientVersion: String
        }
        
        private init() {
            MemoryPressureManager.shared.register(minLevel: .warning) { level in
                switch level {
                case .warning:
                    Task(priority: .high) {
                        if let latestModelCode = await self.latestUsedModelCode() {
                            FreeToken.shared.logger("🟠 Memory state is warning. Unloading all non-default model managers except the latest used one: \(latestModelCode).", .warning)
                            await self.unloadAllModels(except: latestModelCode)
                        }
                    }
                case .critical:
                    Task(priority: .high) {
                        FreeToken.shared.logger("🔴 Memory state is critical. Unloading all model managers and removing from memory.", .warning)
                        await self.unloadAllModels()
                        
                        var removeIndex: [Int] = []
                        for (i, wrapper) in self.aiModelManagers.enumerated() {
                            if !wrapper.isDefault {
                                removeIndex.append(i)
                            }
                        }
                        
                        for index in removeIndex.reversed() {
                            self.aiModelManagers.remove(at: index)
                        }
                    }
                default:
                    // No action needed for .normal
                    FreeToken.shared.logger("🟢 Memory state is normal. No action needed.", .info)
                }
            }
        }
        
        func addManager(modelConfig: Codings.AiModelResponse, clientVersion: String, isDefault: Bool) throws -> AIModelManager {
            if isDefault == true, defaultManager != nil {
                throw FreeTokenError.cannotInitializeSecondDefaultAIModel
            }
            
            let modelAlreadyExists = aiModelManagers.contains(where: { $0.modelCode == modelConfig.code })
            
            guard !modelAlreadyExists else {
                throw FreeTokenError.modelManagerAlreadyInitialized(code: modelConfig.code)
            }
            
            let initOptions = AIModelInitializeOptions(
                modelConfig: modelConfig,
                clientVersion: clientVersion
            )
            
            let aiModelManager = AIModelManager(
                modelConfig: modelConfig,
                clientVersion: clientVersion
            )
            
            #if os(iOS)
            let memoryRequirement = modelConfig.clientsConfig["iOS"]!.requiredMemoryBytes
            #else
            let memoryRequirement = modelConfig.clientsConfig["macOS"]!.requiredMemoryBytes
            #endif
            
            let deviceManager = DeviceManager(memoryRequirement: memoryRequirement)
            
            let wrapper = AIModelManagerWrapper(
                aiModelManager: aiModelManager,
                modelCode: modelConfig.code,
                isDefault: isDefault,
                initializeOptions: initOptions,
                deviceManager: deviceManager
            )
            
            aiModelManagers.append(wrapper)
            
            return aiModelManager
        }
        
        func getManager(for modelCode: String) -> AIModelManager? {
            return aiModelManagers.first(where: { $0.modelCode == modelCode })?.aiModelManager
        }
        
        func getDeviceManager(for modelCode: String) -> DeviceManager? {
            return aiModelManagers.first(where: { $0.modelCode == modelCode })?.deviceManager
        }
        
        func reset() {
            aiModelManagers.removeAll()
        }
        
        func unloadAllModels(except modelCode: String? = nil) async {
            let modelCode = modelCode ?? defaultManager?.modelCode
            
            if let modelCode = modelCode {
                for wrapper in aiModelManagers {
                    if wrapper.modelCode != modelCode {
                        await wrapper.aiModelManager.unloadModel()
                    }
                }
            }
        }
        
        func unloadModel(modelCode: String) async {
            if let wrapper = aiModelManagers.first(where: { $0.modelCode == modelCode }) {
                await wrapper.aiModelManager.unloadModel()
            }
        }
        
        func getModelRepo(for modelCode: String) -> String? {
            guard let wrapper = aiModelManagers.first(where: { $0.modelCode == modelCode }) else {
                return nil
            }
            return wrapper.initializeOptions.modelConfig.modelTypes?.llamaCpp.repo
        }
        
        func getModelFiles(for modelCode: String) -> (repo: String, modelFileName: String?, mmprojFileName: String?)? {
            guard let wrapper = aiModelManagers.first(where: { $0.modelCode == modelCode }) else {
                return nil
            }
            guard let llamaCpp = wrapper.initializeOptions.modelConfig.modelTypes?.llamaCpp else {
                return nil
            }
            return (repo: llamaCpp.repo, modelFileName: llamaCpp.modelFileName, mmprojFileName: llamaCpp.mmproj)
        }
        
        func latestUsedModelCode() async -> String?  {
            // Sort the managers by last used date, descending
            var managers: [String: [ String: Any ]] = [:]
            
            for wrapper in aiModelManagers {
                if let lastUsed = await wrapper.aiModelManager.lastUsedAt() {
                    managers[wrapper.modelCode] = [
                        "manager": wrapper,
                        "lastUsed": lastUsed
                    ]
                }
            }
            
            let sortedManagers = managers.sorted { first, second in
                guard let firstDate = first.value["lastUsed"] as? Date,
                      let secondDate = second.value["lastUsed"] as? Date else {
                    return false
                }
                return firstDate > secondDate
            }
            
            if let latest = sortedManagers.first,
               let latestManager = latest.value["manager"] as? AIModelManagerWrapper {
                // Unload all other models except the latest used one
                
                // Optionally, you can also load the latest model if needed
                // await latestManager.loadModel()
                return latestManager.modelCode
            } else {
                return nil
            }
        }
        
    }
}
