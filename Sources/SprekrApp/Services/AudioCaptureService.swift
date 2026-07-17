import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

private final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLevel: Float = 0

    func update(_ level: Float) {
        lock.lock()
        let response: Float = level > storedLevel ? 0.64 : 0.22
        storedLevel += (level - storedLevel) * response
        lock.unlock()
    }

    func reset() {
        lock.lock()
        storedLevel = 0
        lock.unlock()
    }

    func read() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return storedLevel
    }
}

@MainActor
final class AudioCaptureService: NSObject, ObservableObject {
    /// Capture intentionally has no elapsed-time cutoff. Available local disk
    /// space and an explicit user stop are the only normal session boundaries.
    nonisolated static let maximumRecordingDuration: TimeInterval? = nil

    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0
    @Published private(set) var selectedDeviceName = "System Default"
    @Published private(set) var availableDevices: [AVCaptureDevice] = []

    var onCaptureFailure: ((String) -> Void)?
    var onAvailableInputsChange: (([AVCaptureDevice]) -> Void)?

    private let engine = AVAudioEngine()
    private let levelMeter = AudioLevelMeter()
    private var temporaryAudioURL: URL?
    private var configurationObserver: NSObjectProtocol?
    private var configurationChangeTask: Task<Void, Never>?
    private var deviceObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        removeStaleTemporaryAudio()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleUnexpectedConfigurationChange() }
        }
        refreshAvailableInputs()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(350))
                        self?.refreshAvailableInputs()
                    }
                }
            )
        }
    }

    func availableInputs() -> [AVCaptureDevice] {
        availableDevices
    }

    var systemDefaultInputName: String {
        systemDefaultDeviceName
    }

    func refreshAvailableInputs() {
        let devices = discoverAvailableInputs()
        availableDevices = devices
        onAvailableInputsChange?(devices)
    }

    private func discoverAvailableInputs() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func selectInput(named deviceUID: String?) {
        guard let deviceUID,
              let device = availableInputs().first(where: { $0.uniqueID == deviceUID }) else {
            selectedDeviceName = systemDefaultDeviceName
            return
        }
        selectedDeviceName = device.localizedName
    }

    func start(deviceUID: String?) throws {
        guard !isRecording else { return }
        levelMeter.reset()
        level = 0
        let input = engine.inputNode
        try configureInput(deviceUID: deviceUID, for: input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SprekrError.audioCaptureUnavailable
        }

        let directory = Self.temporaryAudioDirectory
        try PrivateFilePermissions.ensureDirectory(directory)
        let url = directory.appendingPathComponent("\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try PrivateFilePermissions.secureFile(url)

        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: Self.makeTapBlock(file: file, levelMeter: levelMeter)
        )

        do {
            engine.prepare()
            try engine.start()
            temporaryAudioURL = url
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() -> URL? {
        guard isRecording else { return nil }
        configurationChangeTask?.cancel()
        configurationChangeTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        levelMeter.reset()
        level = 0
        let url = temporaryAudioURL
        temporaryAudioURL = nil
        return url
    }

    func cancel() {
        let url = stop()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func deleteTemporaryAudio(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func refreshLevel() {
        level = levelMeter.read()
    }

    private func handleUnexpectedConfigurationChange() {
        guard isRecording else { return }
        configurationChangeTask?.cancel()
        configurationChangeTask = Task { @MainActor [weak self] in
            // AVAudioEngine may publish a transient route/configuration notice
            // while the same healthy stream keeps running. Give Core Audio a
            // moment to settle and never end a long dictation for that notice.
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            let format = self.engine.inputNode.outputFormat(forBus: 0)
            guard Self.configurationChangeRequiresStopping(
                engineIsRunning: self.engine.isRunning,
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            ) else { return }

            let url = self.stop()
            if let url { self.deleteTemporaryAudio(at: url) }
            self.onCaptureFailure?("The microphone disconnected. Start again when it is available.")
        }
    }

    nonisolated static func configurationChangeRequiresStopping(
        engineIsRunning: Bool,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) -> Bool {
        !engineIsRunning || sampleRate <= 0 || channelCount == 0
    }

    nonisolated static func resolvedSelectedDeviceUID(
        _ selectedUID: String?,
        availableUIDs: [String]
    ) -> String? {
        guard let selectedUID else { return nil }
        return availableUIDs.contains(selectedUID) ? selectedUID : nil
    }

    private func removeStaleTemporaryAudio() {
        try? FileManager.default.removeItem(at: Self.temporaryAudioDirectory)
    }

    private func configureInput(deviceUID: String?, for input: AVAudioInputNode) throws {
        guard let deviceUID else {
            selectedDeviceName = systemDefaultDeviceName
            return
        }
        guard let device = availableInputs().first(where: { $0.uniqueID == deviceUID }),
              let deviceID = audioDeviceID(for: deviceUID),
              let audioUnit = input.audioUnit else {
            throw SprekrError.audioCaptureUnavailable
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        selectedDeviceName = device.localizedName
    }

    private func audioDeviceID(for uniqueID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else { return nil }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
                  let uid else {
                continue
            }
            if uid.takeUnretainedValue() as String == uniqueID { return deviceID }
        }
        return nil
    }

    private var systemDefaultDeviceName: String {
        guard let defaultUID = defaultInputDeviceUID(),
              let device = availableInputs().first(where: { $0.uniqueID == defaultUID })
        else { return "System Default" }
        return "System Default · \(device.localizedName)"
    }

    private func defaultInputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &uidAddress,
            0,
            nil,
            &uidSize,
            &uid
        ) == noErr,
              let uid
        else { return nil }
        return uid.takeUnretainedValue() as String
    }

    private nonisolated static var temporaryAudioDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Sprekr Audio", isDirectory: true)
    }

    private nonisolated static func makeTapBlock(
        file: AVAudioFile,
        levelMeter: AudioLevelMeter
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            do { try file.write(from: buffer) } catch { return }
            levelMeter.update(averagePower(of: buffer))
        }
    }

    private nonisolated static func averagePower(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frames {
            let sample = channels[0][index]
            sum += sample * sample
        }
        return normalizedMeterLevel(forRMS: sqrt(sum / Float(frames)))
    }

    nonisolated static func normalizedMeterLevel(forRMS rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 0.000_01))
        let noiseFloor: Float = -54
        let speechCeiling: Float = -10
        guard decibels > noiseFloor else { return 0 }
        let normalized = min(max((decibels - noiseFloor) / (speechCeiling - noiseFloor), 0), 1)
        // Slightly lift normal conversational speech while preserving a quiet
        // noise floor, so the Flow Bar reads clearly without looking frantic.
        return pow(normalized, 0.72)
    }
}
