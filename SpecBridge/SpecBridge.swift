import Foundation
import Combine
import AVFoundation
import HaishinKit
import RTMPHaishinKit

@MainActor
class TwitchManager: NSObject, ObservableObject {
    // The connection to the Twitch Server
    private var rtmpConnection = RTMPConnection()
    // The stream object that sends the data
    private var rtmpStream: RTMPStream!
    // Media mixer for audio/video - routes both to the RTMP stream
    private var mediaMixer: MediaMixer!

    // Audio capture session (separate from MediaMixer since we use manual mode)
    private var audioCaptureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let audioCaptureQueue = DispatchQueue(label: "com.specbridge.audiocapture")

    @Published var isBroadcasting = false
    @Published var connectionStatus = "Disconnected"
    @Published var isAudioEnabled = true
    @Published var audioStatus = "Not started"

    override init() {
        super.init()
        rtmpStream = RTMPStream(connection: rtmpConnection)

        // Initialize MediaMixer for audio handling
        Task {
            await setupMediaMixer()
        }
    }

    private func setupMediaMixer() async {
        // Create media mixer - use manual mode since we provide both video and audio manually
        mediaMixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)

        // Configure video to passthrough mode (we're providing raw frames)
        var videoSettings = await mediaMixer.videoMixerSettings
        videoSettings.mode = .passthrough
        await mediaMixer.setVideoMixerSettings(videoSettings)

        // Configure audio settings on the RTMP stream
        var audioSettings = AudioCodecSettings()
        audioSettings.bitRate = 128 * 1000  // 128 kbps
        audioSettings.format = .aac
        try? await rtmpStream.setAudioSettings(audioSettings)

        // Attach the RTMP stream as output from the mixer
        await mediaMixer.addOutput(rtmpStream)

        print("[TwitchManager] MediaMixer setup complete")
    }

    func startBroadcast(streamKey: String) async {
        let twitchURL = "rtmp://live.twitch.tv/app"
        connectionStatus = "Connecting..."

        do {
            // Request microphone permission first
            let micPermissionGranted = await requestMicrophonePermission()
            if !micPermissionGranted {
                audioStatus = "Mic permission denied"
                print("[TwitchManager] Microphone permission denied")
            }

            // Configure audio session
            try configureAudioSession()

            // Start the media mixer
            await mediaMixer.startRunning()
            print("[TwitchManager] MediaMixer started running")

            // Start audio capture from iPhone microphone (our own capture session)
            if isAudioEnabled && micPermissionGranted {
                startAudioCaptureSession()
            }

            _ = try await rtmpConnection.connect(twitchURL)
            _ = try await rtmpStream.publish(streamKey)
            connectionStatus = "Live on Twitch!"
            isBroadcasting = true
            print("[TwitchManager] Broadcasting started successfully")
        } catch {
            connectionStatus = "Connection Failed: \(error.localizedDescription)"
            isBroadcasting = false
            stopAudioCaptureSession()
            print("[TwitchManager] Broadcast failed: \(error)")
        }
    }

    func stopBroadcast() async {
        do {
            try await rtmpConnection.close()
        } catch {
            print("[TwitchManager] Error closing stream: \(error)")
        }

        stopAudioCaptureSession()
        await mediaMixer.stopRunning()
        isBroadcasting = false
        connectionStatus = "Disconnected"
        audioStatus = "Stopped"
    }

    private func requestMicrophonePermission() async -> Bool {
        print("[TwitchManager] Requesting microphone permission...")

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[TwitchManager] Current mic auth status: \(status.rawValue)")

        switch status {
        case .authorized:
            print("[TwitchManager] Microphone already authorized")
            return true
        case .notDetermined:
            print("[TwitchManager] Requesting mic permission from user...")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            print("[TwitchManager] User response: \(granted ? "granted" : "denied")")
            return granted
        case .denied, .restricted:
            print("[TwitchManager] Microphone access denied or restricted")
            return false
        @unknown default:
            return false
        }
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
        )
        try audioSession.setActive(true)
        print("[TwitchManager] Audio session configured")
    }

    // MARK: - Audio Capture Session (Manual)

    private func startAudioCaptureSession() {
        guard audioCaptureSession == nil else {
            print("[TwitchManager] Audio capture session already running")
            return
        }

        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            audioStatus = "No mic found"
            print("[TwitchManager] No audio device found")
            return
        }

        print("[TwitchManager] Setting up audio capture session with: \(audioDevice.localizedName)")

        do {
            let captureSession = AVCaptureSession()
            captureSession.beginConfiguration()

            // Add audio input
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
                print("[TwitchManager] Audio input added to capture session")
            } else {
                print("[TwitchManager] Cannot add audio input to capture session")
                audioStatus = "Mic input failed"
                return
            }

            // Add audio output
            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(self, queue: audioCaptureQueue)
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
                print("[TwitchManager] Audio output added to capture session")
            } else {
                print("[TwitchManager] Cannot add audio output to capture session")
                audioStatus = "Mic output failed"
                return
            }

            captureSession.commitConfiguration()

            // Start the capture session on a background thread
            self.audioCaptureSession = captureSession
            self.audioOutput = audioOutput

            DispatchQueue.global(qos: .userInitiated).async {
                captureSession.startRunning()
                DispatchQueue.main.async {
                    self.audioStatus = "Mic active"
                    print("[TwitchManager] Audio capture session started")
                }
            }

        } catch {
            audioStatus = "Mic setup failed"
            print("[TwitchManager] Failed to setup audio capture: \(error)")
        }
    }

    private func stopAudioCaptureSession() {
        guard let captureSession = audioCaptureSession else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.stopRunning()
            DispatchQueue.main.async {
                self.audioCaptureSession = nil
                self.audioOutput = nil
                self.audioStatus = "Mic stopped"
                print("[TwitchManager] Audio capture session stopped")
            }
        }
    }

    // MARK: - Video Frame Processing

    func processVideoFrame(_ buffer: CMSampleBuffer) {
        guard isBroadcasting else { return }

        Task {
            // Send video frame through the MediaMixer
            await mediaMixer.append(buffer)
        }
    }

    // MARK: - Audio Toggle

    func toggleAudio() async {
        isAudioEnabled.toggle()

        if isBroadcasting {
            if isAudioEnabled {
                startAudioCaptureSession()
            } else {
                stopAudioCaptureSession()
            }
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension TwitchManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Feed audio samples to the MediaMixer
        Task {
            await mediaMixer.append(sampleBuffer, track: 0)
        }
    }
}
