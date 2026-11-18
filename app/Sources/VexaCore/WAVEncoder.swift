import Foundation

/// Encodes mono Float32 samples as a 16-bit PCM WAV file (what Whisper is sent, and what
/// "Keep the audio" saves).
public enum WAVEncoder {
    /// The 44-byte RIFF/WAVE header for `dataByteCount` bytes of 16-bit PCM.
    public static func header(dataByteCount: Int, sampleRate: Int, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        var d = Data(capacity: 44)
        d.append(contentsOf: Array("RIFF".utf8))
        d.appendLE(UInt32(clamping: 36 + dataByteCount))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.appendLE(UInt32(16))                       // fmt chunk size
        d.appendLE(UInt16(1))                        // PCM
        d.appendLE(UInt16(channels))
        d.appendLE(UInt32(sampleRate))
        d.appendLE(UInt32(sampleRate * blockAlign))  // byte rate
        d.appendLE(UInt16(blockAlign))
        d.appendLE(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8))
        d.appendLE(UInt32(clamping: dataByteCount))
        return d
    }

    /// Little-endian 16-bit samples; values outside -1...1 are clipped.
    public static func pcm16(_ samples: [Float]) -> Data {
        var out = Data(count: samples.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                let clipped = s.isNaN ? 0 : min(1, max(-1, s))
                p[i] = Int16(clipped * 32767).littleEndian
            }
        }
        return out
    }

    /// A complete WAV file.
    public static func encode(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        header(dataByteCount: samples.count * 2, sampleRate: sampleRate) + pcm16(samples)
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
