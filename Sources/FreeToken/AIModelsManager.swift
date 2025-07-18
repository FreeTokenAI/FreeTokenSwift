//
//  AIModelsManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 7/15/25.
//

extension FreeToken {
    class AIModelsManager {
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
        
        func unloadAllOtherModels(except modelCode: String) async {
            for wrapper in aiModelManagers {
                if wrapper.modelCode != modelCode {
                    await wrapper.aiModelManager.unloadModel()
                }
            }
        }
        
    }
}
