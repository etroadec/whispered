# Whispered - Instructions Claude Code

## Workflow de développement obligatoire

Pour **toute demande de développement ou changement de code**, suivre ce workflow :

### Étape 1 : Seb (Implémentation)
Utiliser l'agent **seb** pour :
- Analyser la demande
- Implémenter la solution (idiomatique macOS)
- Proposer le code

### Étape 2 : Gérard (Code Review)
Utiliser l'agent **gerard** pour :
- Reviewer le code produit par Seb
- Identifier les bugs, race conditions, memory leaks
- Proposer des corrections

### Étape 3 : Corrections & Validation
- Appliquer les corrections de Gérard
- Rebuild : `make install`
- Test manuel

## Agents disponibles

| Agent | Rôle | Modèle |
|-------|------|--------|
| `seb` | Expert macOS/iOS, implémentation | opus |
| `gerard` | Code review sans pitié | opus |

## Commandes utiles

```bash
make install      # Build + install dans /Applications
make run          # Lancer en mode dev
make clean        # Nettoyer le build
```

## Architecture du projet

- `Whispered/App/` - AppDelegate, point d'entrée
- `Whispered/Services/` - HotkeyManager, WhisperService, AudioRecorder
- `Whispered/Views/` - SwiftUI views
- `WhisperCpp/` - Bridge whisper.cpp

## Notes importantes

- L'app utilise CGEvent tap pour le raccourci clavier (⌘ droite)
- Nécessite les permissions Accessibilité et Microphone
- Les modèles Whisper sont dans `~/Library/Application Support/Whispered/models/`
