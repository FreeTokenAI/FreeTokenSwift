//
//  ToolDefinitionsManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 7/20/25.
//

import Foundation

extension FreeToken {
    
    actor ToolDefinitionsManager {
        private var builtInDefinitions: [ToolDefinition] = []
        private var cloudDefinitions: [ToolDefinition] = []
        private var applicationDefinitions: [ToolDefinition] = []
        private var toolInstructions: String = ""
        
        func setToolInstructions(_ instructions: String) {
            toolInstructions = instructions
        }
        
        func getToolInstructions() -> String {
            return toolInstructions
        }
        
        func addToolDefinitions(_ definitions: [ToolDefinition], type: ToolDefinitionType) {
            for definition in definitions {
                addToolDefinition(definition, type: type)
            }
        }
        
        func addToolDefinition(_ definition: ToolDefinition, type: ToolDefinitionType) {
            switch type {
            case .builtIn:
                // Remove any existing definition with the same name
                builtInDefinitions.removeAll(where: { $0.name == definition.name })
                builtInDefinitions.append(definition)
            case .cloud:
                // Remove any existing definition with the same name
                cloudDefinitions.removeAll(where: { $0.name == definition.name })
                cloudDefinitions.append(definition)
            case .application:
                // Remove any existing definition with the same name
                applicationDefinitions.removeAll(where: { $0.name == definition.name })
                applicationDefinitions.append(definition)
            }
        }
        
        func getToolDefinitions(for type: ToolDefinitionType) -> [ToolDefinition] {
            switch type {
            case .builtIn:
                return builtInDefinitions
            case .cloud:
                return cloudDefinitions
            case .application:
                return applicationDefinitions
            }
        }
        
        func getToolDefinition(for name: String, type: ToolDefinitionType) -> ToolDefinition? {
            switch type {
            case .builtIn:
                return builtInDefinitions.first(where: { $0.name == name })
            case .cloud:
                return cloudDefinitions.first(where: { $0.name == name })
            case .application:
                return applicationDefinitions.first(where: { $0.name == name })
            }
        }
        
        func getToolDefinition(for name: String) -> ToolDefinition? {
            return allToolDefinitions().first(where: { $0.name == name })
        }
        
        func allToolDefinitions() -> [ToolDefinition] {
            return builtInDefinitions + cloudDefinitions + applicationDefinitions
        }
        
        func getToolNames(for type: ToolDefinitionType? = nil) -> [String] {
            if let type = type {
                switch type {
                case .builtIn:
                    return builtInDefinitions.map { $0.name }
                case .cloud:
                    return cloudDefinitions.map { $0.name }
                case .application:
                    return applicationDefinitions.map { $0.name }
                }
            } else {
                return allToolDefinitions().map { $0.name }
            }
        }
        
        func removeToolDefinition(for name: String, type: ToolDefinitionType) {
            switch type {
            case .builtIn:
                builtInDefinitions.removeAll(where: { $0.name == name })
            case .cloud:
                cloudDefinitions.removeAll(where: { $0.name == name })
            case .application:
                applicationDefinitions.removeAll(where: { $0.name == name })
            }
        }
        
        func removeAllToolDefinitions() {
            builtInDefinitions.removeAll()
            cloudDefinitions.removeAll()
            applicationDefinitions.removeAll()
        }
        
        func processToolMask(_ masks: [ToolRunMask], toolDefinitions: [ToolDefinition]? = nil) -> [ToolDefinition] {
            var definitions: [ToolDefinition]
            
            if let toolDefinitions = toolDefinitions {
                definitions = toolDefinitions
            } else {
                definitions = allToolDefinitions()
            }
            
            for mask in masks {
                switch mask {
                case .denyAll:
                    definitions.removeAll()
                case .allow(let name):
                    if definitions.first(where: { $0.name == name }) == nil {
                        let definition = self.getToolDefinition(for: name)
                        if let definition = definition {
                            definitions.append(definition)
                        } else {
                            FreeToken.shared.logger("⚠️ Explicit allow of tool definition \(name) - tool by that name was not found", .warning)
                        }
                    }
                case .deny(let name):
                    definitions.removeAll(where: { $0.name == name })
                case .allowAll:
                    definitions = self.allToolDefinitions()
                }
            }
            
            return definitions
        }
    }
    
}
