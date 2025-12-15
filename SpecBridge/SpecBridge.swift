import Foundation
import Combine
import AVFoundation
import HaishinKit
import RTMPHaishinKit

@MainActor
class TwitchManager: ObservableObject {
    // The connection to the Twitch Server
    private var rtmpConnection = RTMPConnection()
    // The stream object that sends the data
    private var rtmpStream: RTMPStream!
    // Media mixer for audio capture from iPhone mic
    private var mediaMixer: MediaMixer!

    @Published var isBroadcasting = false
    @Published var connectionStatus = "Disconnected"
    @Published var isAudioEnabled = true

    init() {
        rtmpStream = RTMPStream(connection: rtmpConnection)

        // Initialize MediaMixer for audio handling
        Task {
            await setupMediaMixer()
        }
    }

    private func setupMediaMixer() async {
        // Create media mixer - use manual mode since we get video from glasses, not camera
        mediaMixer = MediaMixer(captureSessionMode: .manual)

        // Configure audio settings on the RTMP stream
        var audioSettings = AudioCodecSettings()
        audioSettings.bitRate = 128 * 1000  // 128 kbps
        audioSettings.format = .aac
        try? await rtmpStream.setAudioSettings(audioSettings)

        // Attach the RTMP stream as output from the mixer
        await mediaMixer.addOutput(rtmpStream)
    }

    func startBroadcast(streamKey: String) async {
        let twitchURL = "rtmp://live.twitch.tv/app"
        connectionStatus = "Connecting..."

        do {
            // Configure audio session first
            try configureAudioSession()

            // Start audio capture from iPhone microphone
            if isAudioEnabled {
                await startAudioCapture()
            }

            _ = try await rtmpConnection.connect(twitchURL)
            _ = try await rtmpStream.publish(streamKey)
            connectionStatus = "Live on Twitch!"
            isBroadcasting = true
        } catch {
            connectionStatus = "Connection Failed: \(error.localizedDescription)"
            isBroadcasting = false
            await stopAudioCapture()
        }
    }

    func stopBroadcast() async {
        do {
            try await rtmpConnection.close()
        } catch {
            print("Error closing stream: \(error)")
        }

        await stopAudioCapture()
        isBroadcasting = false
        connectionStatus = "Disconnected"
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
        )
        try audioSession.setActive(true)
    }

    private func startAudioCapture() async {
        // Attach iPhone microphone to the media mixer
        do {
            try await mediaMixer.attachAudio(AVCaptureDevice.default(for: .audio))
            print("Audio capture started from iPhone microphone")
        } catch {
            print("Failed to attach audio device: \(error)")
        }
    }

    private func stopAudioCapture() async {
        // Detach audio device
        do {
            try await mediaMixer.attachAudio(nil)
            print("Audio capture stopped")
        } catch {
            print("Failed to detach audio device: \(error)")
        }
    }

    // Handles video frames from the glasses
    func processVideoFrame(_ buffer: CMSampleBuffer) {
        guard isBroadcasting else { return }

        Task {
            // Send video frame to the RTMP stream
            await rtmpStream.append(buffer)
        }
    }

    // Toggle audio on/off
    func toggleAudio() async {
        isAudioEnabled.toggle()

        if isBroadcasting {
            if isAudioEnabled {
                await startAudioCapture()
            } else {
                await stopAudioCapture()
            }
        }
    }
}
