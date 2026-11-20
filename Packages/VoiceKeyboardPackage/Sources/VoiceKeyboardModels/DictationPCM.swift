import Foundation

/// A bounded mono recording containing signed little-endian 16-bit samples.
public struct DictationPCM: Sendable {
    public static let sampleRate = 16_000
    public static let maximumDuration = 60
    private static let maximumSampleCount = sampleRate * maximumDuration
    private static let maximumChunkBytes = 8_192

    private var samples: [Int16] = []

    public init() {}

    public var sampleCount: Int { samples.count }
    public var isFull: Bool { sampleCount == Self.maximumSampleCount }

    @discardableResult
    public mutating func append(base64: String) -> Bool {
        guard !isFull,
              base64.utf8.count <= ((Self.maximumChunkBytes + 2) / 3) * 4,
              let bytes = Data(base64Encoded: base64),
              !bytes.isEmpty,
              bytes.count <= Self.maximumChunkBytes,
              bytes.count.isMultiple(of: 2) else { return false }

        let count = min(bytes.count / 2, Self.maximumSampleCount - sampleCount)
        bytes.withUnsafeBytes { bytes in
            for offset in 0..<count {
                let value = bytes.loadUnaligned(fromByteOffset: offset * 2, as: UInt16.self)
                samples.append(Int16(bitPattern: UInt16(littleEndian: value)))
            }
        }
        return true
    }

    public func normalizedSamples() -> [Float] {
        let peak = samples.reduce(0) { max($0, abs(Int($1))) }
        guard peak > 0 else { return Array(repeating: 0, count: sampleCount) }
        let scale = min(Float(4) / 32_768, 0.9 / Float(peak))
        return samples.map { Float($0) * scale }
    }
}
