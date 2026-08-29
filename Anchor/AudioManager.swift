//
//  AudioManager.swift
//  Anchor
//
//  Created by Salman Maarouf on 29/8/2026.
//

import Foundation
import AVFoundation

class AudioManager: ObservableObject {
    static let shared = AudioManager()
    private var audioPlayer: AVAudioPlayer?

    func playAmbient(named name: String = "ambient", volume: Float = 0.25) {
        // Try common audio extensions in order
        let extensions = ["mp4", "m4a", "wav", "mp3", "aac"]
        var soundURL: URL?

        for ext in extensions {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                soundURL = url
                break
            }
        }

        guard let validUrl = soundURL else {
            print("Audio file named '\(name)' with extensions [mp4, m4a, wav, mp3, aac] not found in Bundle.main.")
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)

            audioPlayer = try AVAudioPlayer(contentsOf: validUrl)
            audioPlayer?.numberOfLoops = -1 // Infinite loop
            audioPlayer?.volume = volume
            audioPlayer?.prepareToPlay()
            let didPlay = audioPlayer?.play() ?? false
            print("Ambient audio started successfully: \(didPlay) at path: \(validUrl.lastPathComponent)")
        } catch {
            print("Error initializing AVAudioPlayer: \(error.localizedDescription)")
        }
    }

    func stop() {
        audioPlayer?.stop()
    }
}
