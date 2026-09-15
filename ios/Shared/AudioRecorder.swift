import AVFoundation
import Combine
import Foundation

class AudioRecorder: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioConverter: AVAudioConverter?

    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var permissionDenied = false

    // Callback for audio data
    var onAudioData: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setPreferredSampleRate(16000.0)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print(
                "[AudioRecorder] Audio session setup successful. Preferred: 16000, Actual: \(session.sampleRate)"
            )
        } catch {
            print("[AudioRecorder] Failed to setup audio session: \(error)")
            onError?("Audio session failed: \(error.localizedDescription)")
        }
    }

    func requestPermissionAndRecord() {
        print("[AudioRecorder] Requesting microphone permission...")

        // Check iOS 17 deprecated lookup if possible, but standard check is fine
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            startRecordingInternal()
        case .denied:
            permissionDenied = true
            onError?("Microphone access denied. Enable in Settings.")
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startRecordingInternal()
                    } else {
                        self?.permissionDenied = true
                        self?.onError?("Microphone access denied. Enable in Settings.")
                    }
                }
            }
        @unknown default:
            break
        }
    }

    func startRecording() {
        requestPermissionAndRecord()
    }

    private func startRecordingInternal() {
        print("[AudioRecorder] Starting recording (AVAudioEngine)...")

        setupAudioSession()

        // Tear down existing
        if audioEngine?.isRunning == true {
            audioEngine?.stop()
        }

        // Create new engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }

        inputNode = audioEngine.inputNode

        // Get hardware format
        let inputFormat = inputNode!.outputFormat(forBus: 0)

        // Define target format: 16kHz, 1 channel, PCM Int16
        // Deepgram prefers this format.
        guard
            let recordingFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)
        else {
            print("[AudioRecorder] Failed to create audio format")
            return
        }

        // Setup Converter
        audioConverter = AVAudioConverter(from: inputFormat, to: recordingFormat)

        // Install Tap
        // Buffer size is a hint. 1024 frames @ 44.1k is ~23ms.
        inputNode!.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] (buffer, time) in
            guard let self = self else { return }
            self.processAudioBuffer(buffer)
        }

        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
                print("[AudioRecorder] Started AVAudioEngine successfully")
            }
        } catch {
            print("[AudioRecorder] Audio Engine failed to start: \(error)")
            // Reset state on failure
            cleanupEngine()
            DispatchQueue.main.async {
                self.onError?("Engine Start Error: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording(completion: @escaping (Data?) -> Void) {
        print("[AudioRecorder] Stopping recording...")

        cleanupEngine()

        DispatchQueue.main.async {
            self.isRecording = false
            // Return accumulated data
            let data = self.accumulatedData
            self.accumulatedData = Data()  // Reset
            completion(data)
        }
    }

    private func cleanupEngine() {
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        audioEngine = nil
        inputNode = nil
        audioConverter = nil
    }

    private var accumulatedData = Data()
    private var processCount = 0

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter else { return }

        // Calculate output buffer size
        // input frames * (outputRate / inputRate)
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = UInt32(Double(buffer.frameCapacity) * ratio)

        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { return }

        var error: NSError? = nil

        // Input block for converter
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("Audio conversion error: \(error)")
            return
        }

        // Convert to Data
        let audioData = Data(buffer: outputBuffer)

        // DEBUG LOGGING
        processCount += 1
        if processCount % 50 == 0 {
            print(
                "[AudioRecorder] Generated \(audioData.count) bytes (Total chunks: \(processCount))"
            )
        }

        // Call callback
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.accumulatedData.append(audioData)
            self.onAudioData?(audioData)
        }
    }
}

extension Data {
    init(buffer: AVAudioPCMBuffer) {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        self.init(bytes: audioBuffer.mData!, count: Int(audioBuffer.mDataByteSize))
    }
}
