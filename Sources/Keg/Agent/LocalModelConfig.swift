import Foundation

/// Configuration for local model inference via llama.cpp HTTP server
public struct LocalModelConfig: Codable, Sendable, Equatable, Hashable {
    /// Path to the GGUF model file
    public var modelPath: String

    /// Quantization level (e.g., "Q4_K_M", "Q8_0", "F16")
    public var quantization: String

    /// Port for the llama.cpp HTTP server
    public var port: Int

    /// Display name for the model
    public var modelName: String

    /// Context window size in tokens
    public var contextSize: Int

    /// Number of GPU layers (-1 = all)
    public var gpuLayers: Int

    /// Number of threads (0 = auto)
    public var threads: Int

    /// Batch size for prompt processing
    public var batchSize: Int

    /// Enable flash attention
    public var flashAttention: Bool

    /// Maximum concurrent requests
    public var maxConcurrentRequests: Int

    public init(
        modelPath: String,
        quantization: String = "Q4_K_M",
        port: Int = 8080,
        modelName: String? = nil,
        contextSize: Int = 4096,
        gpuLayers: Int = -1,
        threads: Int = 0,
        batchSize: Int = 512,
        flashAttention: Bool = true,
        maxConcurrentRequests: Int = 4
    ) {
        self.modelPath = modelPath
        self.quantization = quantization
        self.port = port
        self.modelName = modelName ?? URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
        self.threads = threads
        self.batchSize = batchSize
        self.flashAttention = flashAttention
        self.maxConcurrentRequests = maxConcurrentRequests
    }

    /// Default llama.cpp server URL
    public var serverURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// API base URL for completions
    public var apiBaseURL: URL {
        serverURL.appendingPathComponent("v1")
    }

    /// Well-known quantization presets
    public static let quantizationPresets: [String] = [
        "F16",
        "Q8_0",
        "Q6_K",
        "Q5_K_M",
        "Q5_K_S",
        "Q4_K_M",
        "Q4_K_S",
        "Q4_0",
        "Q3_K_M",
        "Q2_K"
    ]

    /// Common context sizes
    public static let contextSizePresets: [Int] = [2048, 4096, 8192, 16384, 32768]
}

// MARK: - Validation

extension LocalModelConfig {
    public var isValid: Bool {
        !modelPath.isEmpty &&
        FileManager.default.fileExists(atPath: modelPath) &&
        (1024...65535).contains(port) &&
        contextSize > 0 &&
        maxConcurrentRequests > 0
    }

    public var validationErrors: [String] {
        var errors: [String] = []
        if modelPath.isEmpty {
            errors.append("Model path is required")
        } else if !FileManager.default.fileExists(atPath: modelPath) {
            errors.append("Model file not found at path")
        }
        if !(1024...65535).contains(port) {
            errors.append("Port must be between 1024 and 65535")
        }
        if contextSize <= 0 {
            errors.append("Context size must be positive")
        }
        if maxConcurrentRequests <= 0 {
            errors.append("Max concurrent requests must be positive")
        }
        return errors
    }
}

// MARK: - Default Configurations

extension LocalModelConfig {
    /// Default configuration for a small model (e.g., 3B params)
    public static func smallModel(modelPath: String, port: Int = 8080) -> LocalModelConfig {
        LocalModelConfig(
            modelPath: modelPath,
            quantization: "Q4_K_M",
            port: port,
            contextSize: 2048,
            gpuLayers: -1,
            threads: 4,
            batchSize: 256,
            flashAttention: true,
            maxConcurrentRequests: 2
        )
    }

    /// Default configuration for a medium model (e.g., 7B params)
    public static func mediumModel(modelPath: String, port: Int = 8080) -> LocalModelConfig {
        LocalModelConfig(
            modelPath: modelPath,
            quantization: "Q4_K_M",
            port: port,
            contextSize: 4096,
            gpuLayers: -1,
            threads: 8,
            batchSize: 512,
            flashAttention: true,
            maxConcurrentRequests: 4
        )
    }

    /// Default configuration for a large model (e.g., 13B+ params)
    public static func largeModel(modelPath: String, port: Int = 8080) -> LocalModelConfig {
        LocalModelConfig(
            modelPath: modelPath,
            quantization: "Q6_K",
            port: port,
            contextSize: 4096,
            gpuLayers: -1,
            threads: 12,
            batchSize: 512,
            flashAttention: true,
            maxConcurrentRequests: 4
        )
    }
}
