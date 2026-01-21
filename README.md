# Whispered

Application macOS de transcription vocale locale, basée sur [whisper.cpp](https://github.com/ggerganov/whisper.cpp).

**100% hors ligne** - Vos données audio ne quittent jamais votre Mac.

## Fonctionnalités

- Transcription vocale en temps réel
- Fonctionne entièrement hors ligne (après téléchargement du modèle)
- Accélération Metal GPU + Neural Engine (Apple Silicon)
- Détection automatique de la langue
- Injection du texte dans le champ actif
- Interface minimaliste dans la barre de menu
- Choix du modèle Whisper (Tiny, Base, Small, Medium)

## Prérequis

- macOS 14.0 ou supérieur
- Xcode Command Line Tools
- CMake

```bash
# Installer les outils nécessaires
xcode-select --install
brew install cmake
```

## Installation

### 1. Cloner le dépôt

```bash
git clone --recursive https://github.com/etroadec/whispered.git
cd whispered
```

> **Note** : `--recursive` est important pour télécharger le submodule whisper.cpp

### 2. Compiler et installer l'application

```bash
make install
```

Cette commande :
- Compile whisper.cpp avec support Metal et CoreML
- Compile l'application Swift
- Crée le bundle `.app`
- Installe dans `/Applications`

L'application apparaîtra dans vos Applications et vous pourrez l'ajouter au démarrage automatique via ses préférences.

### 3. Télécharger un modèle

Au premier lancement :
1. Clic droit sur l'icône dans la barre de menu
2. Sélectionnez **Préférences...**
3. Cliquez sur **Télécharger** à côté du modèle souhaité

Ou via le terminal :
```bash
# Modèle Base (~150 MB) - Recommandé pour commencer
make download-model

# Modèle Small (~500 MB) + CoreML - Meilleure précision
make download-all
```

## Utilisation

1. L'icône apparaît dans la barre de menu (forme d'onde)
2. **Maintenez la touche Command droite (⌘)** enfoncée
3. Parlez
4. Relâchez la touche
5. Le texte est transcrit et collé dans le champ actif

### Raccourcis

| Action | Raccourci |
|--------|-----------|
| Enregistrer | Maintenir **⌘ droite** |
| Menu | Clic droit sur l'icône |
| Préférences | Clic droit → Préférences |

## Modèles disponibles

| Modèle | Taille | Précision | Vitesse |
|--------|--------|-----------|---------|
| Tiny | ~75 MB | ⭐ | Très rapide |
| Base | ~150 MB | ⭐⭐ | Rapide |
| **Small** | ~500 MB | ⭐⭐⭐ | Moyen |
| Medium | ~1.5 GB | ⭐⭐⭐⭐ | Lent |

> **Recommandation** : Le modèle **Small** offre le meilleur rapport qualité/vitesse sur Apple Silicon.

Les modèles sont téléchargés depuis [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp) et stockés dans :
```
~/Library/Application Support/Whispered/models/
```

## Permissions requises

L'application nécessite deux permissions :

| Permission | Raison |
|------------|--------|
| **Microphone** | Capturer l'audio |
| **Accessibilité** | Détecter le raccourci clavier et injecter le texte |

macOS vous demandera ces permissions au premier lancement.

## Commandes Make

| Commande | Description |
|----------|-------------|
| `make` | Compile tout (whisper.cpp + app) |
| `make whisper-lib` | Compile uniquement whisper.cpp |
| `make build` | Compile l'application Swift |
| `make bundle` | Crée le bundle `.app` |
| `make install` | Installe dans `/Applications` |
| `make run` | Lance l'application (mode développement) |
| `make download-model` | Télécharge le modèle Base |
| `make download-coreml` | Télécharge le modèle CoreML Base |
| `make download-all` | Télécharge Base + CoreML |
| `make clean` | Supprime les fichiers de build |
| `make help` | Affiche l'aide |

## Structure du projet

```
whispered/
├── Whispered/                # Application Swift
│   ├── App/                  # Point d'entrée et AppDelegate
│   ├── Views/                # Interface SwiftUI
│   ├── Services/             # Audio, Whisper, Hotkey, TextInjector
│   └── Models/               # Modèles de données
├── WhisperCpp/               # Wrapper whisper.cpp
│   ├── whisper.cpp/          # Submodule Git
│   └── include/              # Headers pour le bridge Swift-C
├── Resources/                # Icône de l'application
├── scripts/                  # Scripts de build (bundle-app.sh)
├── Makefile                  # Scripts de build
├── Package.swift             # Configuration Swift Package Manager
└── README.md
```

## Optimisations Apple Silicon

Sur les Mac avec puce Apple (M1, M2, M3, M4, M5), l'application utilise :

- **Metal GPU** : Calcul parallèle sur le GPU
- **CoreML** : Accélération via le Neural Engine
- **Accelerate** : Framework Apple optimisé pour le calcul vectoriel

Pour bénéficier du Neural Engine, téléchargez aussi les modèles CoreML :
```bash
make download-coreml
```

## Dépannage

### L'application ne démarre pas
```bash
# Recompiler proprement
make clean && make install
```

### Le raccourci clavier ne fonctionne pas
1. Vérifiez les permissions dans **Préférences Système → Confidentialité et Sécurité → Accessibilité**
2. Ajoutez Whispered.app à la liste et cochez-le
3. **Redémarrez l'application** après avoir accordé les permissions

> **Note** : L'application doit être signée avec un certificat Apple Development pour que les permissions soient conservées entre les builds. Voir la section Développement.

### Pas de transcription
- Vérifiez qu'un modèle est téléchargé (Préférences → section Modèle)
- Vérifiez les permissions du microphone dans **Confidentialité et Sécurité → Microphone**

### Erreur "Model not found"
```bash
make download-model
```

## Développement

### Prérequis pour le développement

Pour que les permissions macOS (Accessibilité, Microphone) soient conservées entre les builds, l'application doit être signée avec un certificat Apple Development :

```bash
# Vérifier vos certificats disponibles
security find-identity -v -p codesigning

# Le script bundle-app.sh utilisera automatiquement votre certificat
```

Si vous n'avez pas de certificat, vous pouvez en créer un via Xcode → Settings → Accounts → Manage Certificates.

### Commandes utiles

```bash
make run          # Lancer en mode développement (exécutable direct)
make run-app      # Lancer le bundle .app (même comportement qu'installé)
make install      # Compiler et installer dans /Applications
make clean        # Nettoyer les fichiers de build
```

## Crédits

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) par Georgi Gerganov
- [Whisper](https://github.com/openai/whisper) par OpenAI

## Licence

MIT
