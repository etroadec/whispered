---
description: Aide au développement audio Swift/AVFoundation
---

# Skill: Swift Audio Development

Ce skill fournit des patterns et bonnes pratiques pour le développement audio sur macOS avec AVFoundation.

## Configuration audio pour Whisper

Whisper requiert un format audio spécifique:
- Sample rate: 16000 Hz
- Channels: 1 (mono)
- Format: PCM Int16

```swift
let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false
]
```

## Conversion audio

Pour convertir un fichier audio existant:
```bash
ffmpeg -i input.mp3 -ar 16000 -ac 1 -f wav output.wav
```

## Capture audio en temps réel

Utiliser `AVAudioEngine` pour la capture en temps réel avec analyse de niveau:
```swift
let audioEngine = AVAudioEngine()
let inputNode = audioEngine.inputNode
let format = inputNode.outputFormat(forBus: 0)

inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
    // Traiter le buffer audio
}
```

## Permissions

Ajouter dans Info.plist:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Whispered utilise le microphone pour la transcription vocale.</string>
```
