//
//  EmbeddingManager.swift
//  FreeToken
//
//  Created by Vince Francesi on 2/3/25.
//

import Foundation
import Tokenizers
import OnnxRuntimeBindings
import Gzip

extension FreeToken {
    
    class EmbeddingManager: @unchecked Sendable {
        static let shared = EmbeddingManager()
        
        static let embeddingFailedError = Codings.ErrorResponse(error: "embeddingFailed", message: "The embedding model failed on the device.", code: 3000)
        static let modelAlreadyDownloadingError = Codings.ErrorResponse(error: "modelDownloadingError", message: "The embedding model is downloading. Multiple download calls prohibited.", code: 3001)
        static let modelDownloadError = Codings.ErrorResponse(error: "modelDownloadError", message: "The embedding model failed to download.", code: 3002)
        static let unableToInitializeModel = Codings.ErrorResponse(error: "unableToInitializeModel", message: "The embedding model failed to initialize.", code: 3003)
        static let unableToGenerateEmbedding = Codings.ErrorResponse(error: "unableToGenerateEmbedding", message: "The embedding model failed to generate an embedding.", code: 3004)
        static let managerNotConfigured = Codings.ErrorResponse(error: "managerNotConfigured", message: "The embedding manager is not configured.", code: 3005)
        static let couldNotRemoveModelError = Codings.ErrorResponse(error: "couldNotRemoveModelError", message: "Failed to remove model with error: Failed to remove model directory.", code: 3006)
        
        enum ManagerState: Equatable {
            case unknown
            case configured
        }
        
        enum ModelState: Equatable {
            case unknown
            case downloading
            case downloaded
            case downloadInvalid
            case ready
        }
        
        struct Config {
            let modelName: String
            let modelPath: URL // Where the model is stored in the app cache directory
            let modelConfig: Codings.EmbeddingModelResponse
        }
        
        var config: Config? = nil
        var modelState: ModelState = .unknown
        var managerState: ManagerState = .unknown
        var embeddingModelName: String {
            get {
                return config?.modelName ?? ""
            }
        }
        
        func config(modelConfig: Codings.EmbeddingModelResponse) {
            let modelPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("FreeToken/EmbeddingModels/\(modelConfig.name)")
            
            self.config = Config(modelName: modelConfig.name, modelPath: modelPath, modelConfig: modelConfig)
            self.managerState = .configured
        }
        
        private init() {}

        // MARK: - Downloading
        
        func downloadModel(progress progressCompleted: Optional<@Sendable (_ percentage: Double) -> Void> = nil, successCallback: Optional<@Sendable () -> Void> = nil, failureCallback: Optional<@Sendable (FreeTokenError) -> Void> = nil) async {

            if modelState == .ready {
                FreeToken.shared.logger("Embedding model is already downloaded.", .info)
                successCallback?()
                return
            }
            
            if modelState == .downloading {
                FreeToken.shared.logger("Embedding model is already downloading.", .info)
                failureCallback?(FreeTokenError.convertErrorResponse(errorResponse: Self.modelAlreadyDownloadingError))
                return
            }
            
            if managerState != .configured {
                FreeToken.shared.logger("Embedding manager is not configured.", .error)
                failureCallback?(FreeTokenError.convertErrorResponse(errorResponse: Self.managerNotConfigured))
                return
            }
            let config = self.config!
            
            // If the model path doesn't exist, create it
            if !FileManager.default.fileExists(atPath: config.modelPath.path) {
                do {
                    try FileManager.default.createDirectory(at: config.modelPath, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    FreeToken.shared.logger("Error creating embedding model directory: \(error.localizedDescription)", .error)
                    return
                }
            }
            
            // If everything is downloaded already, just return 100% progress and return
            modelState = .downloading
            let downloadPipeline = DownloadPipelineManager(baseDirectory: config.modelPath, downloadFiles: config.modelConfig.files.toDownload, verifyFiles: config.modelConfig.files.toVerify, progressTracker: progressCompleted)
            
            do {
                let result = try await downloadPipeline.run()
                
                switch result {
                case .success:
                    progressCompleted?(1.0)
                    modelState = .ready
                    successCallback?()
                case .failure(let error):
                    modelState = .downloadInvalid
                    let errorDescription = error.localizedDescription
                    FreeToken.shared.logger("Error downloading embedding model files: \(errorDescription)", .error)
                    failureCallback?(FreeTokenError.convertErrorResponse(errorResponse: Self.modelDownloadError))
                }
            } catch {
                modelState = .downloadInvalid
                FreeToken.shared.logger("Error downloading embedding model files: \(error.localizedDescription)", .error)
                failureCallback?(FreeTokenError.convertErrorResponse(errorResponse: Self.modelDownloadError))
            }
        }
        
        func resetCache() throws {
            let fileManager = FileManager.default
            
            do {
                let modelStore = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("FreeToken/EmbeddingModels")
                try fileManager.removeItem(at: modelStore)
                modelState = .unknown
            } catch {
                FreeToken.shared.logger("Error removing embedding model directory: \(error.localizedDescription)", .error)
                throw FreeTokenError.convertErrorResponse(errorResponse: Self.couldNotRemoveModelError)
            }
        }

        
        private func initializeModel() -> EmbeddingModel? {
            if modelState != .ready {
                return nil
            }
            
            if managerState != .configured {
                return nil
            }
            
            let config = self.config!
            
            if config.modelName == "gist-embedding-v0" {
                return GistEmbeddingV0Model()
            } else {
                FreeToken.shared.logger("Tried to initialize model of unknown name: \(config.modelName)", .error)
                return nil
            }
        }
        
        func generate(text: String) throws -> [Float] {
            let model = initializeModel()
            if model == nil {
                throw FreeTokenError.convertErrorResponse(errorResponse: Self.unableToInitializeModel)
            }
            
            var result: [Float]
            
            do {
                result = try model!.generate(text: text)
            } catch {
                FreeToken.shared.logger("Error generating embedding: \(error.localizedDescription)", .error)
                throw FreeTokenError.convertErrorResponse(errorResponse: Self.unableToGenerateEmbedding)
            }

            return result
        }
        
        // MARK: - Model Class Definitions
        
        protocol EmbeddingModel {
            func generate(text: String) throws -> [Float]
        }
        
        class GistEmbeddingV0Model: EmbeddingModel, @unchecked Sendable {
            static let modelDoesNotExistAtPathError = Codings.ErrorResponse(error: "modelDoesNotExist", message: "The model does not exist at the specified path.", code: 7000)
            
            let name = "gist-embedding-v0"
            let maxTokens: Int = 512
            let hiddenSize: Int = 768
            let modelPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("FreeToken/EmbeddingModels/gist-embedding-v0")
            
            var _session: ORTSession? = nil
            var _tokenizer: Tokenizer? = nil
            
            func session() throws -> ORTSession {
                let fileManager = FileManager.default
                let env = try ORTEnv(loggingLevel: .warning)
                let fullPath = modelPath.appendingPathComponent("model.onnx").path
                
                if fileManager.fileExists(atPath: fullPath) {
                    _session = try ORTSession(env: env, modelPath: fullPath, sessionOptions: nil)
                } else {
                    throw Self.modelDoesNotExistAtPathError
                }
                
                return _session!
            }
            
            func tokenizer(encode text: String) throws -> [Int] {
                if _tokenizer == nil {
                    let semaphore = DispatchSemaphore(value: 0)
                    Task {
                        self._tokenizer = try await AutoTokenizer.from(modelFolder: modelPath)
                        semaphore.signal()
                    }
                    
                    semaphore.wait()
                }
                
                return _tokenizer!.encode(text: text, addSpecialTokens: true)
            }
            
            public func generate(text: String) throws -> [Float] {
                // 1. Tokenize the input text
                let tokenized = try tokenizer(encode: text)

                // 2. Define the maximum token limit
                let maxTokens = self.maxTokens

                // 3. Initialize an array to hold embeddings for each chunk
                var chunkEmbeddings = [[Float]]()

                // 4. Split tokenized text into chunks of maxTokens size
                for chunkStart in stride(from: 0, to: tokenized.count, by: maxTokens) {
                    let chunkEnd = min(chunkStart + maxTokens, tokenized.count)
                    let tokenChunk = Array(tokenized[chunkStart..<chunkEnd])

                    // 5. Create input_ids and attention_mask for the chunk
                    let inputIds: [Int64] = tokenChunk.map { Int64($0) }
                    let attentionMask: [Int64] = Array(repeating: 1, count: inputIds.count)

                    // 6. Convert input_ids and attention_mask to NSData
                    let inputIdsData = NSMutableData(length: inputIds.count * MemoryLayout<Int64>.size)!
                    inputIds.withUnsafeBufferPointer { buffer in
                        inputIdsData.replaceBytes(
                            in: NSRange(location: 0, length: inputIdsData.length),
                            withBytes: buffer.baseAddress!
                        )
                    }

                    let attentionMaskData = NSMutableData(length: attentionMask.count * MemoryLayout<Int64>.size)!
                    attentionMask.withUnsafeBufferPointer { buffer in
                        attentionMaskData.replaceBytes(
                            in: NSRange(location: 0, length: attentionMaskData.length),
                            withBytes: buffer.baseAddress!
                        )
                    }

                    // 7. Create the ORT environment and session
                    let session = try session()

                    // 8. Create ORTValues for input_ids and attention_mask
                    let shape: [NSNumber] = [1, NSNumber(value: inputIds.count)]
                    let inputIdsTensor = try ORTValue(
                        tensorData: inputIdsData,
                        elementType: .int64,
                        shape: shape
                    )
                    let attentionMaskTensor = try ORTValue(
                        tensorData: attentionMaskData,
                        elementType: .int64,
                        shape: shape
                    )

                    // 9. Gather the two inputs into a dictionary
                    let inputsDict: [String: ORTValue] = [
                        "input_ids": inputIdsTensor,
                        "attention_mask": attentionMaskTensor
                    ]

                    // 10. Run inference
                    let allOutputNames = try session.outputNames()
                    let outputNameSet = Set(allOutputNames)

                    let outputs = try session.run(
                        withInputs: inputsDict,
                        outputNames: outputNameSet,
                        runOptions: nil
                    )

                    // 11. Retrieve the first output
                    guard
                        let firstOutputName = allOutputNames.first,
                        let outputValue = outputs[firstOutputName]
                    else {
                        throw NSError(domain: "EmbeddingModel", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "No output found in inference result"])
                    }

                    // 12. Convert the tensor data into [Float]
                    let outputData = try outputValue.tensorData()
                    let floatCount = outputData.count / MemoryLayout<Float>.size
                    var floatArray = [Float](repeating: 0, count: floatCount)
                    _ = floatArray.withUnsafeMutableBytes { ptr in
                        outputData.copyBytes(to: ptr, count: outputData.count)
                    }

                    // 13. Reshape the output to [sequence_length, hidden_size]
                    let sequenceLength = inputIds.count
                    let hiddenSize = self.hiddenSize
                    var embeddings = [[Float]]()
                    for i in 0..<sequenceLength {
                        let start = i * hiddenSize
                        let end = start + hiddenSize
                        let embedding = Array(floatArray[start..<end])
                        embeddings.append(embedding)
                    }

                    // 14. Apply mean pooling to get a single embedding of size [hidden_size] for the chunk
                    var pooledEmbedding = [Float](repeating: 0, count: hiddenSize)
                    for embedding in embeddings {
                        for j in 0..<hiddenSize {
                            pooledEmbedding[j] += embedding[j]
                        }
                    }
                    for j in 0..<hiddenSize {
                        pooledEmbedding[j] /= Float(sequenceLength)
                    }

                    // 15. Append the pooled embedding of the chunk to the list
                    chunkEmbeddings.append(pooledEmbedding)
                }

                // 16. Aggregate all chunk embeddings to form a single embedding for the entire text
                let numChunks = chunkEmbeddings.count
                var finalEmbedding = [Float](repeating: 0, count: hiddenSize)
                for embedding in chunkEmbeddings {
                    for j in 0..<hiddenSize {
                        finalEmbedding[j] += embedding[j]
                    }
                }
                for j in 0..<hiddenSize {
                    finalEmbedding[j] /= Float(numChunks)
                }

                // 17. Return the final aggregated embedding vector
                return finalEmbedding
            }
        }
    }
    
}
