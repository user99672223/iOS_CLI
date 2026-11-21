import AVFoundation
import UIKit
import os

/// Keeps the app running in the background while Claude works, the way
/// Madeira's BackgroundRun does: iOS suspends an app a few seconds after it
/// leaves the screen unless it plays audio (UIBackgroundModes = audio). While
/// a turn runs and the app is in the background, a silent audio engine plays
/// (mixed with other apps' audio). It stops after the configured duration
/// (Settings, default 10 minutes; 0 = never), or when the turn ends.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private let log = Logger(subsystem: "cli.app", category: "background")
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var since: Date?
    private var timer: Timer?
    private var inBackground = false
    /// Asked by the engine: is there work worth staying awake for?
    var isBusy: () -> Bool = { false }

    static var minutes: Double {
        get { UserDefaults.standard.object(forKey: "backgroundMinutes") as? Double ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "backgroundMinutes") }
    }

    func install() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let ended = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            MainActor.assumeIsolated { if ended { self?.restartIfNeeded() } }
        }
    }

    var isKeeping: Bool { engine?.isRunning == true }

    private func enteredBackground() {
        inBackground = true
        since = Date()
        guard Self.minutes > 0, isBusy() else { return }
        startAudio()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func becameActive() {
        inBackground = false
        timer?.invalidate(); timer = nil
        stopAudio()
    }

    private func tick() {
        guard inBackground, let since else { return }
        if !isBusy() || Date().timeIntervalSince(since) > Self.minutes * 60 {
            log.log("background run ends (\(self.isBusy() ? "time limit" : "idle", privacy: .public))")
            timer?.invalidate(); timer = nil
            stopAudio()
        }
    }

    private func restartIfNeeded() {
        if inBackground, engine != nil, engine?.isRunning == false { try? engine?.start(); player?.play() }
    }

    private func startAudio() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: format)
            e.mainMixerNode.outputVolume = 0
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = 44100   // one second of silence, looped
            p.scheduleBuffer(buffer, at: nil, options: .loops)
            try e.start()
            p.play()
            engine = e; player = p
            log.log("keeping the app running in the background (\(Int(Self.minutes)) min max)")
        } catch {
            log.error("background audio failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopAudio() {
        player?.stop(); engine?.stop()
        player = nil; engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
