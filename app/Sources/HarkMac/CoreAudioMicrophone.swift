import AudioToolbox
import AudioUnit
import AVFoundation
import CoreAudio
import Foundation
import HarkCore

public enum MicrophoneError: Error, CustomStringConvertible {
    case audioStatus(String, OSStatus)
    case deviceNotFound(String)
    case noInputDevice
    case firstBufferTimeout
    case notRecording

    public var description: String {
        switch self {
        case let .audioStatus(operation, status): "\(operation) failed with Core Audio status \(status)"
        case let .deviceNotFound(name): "input device not found: \(name)"
        case .noInputDevice: "no input audio device found"
        case .firstBufferTimeout: "timed out waiting for the first microphone buffer"
        case .notRecording: "the microphone is not recording"
        }
    }
}

/// The Mac's mic through a Core Audio HAL input unit (AUHAL).
///
/// The unit is created and initialized ahead of time but not started, so the
/// mic stays off (no orange dot) and a key press only has to start the
/// hardware. It asks for a 64-frame buffer, so the first buffer comes about
/// 1.3 ms after the hardware starts instead of 10.7 ms (issue #24).
///
/// It picks the mic by name, then the built-in mic, and never an iPhone
/// (Continuity) mic, which often comes first in the device list. When devices
/// come or go, it chooses again between dictations.
public final class CoreAudioMicrophone: Microphone, @unchecked Sendable {
    // Read and written only on `queue`.
    private var deviceName: String?
    private let queue = DispatchQueue(label: "works.hark.microphone", qos: .userInteractive)
    // Read and written only on `queue`.
    private var unit: InputUnit?
    private var recording = false
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// - Parameter deviceName: an exact input device name, or nil for the built-in mic.
    public init(deviceName: String? = nil) {
        self.deviceName = deviceName
    }

    deinit {
        if let deviceListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
        }
    }

    /// The name of the device the mic uses now, or nil before `prepare`.
    public var deviceInUse: String? {
        queue.sync { unit?.device.name }
    }

    /// The names of the mics the user can choose. iPhone (Continuity) mics are left out.
    public static func choices() -> [String] {
        ((try? inputDevices()) ?? []).filter { !continuity.contains($0.transport) }.map(\.name)
    }

    /// Uses this mic from the next dictation on; nil goes back to the built-in mic.
    public func choose(_ name: String?) async {
        _ = try? await onQueue { [self] in
            deviceName = name
            if !recording { try prepareUnit() }
        }
    }

    public func prepare() async throws {
        try await onQueue {
            self.watchDevices()
            if !self.recording { try self.prepareUnit() }
        }
    }

    public func start(_ handler: MicrophoneHandler) async throws {
        try await onQueue { [self] in
            if unit == nil { try prepareUnit() }
            do {
                // A lost device is dropped, so the next start chooses again.
                try unit!.start(handler: handler) { [weak self] in self?.dropUnit() }
            } catch {
                unit = nil
                throw error
            }
            recording = true
        }
    }

    public func stop() async throws -> Samples {
        try await onQueue {
            guard let unit = self.unit, self.recording else { throw MicrophoneError.notRecording }
            self.recording = false
            let (samples, rate) = try unit.stop()
            return resample(samples, from: rate)
        }
    }

    private func dropUnit() {
        queue.async {
            self.unit = nil
            self.recording = false
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func prepareUnit() throws {
        let device = try selectInputDevice(requestedName: deviceName)
        if let unit, unit.device.id == device.id { return }
        unit = try InputUnit(device: device)
    }

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func watchDevices() {
        guard deviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Already on `queue`. Choose again between dictations only.
            guard let self, !self.recording else { return }
            try? self.prepareUnit()
        }
        var address = Self.devicesAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            deviceListener = listener
        }
    }
}

// MARK: - Devices

struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw MicrophoneError.audioStatus(operation, status) }
}

private func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func inputDevices() throws -> [AudioDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let system = AudioObjectID(kAudioObjectSystemObject)
    var byteCount: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount), "list audio devices")
    var ids = [AudioDeviceID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size)
    try check(AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, &ids), "read audio devices")

    return ids.compactMap { id in
        var streams = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioStreamID>.size,
              let name = property(id, kAudioObjectPropertyName, Unmanaged<CFString>?.none)??.takeRetainedValue()
        else { return nil }
        let transport = property(id, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0
        return AudioDevice(id: id, name: name as String, transport: transport)
    }
}

let continuity: Set<UInt32> = [kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless]

/// The requested mic when it is connected, else the built-in mic, else the
/// system's default input, and never an iPhone unless it is all there is.
func selectInputDevice(requestedName: String?) throws -> AudioDevice {
    let devices = try inputDevices()
    // A chosen mic that is unplugged falls back to the built-in one, so dictation keeps working.
    if let requestedName, let requested = devices.first(where: { $0.name == requestedName }) {
        return requested
    }
    let usable = devices.filter { !continuity.contains($0.transport) }
    if let builtIn = usable.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn }) { return builtIn }
    let defaultID = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioDeviceID(0))
    if let chosen = usable.first(where: { $0.id == defaultID }) { return chosen }
    guard let first = usable.first ?? devices.first else { throw MicrophoneError.noInputDevice }
    return first
}

func deviceIsRunning(_ device: AudioDevice) -> Bool {
    (property(device.id, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) ?? 0) != 0
}

// MARK: - Input unit

/// Asked of the device: 64 frames, or the smallest size it allows above that.
private let preferredBufferFrames: UInt32 = 64

private let inputCallback: AURenderCallback = { refCon, flags, timestamp, _, frames, _ in
    Unmanaged<InputUnit>.fromOpaque(refCon).takeUnretainedValue().receive(flags: flags, timestamp: timestamp, frames: frames)
}

/// One initialized AUHAL unit on one device. Records mono Float32 at the
/// device's rate.
private final class InputUnit: @unchecked Sendable {
    let device: AudioDevice
    private let audioUnit: AudioUnit
    private let sampleRate: Double
    private let maximumFrames: UInt32
    private let renderStorage: UnsafeMutablePointer<Float>
    private let renderBuffers: UnsafeMutableAudioBufferListPointer
    private let lock = NSLock()

    // Guarded by `lock`; written by the audio thread while recording.
    private var recording = false
    private var recorded: [Float] = []
    private var levelSquares: Float = 0
    private var levelCount = 0
    private var firstBuffer: DispatchSemaphore?

    private var levelTimer: DispatchSourceTimer?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var deviceWasRunning = false

    init(device: AudioDevice) throws {
        self.device = device
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw MicrophoneError.noInputDevice }
        var instance: AudioComponentInstance?
        try check(AudioComponentInstanceNew(component, &instance), "create HAL input unit")
        guard let instance else { throw MicrophoneError.noInputDevice }
        audioUnit = instance

        let audioUnit = instance
        func set<T: BitwiseCopyable>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement,
                                     _ value: T, _ operation: String) throws {
            var value = value
            try check(AudioUnitSetProperty(audioUnit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)), operation)
        }

        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "enable HAL input")
        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "disable HAL output")
        try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id, "select input device")

        var frames = preferredBufferFrames
        if let range = property(device.id, kAudioDevicePropertyBufferFrameSizeRange, AudioValueRange()) {
            frames = UInt32(max(range.mMinimum, min(range.mMaximum, Double(frames))))
        }
        try? set(kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, frames, "set buffer size")

        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &formatSize),
            "read input format"
        )
        sampleRate = deviceFormat.mSampleRate
        let clientFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, clientFormat, "set mono float input format")

        var sliceFrames: UInt32 = 0
        var sliceSize = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioUnitGetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &sliceFrames, &sliceSize),
            "read maximum input slice"
        )
        maximumFrames = max(4096, sliceFrames)
        renderStorage = .allocate(capacity: Int(maximumFrames))
        renderBuffers = AudioBufferList.allocate(maximumBuffers: 1)
        renderBuffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: maximumFrames * 4, mData: renderStorage)

        var callback = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(
            AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                 &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "set input callback"
        )
        try check(AudioUnitInitialize(audioUnit), "initialize HAL input")
    }

    deinit {
        stopLevelTimer()
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        renderBuffers.unsafeMutablePointer.deallocate()
        renderStorage.deallocate()
    }

    func receive(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>,
                 frames: UInt32) -> OSStatus {
        guard frames <= maximumFrames else { return kAudio_ParamError }
        renderBuffers[0].mDataByteSize = frames * 4
        let status = AudioUnitRender(audioUnit, flags, timestamp, 1, frames, renderBuffers.unsafeMutablePointer)
        guard status == noErr else { return status }
        let samples = UnsafeBufferPointer(start: renderStorage, count: Int(frames))
        lock.lock()
        if recording {
            recorded.append(contentsOf: samples)
            for sample in samples { levelSquares += sample * sample }
            levelCount += samples.count
        }
        let waiter = firstBuffer
        firstBuffer = nil
        lock.unlock()
        waiter?.signal()
        return noErr
    }

    /// Starts the hardware and returns after the first buffer.
    func start(handler: MicrophoneHandler, onDeviceLost: @escaping @Sendable () -> Void) throws {
        deviceWasRunning = deviceIsRunning(device)
        let waiter = DispatchSemaphore(value: 0)
        lock.withLock {
            recorded = []
            recorded.reserveCapacity(Int(sampleRate) * 60)
            levelSquares = 0
            levelCount = 0
            recording = true
            firstBuffer = waiter
        }
        do {
            try check(AudioOutputUnitStart(audioUnit), "start HAL input")
            guard waiter.wait(timeout: .now() + 3) == .success else { throw MicrophoneError.firstBufferTimeout }
        } catch {
            AudioOutputUnitStop(audioUnit)
            lock.withLock {
                recording = false
                firstBuffer = nil
            }
            throw error
        }
        watchAlive(handler: handler, onDeviceLost: onDeviceLost)
        startLevelTimer(handler: handler)
    }

    /// Stops the hardware, waits until the mic is off, and returns the recording.
    func stop() throws -> ([Float], Double) {
        stopLevelTimer()
        unwatchAlive()
        lock.withLock { recording = false }
        try check(AudioOutputUnitStop(audioUnit), "stop HAL input")
        if !deviceWasRunning {
            // The orange dot goes out a few milliseconds after the stop. Wait, so
            // the mic is off before Whisper takes the CPU and GPU.
            let deadline = DispatchTime.now() + .milliseconds(250)
            while deviceIsRunning(device) && DispatchTime.now() < deadline { usleep(1_000) }
        }
        let samples = lock.withLock { () -> [Float] in
            defer { recorded = [] }
            return recorded
        }
        return (samples, sampleRate)
    }

    private func startLevelTimer(handler: MicrophoneHandler) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let (squares, count) = self.lock.withLock { () -> (Float, Int) in
                defer { self.levelSquares = 0; self.levelCount = 0 }
                return (self.levelSquares, self.levelCount)
            }
            guard count > 0 else { return }
            handler.level((squares / Float(count)).squareRoot())
        }
        levelTimer = timer
        timer.resume()
    }

    private func stopLevelTimer() {
        levelTimer?.cancel()
        levelTimer = nil
    }

    private var aliveAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func watchAlive(handler: MicrophoneHandler, onDeviceLost: @escaping @Sendable () -> Void) {
        let device = device
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            guard (property(device.id, kAudioDevicePropertyDeviceIsAlive, UInt32(1)) ?? 0) == 0 else { return }
            onDeviceLost()
            handler.failure(MicrophoneError.deviceNotFound(device.name))
        }
        if AudioObjectAddPropertyListenerBlock(device.id, &aliveAddress, .global(), listener) == noErr {
            aliveListener = listener
        }
    }

    private func unwatchAlive() {
        guard let aliveListener else { return }
        AudioObjectRemovePropertyListenerBlock(device.id, &aliveAddress, .global(), aliveListener)
        self.aliveListener = nil
    }
}

// MARK: - Resampling

/// Converts mono audio to Whisper's 16 kHz.
public func resample(_ samples: [Float], from rate: Double) -> Samples {
    let target = Double(whisperSampleRate)
    guard rate != target, !samples.isEmpty,
          let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
          let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: input, to: output),
          let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count))
    else { return samples }
    converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    source.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

    let capacity = AVAudioFrameCount((Double(samples.count) * target / rate).rounded(.up)) + 1024
    guard let destination = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return samples }
    nonisolated(unsafe) var supplied = false
    var error: NSError?
    converter.convert(to: destination, error: &error) { _, status in
        if supplied {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return source
    }
    guard error == nil else { return samples }
    return Array(UnsafeBufferPointer(start: destination.floatChannelData![0], count: Int(destination.frameLength)))
}
