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
- **Popup personnalisable** : mode Standard ou Compact
- **Mises à jour automatiques** depuis GitHub

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

```
┌─────────────────────────────────────────────────────────────────┐
│  1. APPUYER          2. PARLER           3. RELÂCHER           │
│                                                                 │
│   ┌─────────┐       ┌─────────────┐       ┌─────────────────┐  │
│   │  ⌘ →    │  ──▶  │  🎙️ "Bonjour │  ──▶  │ Bonjour tout le │  │
│   │ (droite)│       │  tout le    │       │ monde|          │  │
│   └─────────┘       │  monde"     │       └─────────────────┘  │
│                     └─────────────┘         ↑ Texte injecté    │
│                                             dans le curseur    │
└─────────────────────────────────────────────────────────────────┘
```

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

## Mise à jour

### Mise à jour automatique (v1.1.0+)

À partir de la version 1.1.0, Whispered peut se mettre à jour automatiquement :

1. Ouvrez **Préférences** (clic droit sur l'icône)
2. Section **Mises à jour** → cliquez sur **Vérifier**
3. Si une mise à jour est disponible, cliquez sur **Installer la mise à jour**
4. L'application télécharge, s'installe et redémarre automatiquement

### Mise à jour manuelle (depuis les sources)

Si vous avez installé depuis les sources :

```bash
cd whispered
git pull
make clean && make install
```

### Première installation depuis une version antérieure

Si vous aviez une version sans mise à jour automatique :

```bash
# 1. Mettre à jour les sources
cd whispered
git pull

# 2. Recompiler et installer
make clean && make install

# 3. L'app aura maintenant les mises à jour automatiques
```

## Publier une nouvelle version (développeurs)

Pour publier une mise à jour sur GitHub :

1. **Mettre à jour la version** dans `scripts/bundle-app.sh` :
   ```bash
   VERSION="1.2.0"  # Incrémenter selon semver
   ```

2. **Compiler et créer le zip** :
   ```bash
   make clean && make bundle
   cd .build/release
   zip -r Whispered.zip Whispered.app
   ```

3. **Créer une release GitHub** :
   - Tag : `v1.2.0` (doit correspondre à VERSION)
   - Titre : `v1.2.0 - Description courte`
   - Joindre : `Whispered.zip`
   - Notes de version : décrire les changements

L'application des utilisateurs détectera automatiquement la nouvelle version.

## Changelog

### v1.2.0 (à venir)

**Nouvelles fonctionnalités :**
- Deux modes de popup : Standard (complet) et Compact (minimal)
- Popup centré en haut de l'écran pour moins de distraction
- Sélection du mode dans les Préférences → Apparence

### v1.1.0

**Nouvelles fonctionnalités :**
- Mises à jour automatiques depuis GitHub Releases
- Vérification des mises à jour dans les Préférences

**Améliorations :**
- Filtrage intelligent des transcriptions vides (ne colle plus "[BLANK_AUDIO]")
- Détection des marqueurs Whisper (silence, musique, etc.)
- Interface popup remplacée par un panneau flottant plus fiable

**Corrections :**
- Pas d'injection de texte quand l'audio est vide
- Positionnement du popup corrigé
- Redémarrage après mise à jour corrigé

### v1.0.0

- Version initiale
- Transcription vocale avec whisper.cpp
- Support Metal GPU et CoreML
- Raccourci clavier (⌘ droite)
- Gestion des modèles (Tiny, Base, Small, Medium)
- Lancement au démarrage

## Crédits

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) par Georgi Gerganov
- [Whisper](https://github.com/openai/whisper) par OpenAI

## Licence

MIT
