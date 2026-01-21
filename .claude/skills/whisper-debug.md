---
description: Débogue les problèmes de transcription Whisper
---

# Skill: Whisper Debug

Ce skill aide à diagnostiquer et résoudre les problèmes de transcription.

## Étapes de diagnostic

1. Vérifier que le modèle est téléchargé:
   ```bash
   ls -la ~/Library/Application\ Support/Whispered/models/
   ```

2. Tester une transcription manuelle avec whisper-cli:
   ```bash
   ./build/whisper/bin/whisper-cli -m ~/Library/Application\ Support/Whispered/models/ggml-base.bin -f <audio.wav>
   ```

3. Vérifier les permissions:
   - Microphone: Préférences Système > Confidentialité > Microphone
   - Accessibilité: Préférences Système > Confidentialité > Accessibilité

4. Vérifier les logs système:
   ```bash
   log show --predicate 'processImagePath contains "Whispered"' --last 5m
   ```

## Problèmes courants

- **Modèle non trouvé**: Exécuter `make download-model`
- **Pas de transcription**: Vérifier le format audio (16kHz mono PCM requis)
- **Raccourci ne fonctionne pas**: Ajouter l'app aux permissions d'accessibilité
