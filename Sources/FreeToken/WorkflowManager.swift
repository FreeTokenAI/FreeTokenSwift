//
//  WorkflowManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 6/21/25.
//
import Foundation

extension FreeToken {

    final class WorkflowManager<Context: WorkflowContext>: Sendable {
        let workflowContext: any WorkflowContext
        let executionManager: ExecutionManager
        
        init(context: Context, steps: [WorkflowStep.Type]) {
            self.workflowContext = context
            self.executionManager = ExecutionManager(context: context, steps: steps)
        }
        
        actor ExecutionManager {
            var steps: [WorkflowStep.Type]
            var currentContext: any WorkflowContext
            var shouldContinueExecution = true
            
            init(context: any WorkflowContext, steps: [WorkflowStep.Type]) {
                self.currentContext = context
                self.steps = steps
            }
            
            func updateContext(_ newContext: any WorkflowContext) {
                currentContext = newContext
            }
            
            func getContext() -> any WorkflowContext {
                return currentContext
            }
            
            func shouldContinue() -> Bool {
                return shouldContinueExecution
            }
            
            func setShouldContinue(_ shouldContinue: Bool) {
                shouldContinueExecution = shouldContinue
            }
            
            func appendSteps(_ newSteps: [WorkflowStep.Type]) {
                steps.append(contentsOf: newSteps)
            }
        }
            
        
        func execute(
            success: @escaping @Sendable (_ context: WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: WorkflowContext) async -> Void
        ) async {
            let execManager = executionManager

            let steps = await execManager.steps
            for step in steps {
                let stepInstance = step.init(context: await execManager.getContext())
                let semaphore = DispatchSemaphore(value: 0)
                // If execute can be made to return a Result or throw, this becomes much simpler
                await stepInstance.execute(
                    success: { newContext in
                        await execManager.updateContext(newContext)
                        semaphore.signal()
                    },
                    failure: { error, failedContext in
                        await failure(error, failedContext)
                        await execManager.setShouldContinue(false)
                        semaphore.signal()
                    }
                )
                
                if await execManager.shouldContinue() == false {
                    return
                }
            }
            
            if await execManager.shouldContinue() == false {
                return
            }
                
            await success(await execManager.getContext())
        }
    }
    
    protocol WorkflowContext: Sendable {}
    
    protocol WorkflowStep: Sendable {
        init(context: any WorkflowContext)
        
        func execute(
            success: @escaping @Sendable (_ context: any WorkflowContext) async -> Void,
            failure: @escaping @Sendable (_ error: FreeTokenError, _ context: any WorkflowContext) async -> Void
        ) async -> Void
    }
    
}
