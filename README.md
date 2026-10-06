# Whispered

Application macOS de dictée vocale locale, basée sur [whisper.cpp](https://github.com/ggml-org/whisper.cpp) et le modèle [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) de NVIDIA.

**100 % hors ligne** - Vos données audio ne quittent jamais votre Mac.

## Fonctionnalités

- Dictée instantanée : **50 ms de transcription pour 3 s de parole** sur Apple Silicon
- Deux moteurs : **Parakeet TDT v3** (défaut, 25 langues européennes, détection automatique) et **whisper large-v3-turbo** (99 langues, traduction)
- Fonctionne entièrement hors ligne après téléchargement du modèle
- Détection de parole Silero : aucune transcription sur du silence, aucune hallucination
- Insertion dans le champ actif par l'API d'accessibilité, repli presse-papier, détection de la saisie sécurisée
- Historique des 50 dernières dictées, cherchable, avec réinsertion
- Dictionnaire de corrections pour les noms propres et le jargon
- Onde du micro affichée pendant la dictée
- Second raccourci configurable : autre moteur, copie seule, ou réinsertion
- Mises à jour automatiques depuis GitHub, vérifiées par empreinte et signature

## Prérequis

- macOS 14.0 ou supérieur, **Mac Apple Silicon** (M1 ou plus récent)
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

| Modèle | Taille | Moteur | Pour quoi |
|--------|--------|--------|-----------|
| **Parakeet v3** (défaut) | 638 Mo | Parakeet | Le plus rapide et le plus précis en français. 25 langues européennes, détection automatique. |
| Parakeet v3 léger | 396 Mo | Parakeet | Même vitesse, 240 Mo de moins. |
| Whisper large-v3-turbo Q5 | 547 Mo | whisper.cpp | 99 langues et traduction vers l'anglais. Plus lent, meilleur sur le jargon anglais. |
| Silero VAD | 0,8 Mo | — | Détection de parole, téléchargé automatiquement. |

Mesuré sur un MacBook M5, extrait de français de 3,2 s, modèle déjà chargé :

| Moteur | Latence | Remarque |
|--------|---------|----------|
| Parakeet v3 q8_0 | **50 ms** | coût proportionnel à la durée de l'audio |
| whisper large-v3-turbo | 710 ms | coût fixe : Whisper complète toujours une fenêtre de 30 s |

> Les modèles Tiny, Base, Small, Medium et Large V3 ont été retirés en v2.0 : tous dominés en qualité comme en vitesse par les deux restants. Les préférences proposent de récupérer la place qu'ils occupent.

Les modèles sont téléchargés depuis [Hugging Face](https://huggingface.co/ggml-org/parakeet-GGUF) et stockés dans :
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
| `make sync-headers` | Recopie les en-têtes du submodule dans `WhisperCpp/include` |
| `make download-model` | Télécharge Parakeet TDT v3 q8_0 (638 Mo) |
| `make download-vad` | Télécharge Silero VAD (0,8 Mo) |
| `make download-whisper` | Télécharge whisper large-v3-turbo Q5 (547 Mo) |
| `make download-all` | Télécharge les trois |
| `make clean` | Supprime les fichiers de build |
| `make help` | Affiche l'aide |

## Structure du projet

```
whispered/
├── Whispered/                # Application Swift
│   ├── App/                  # Point d'entrée et AppDelegate
│   ├── Views/                # Interface SwiftUI
│   ├── Services/             # Moteurs, audio, VAD, raccourcis, insertion
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

Les deux moteurs tournent sur **Metal**, avec **Accelerate** pour le calcul vectoriel. Le build est arm64 uniquement.

CoreML a été retiré en v2.0 : l'encodeur n'était jamais téléchargé par l'application (il fallait passer par `make`), Parakeet n'a pas de chemin Neural Engine dans whisper.cpp, et Metal seul suffit — 50 ms pour 3 s d'audio.

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

### v2.0.0

**Moteur :**
- **Parakeet TDT 0.6B v3 comme moteur par défaut** : 50 ms pour 3 s de parole au lieu de 710 ms, meilleure ponctuation, 638 Mo au lieu de 1,6 Go, détection de langue automatique
- Submodule whisper.cpp porté en v1.9.4, qui apporte le support natif de Parakeet
- Catalogue réduit à 3 entrées : Tiny, Base, Small, Medium et Large V3 retirés
- **Détection de parole Silero (VAD)** à la place du seuil d'énergie global : rogne les blancs et n'invente rien sur du silence
- CoreML et la tranche x86_64 retirés du build ; cible de déploiement des bibliothèques alignée sur macOS 14

**Corrections :**
- Les dictées « merci beaucoup », « au revoir », « thank you » n'étaient jamais insérées : la liste noire anti-hallucination les confondait avec du bruit. Remplacée par le VAD et un filtre de répétitions
- L'encodeur CoreML annoncé dans les préférences n'était jamais téléchargé : le Neural Engine n'était donc jamais utilisé
- Le téléchargement d'un modèle de 1,6 Go n'affichait aucune progression et ne pouvait pas être annulé
- Le presse-papier pouvait rester écrasé après une insertion ; son contenu complet est maintenant restauré, images et fichiers inclus
- Dans un champ de mot de passe, l'app annonçait « Transcrit ! » alors que rien n'était inséré
- Plus d'écriture de WAV sur le disque ni d'attente arbitraire de 0,1 s : la capture reste en mémoire
- ⌘ gauche et ⌘ droite n'étaient plus confondues (masques dépendants du périphérique)
- La fenêtre de préférences était tronquée (contenu de 950 px dans une fenêtre de 850)

**Nouveau :**
- **Texte affiché pendant que tu parles** (macOS 26) : le moteur de transcription du système écrit dans le popup au fil de la parole, environ 30 ms après chaque mot. Le texte inséré reste celui de Parakeet, plus fidèle.
- **Réécriture par le modèle de langue de macOS** : nettoyer la ponctuation et les hésitations, passer du parlé à l'écrit, ou traduire en anglais — en local, sur le second raccourci. Demande Apple Intelligence activé.
- Dictée possible dès le premier lancement, via le moteur du système, pendant que le modèle se télécharge
- Historique des 50 dernières dictées, cherchable, avec réinsertion et copie
- Dictionnaire de corrections éditable, appliqué après transcription
- Onde du micro réelle dans le popup
- Modes d'insertion : insérer, copier seulement, ajouter à la suite
- Second raccourci configurable (autre moteur, copie seule, réinsertion)
- Arrêt automatique sur silence en mode « appuyer »
- Fenêtre de premier lancement : permissions, langue, raccourci
- Préférences réorganisées en onglets
- Mises à jour vérifiées par empreinte SHA-256 et signature du bundle
- Téléchargements reprenables : une connexion coupée ne fait pas repartir 638 Mo de zéro
- `make release` produit l'archive et son empreinte, `make notarize` la soumet à Apple
- Le micro non autorisé, ou changé en pleine dictée (casque branché), est signalé au lieu d'enregistrer du silence

### v1.5.0

**Nouvelles fonctionnalités :**
- **Modèles Large V3** : Ajout de 3 nouveaux modèles Whisper large-v3 pour une meilleure précision
  - Large V3 Turbo Q5 (~574 MB) - Rapide et précis, quantisé
  - Large V3 Turbo (~1.6 GB) - Haute qualité
  - Large V3 Q5 (~1.1 GB) - Meilleure précision, quantisé

### v1.4.0

**Nouvelles fonctionnalités :**
- **Choix du raccourci clavier** : ⌘ droite, Fn, ⌥ droite, ou Ctrl droite
- **Mode d'enregistrement** : Maintenir (hold-to-talk) ou Appuyer (toggle)
- **Langues favorites** : Définir 1-2 langues pour accès rapide dans le menu

### v1.2.0

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
