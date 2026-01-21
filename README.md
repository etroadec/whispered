# Whispered

Application macOS minimaliste pour la transcription vocale, basée sur [whisper.cpp](https://github.com/ggerganov/whisper.cpp).

## Fonctionnalités

- Transcription vocale locale (aucune connexion internet requise)
- Raccourci clavier: **Command droit (⌘)** pour enregistrer
- Interface discrète dans la barre de menu
- Injection automatique du texte dans le champ actif
- Détection automatique de la langue
- Accélération Metal sur Apple Silicon

## Installation

### Prérequis

- macOS 13.0+
- Xcode Command Line Tools
- CMake

```bash
# Installer les outils
xcode-select --install
brew install cmake
```

### Compilation

```bash
# Cloner le repo avec les submodules
git clone --recursive https://github.com/votre-username/whispered.git
cd whispered

# Compiler whisper.cpp et l'application
make

# Télécharger le modèle Whisper Base (~150MB)
make download-model
```

### Lancer l'application

```bash
make run
```

## Utilisation

1. L'application apparaît dans la barre de menu (icône waveform)
2. Maintenez la touche **Command droite (⌘)** enfoncée
3. Un popup s'ouvre, parlez
4. Relâchez la touche
5. Le texte est transcrit et injecté dans le champ de texte actif

## Permissions requises

L'application nécessite deux permissions:

- **Microphone**: Pour capturer l'audio
- **Accessibilité**: Pour détecter le raccourci clavier global et injecter le texte

Lors du premier lancement, macOS vous demandera d'autoriser ces permissions.

## Commandes Make

| Commande | Description |
|----------|-------------|
| `make` | Compile tout (whisper.cpp + app) |
| `make whisper-lib` | Compile uniquement whisper.cpp |
| `make build` | Compile l'application Swift |
| `make run` | Lance l'application |
| `make download-model` | Télécharge le modèle Whisper Base |
| `make clean` | Supprime les fichiers de build |

## Structure du projet

```
whispered/
├── Whispered/           # Application Swift
│   ├── App/             # Point d'entrée et AppDelegate
│   ├── Views/           # Interface SwiftUI
│   ├── Services/        # Services (Audio, Whisper, Hotkey)
│   └── Models/          # Modèles de données
├── WhisperCpp/          # Wrapper pour whisper.cpp
│   ├── whisper.cpp/     # Submodule Git
│   └── include/         # Headers pour le bridge Swift-C
├── .claude/commands/    # Commandes Claude Code
├── Makefile             # Scripts de build
└── Package.swift        # Configuration Swift Package Manager
```

## Licence

MIT
