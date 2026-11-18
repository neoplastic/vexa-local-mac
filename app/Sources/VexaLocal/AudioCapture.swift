import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

// Audio capture for the local recorder. Both sources end up as 16 kHz mono Float32.

/// Mixes any PCM buffer down to mono and resamples it to 16 kHz.
final class MonoResampler {
    static let targetRate: Double = 16_000

    private var converter: AVAudioConverter?
    private var converterRate: Double = 0
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MonoResampler.targetRate,
                                             channels: 1, interleaved: false)!

    func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let mono = Self.downmix(buffer)
        let rate = buffer.format.sampleRate
        guard !mono.isEmpty, rate > 0 else { return [] }
        if rate == Self.targetRate { return mono }

        if converter == nil || converterRate != rate {
            guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            else { return [] }
            converter = AVAudioConverter(from: source, to: targetFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converterRate = rate
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(mono.count))
        else { return [] }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: mono.count)
        }
        let capacity = AVAudioFrameCount(Double(mono.count) * Self.targetRate / rate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// Averages all channels. Handles float32, int16 and int32, interleaved or not.
    static func downmix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        var out = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)

        func mix(_ read: (Int, Int) -> Float) {
            for c in 0..<channels {
                for i in 0..<frames { out[i] += read(c, i) * scale }
            }
        }
        if let data = buffer.floatChannelData {
            mix { c, i in interleaved ? data[0][i * stride + c] : data[c][i] }
        } else if let data = buffer.int16ChannelData {
            mix { c, i in Float(interleaved ? data[0][i * stride + c] : data[c][i]) / 32768 }
        } else if let data = buffer.int32ChannelData {
            mix { c, i in Float(interleaved ? data[0][i * stride + c] : data[c][i]) / 2_147_483_648 }
        } else {
            return []
        }
        return out
    }
}

/// An input device (microphone) the user can pick.
struct AudioInputDevice: Identifiable, Hashable {
    /// Core Audio's device UID (stable across restarts).
    var id: String
    var name: String
}

enum AudioInputDevices {
    static func list() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioInputDevice(id: uid, name: stringProperty(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

struct CaptureError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The microphone, through AVAudioEngine. `onSamples` runs on the audio thread.
final class MicrophoneCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let resampler = MonoResampler()
    private var deviceUID: String?
    private var onSamples: (([Float]) -> Void)?
    private var observer: NSObjectProtocol?
    /// Called (on the main queue) if the microphone stops and can't be restarted.
    var onFailure: ((String) -> Void)?

    func start(deviceUID: String?, onSamples: @escaping ([Float]) -> Void) throws {
        self.deviceUID = deviceUID
        self.onSamples = onSamples
        try startEngine()
        // Plugging in headphones or switching the default input reconfigures the engine and
        // stops it; start it again on the new configuration.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil,
                                                          queue: .main) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            do { try self.startEngine() } catch { self.onFailure?("The microphone stopped: \(error.localizedDescription)") }
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        if let uid = deviceUID, !uid.isEmpty {
            guard var device = AudioInputDevices.deviceID(forUID: uid) else {
                throw CaptureError(message: "The chosen microphone is not connected. Pick another one or use the system default.")
            }
            guard let unit = input.audioUnit else { throw CaptureError(message: "Could not open the microphone.") }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw CaptureError(message: "Could not switch to the chosen microphone (\(status)).") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError(message: "No microphone found.")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.resampler.process(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError(message: "Could not start the microphone: \(error.localizedDescription)")
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onSamples = nil
    }
}

/// What the Mac plays (the other people in a call), through ScreenCaptureKit, audio only.
/// `onSamples` runs on a private queue.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "vexa.recorder.system-audio")
    private let videoQueue = DispatchQueue(label: "vexa.recorder.system-video")
    private let resampler = MonoResampler()
    private var onSamples: (([Float]) -> Void)?
    /// Called (on the main queue) if capture stops by itself.
    var onFailure: ((String) -> Void)?

    /// Throws when Screen & System Audio Recording permission is missing. The first call
    /// makes macOS ask for it.
    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    func start(onSamples: @escaping ([Float]) -> Void) async throws {
        self.onSamples = onSamples
        let content = try await Self.shareableContent()
        guard let display = content.displays.first else { throw CaptureError(message: "No display found to capture audio from.") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video can't be turned off; make it as small and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        // Without a screen output ScreenCaptureKit logs an error for every dropped frame.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        audioQueue.sync { onSamples = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcmBuffer(sampleBuffer) else { return }
        let samples = resampler.process(buffer)
        if !samples.isEmpty { onSamples?(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = "System audio capture stopped: \(error.localizedDescription)"
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }

    static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// Microphone and Screen Recording permission checks.
enum RecorderPermissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Asks if not asked yet; true when allowed.
    static func requestMicrophone() async -> Bool {
        switch microphone {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// System Settings › Privacy & Security › Screen & System Audio Recording.
    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
