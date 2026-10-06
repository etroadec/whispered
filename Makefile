.PHONY: all clean build run run-app whisper-lib sync-headers download-model download-vad download-whisper download-all xcode bundle install release notarize

# Directories
WHISPER_DIR = WhisperCpp/whisper.cpp
BUILD_DIR = build
LIB_DIR = lib
NPROC = $(shell sysctl -n hw.ncpu)
MODEL_DIR = $(HOME)/Library/Application Support/Whispered/models

all: whisper-lib build

# Recopie les en-tetes du submodule dans WhisperCpp/include (vus par SwiftPM).
# A relancer apres chaque mise a jour du submodule, sinon les en-tetes derivent
# silencieusement de la lib compilee.
sync-headers:
	@echo "==> Syncing headers from $(WHISPER_DIR)..."
	@cp $(WHISPER_DIR)/include/whisper.h $(WHISPER_DIR)/include/parakeet.h WhisperCpp/include/
	@cp $(WHISPER_DIR)/ggml/include/ggml.h \
		$(WHISPER_DIR)/ggml/include/ggml-alloc.h \
		$(WHISPER_DIR)/ggml/include/ggml-backend.h \
		$(WHISPER_DIR)/ggml/include/ggml-cpu.h WhisperCpp/include/
	@echo "==> Headers synced:" $$(cd $(WHISPER_DIR) && git describe --tags 2>/dev/null)

# Build whisper.cpp + parakeet (Apple Silicon, Metal)
# Les deux moteurs tournent sur Metal : pas de CoreML (jamais telecharge par
# l'app, et Parakeet n'a pas de chemin ANE), pas de tranche x86_64.
whisper-lib: sync-headers
	@echo "==> Building whisper.cpp + parakeet (arm64, Metal)..."
	@mkdir -p $(BUILD_DIR)/whisper
	@cd $(BUILD_DIR)/whisper && cmake ../../$(WHISPER_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_OSX_ARCHITECTURES="arm64" \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
		-DGGML_METAL=ON \
		-DGGML_ACCELERATE=ON \
		-DWHISPER_COREML=OFF \
		-DBUILD_SHARED_LIBS=OFF \
		-DWHISPER_BUILD_TESTS=OFF \
		-DWHISPER_BUILD_EXAMPLES=OFF
	@cd $(BUILD_DIR)/whisper && make -j$(NPROC)
	@mkdir -p $(LIB_DIR)
	@echo "==> Copying libraries..."
	@rm -f $(LIB_DIR)/*.a $(LIB_DIR)/*.metal
	@find $(BUILD_DIR)/whisper -name "*.a" -exec cp {} $(LIB_DIR)/ \;
	@echo "==> Libraries built:" $$(ls $(LIB_DIR) | tr '\n' ' ')

# Build Swift application
build: whisper-lib
	@echo "==> Building Whispered app..."
	@swift build -c release

# Run the application
run: build
	@echo "==> Running Whispered..."
	@.build/release/Whispered

# Download the default model (Parakeet TDT v3 q8_0, 638 MB)
download-model:
	@echo "==> Downloading Parakeet TDT 0.6B v3 (q8_0)..."
	@mkdir -p "$(MODEL_DIR)"
	@curl -L --progress-bar -o "$(MODEL_DIR)/ggml-parakeet-tdt-0.6b-v3-q8_0.bin" \
		"https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin"
	@echo "==> Model downloaded to $(MODEL_DIR)"

# Download the Silero VAD model (0.8 MB) used to detect actual speech
download-vad:
	@echo "==> Downloading Silero VAD..."
	@mkdir -p "$(MODEL_DIR)"
	@curl -L --progress-bar -o "$(MODEL_DIR)/ggml-silero-v5.1.2.bin" \
		"https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
	@echo "==> VAD model ready."

# Download the fallback Whisper model (large-v3-turbo Q5, 547 MB)
download-whisper:
	@echo "==> Downloading whisper large-v3-turbo Q5..."
	@mkdir -p "$(MODEL_DIR)"
	@curl -L --progress-bar -o "$(MODEL_DIR)/ggml-large-v3-turbo-q5_0.bin" \
		"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

# Download everything the app can use
download-all: download-model download-vad download-whisper
	@echo "==> All models downloaded!"

# Create app bundle
bundle: build
	@echo "==> Creating app bundle..."
	@./scripts/bundle-app.sh

# Run the bundled app (same identifier as installed version, for testing)
run-app: bundle
	@echo "==> Running Whispered.app bundle..."
	@open .build/release/Whispered.app

# Install to /Applications
install: bundle
	@echo "==> Installing Whispered to /Applications..."
	@rm -rf /Applications/Whispered.app
	@cp -r .build/release/Whispered.app /Applications/
	@echo "==> Whispered installed to /Applications/Whispered.app"
	@echo "==> You can now enable 'Launch at startup' in preferences."

# Archive prete pour une release GitHub
release: bundle
	@echo "==> Creating release archive..."
	@rm -f $(BUILD_DIR)/Whispered.zip
	@mkdir -p $(BUILD_DIR)
	@cd .build/release && ditto -c -k --sequesterRsrc --keepParent Whispered.app "$(CURDIR)/$(BUILD_DIR)/Whispered.zip"
	@echo "==> $(BUILD_DIR)/Whispered.zip"
	@shasum -a 256 $(BUILD_DIR)/Whispered.zip

# Notarisation Apple : necessaire pour que l'app s'ouvre sans avertissement
# ailleurs que sur cette machine.
#
# Prerequis, une seule fois :
#   1. un certificat « Developer ID Application » (Apple Developer Program) ;
#   2. un profil de credentials enregistre dans le trousseau :
#      xcrun notarytool store-credentials whispered-notary \
#        --apple-id <email> --team-id <TEAM_ID> --password <mot-de-passe-app>
notarize: release
	@if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then \
		echo "❌ Aucun certificat « Developer ID Application » dans le trousseau."; \
		echo "   Sans lui, impossible de notariser : l'app restera bloquee par Gatekeeper"; \
		echo "   sur une autre machine. A creer depuis le portail Apple Developer."; \
		exit 1; \
	fi
	@echo "==> Submitting to Apple notary service..."
	@xcrun notarytool submit $(BUILD_DIR)/Whispered.zip \
		--keychain-profile whispered-notary --wait
	@echo "==> Stapling..."
	@xcrun stapler staple .build/release/Whispered.app
	@rm -f $(BUILD_DIR)/Whispered.zip
	@cd .build/release && ditto -c -k --sequesterRsrc --keepParent Whispered.app "$(CURDIR)/$(BUILD_DIR)/Whispered.zip"
	@echo "==> Notarized archive: $(BUILD_DIR)/Whispered.zip"
	@shasum -a 256 $(BUILD_DIR)/Whispered.zip

# Generate Xcode project
xcode: whisper-lib
	@echo "==> Generating Xcode project..."
	@swift package generate-xcodeproj

# Clean build artifacts
clean:
	@echo "==> Cleaning..."
	@rm -rf $(BUILD_DIR)
	@rm -rf $(LIB_DIR)
	@rm -rf .build
	@rm -rf .swiftpm
	@rm -rf *.xcodeproj
	@echo "==> Cleaned!"

# Help
help:
	@echo "Whispered - Voice transcription for macOS (Apple Silicon)"
	@echo ""
	@echo "Usage:"
	@echo "  make              - Build everything (whisper.cpp + parakeet, Metal)"
	@echo "  make whisper-lib  - Build the C libraries (syncs headers first)"
	@echo "  make sync-headers - Copy submodule headers into WhisperCpp/include"
	@echo "  make build        - Build Swift application"
	@echo "  make bundle       - Create .app bundle"
	@echo "  make install      - Install to /Applications"
	@echo "  make run          - Run the application (dev mode)"
	@echo "  make run-app      - Run the bundled .app (test before install)"
	@echo "  make download-model   - Download Parakeet TDT v3 q8_0 (638 MB)"
	@echo "  make download-vad     - Download Silero VAD (0.8 MB)"
	@echo "  make download-whisper - Download whisper large-v3-turbo Q5 (547 MB)"
	@echo "  make download-all     - Download all models"
	@echo "  make release      - Build + zip ready for a GitHub release"
	@echo "  make notarize     - Notarize the release archive with Apple"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make help         - Show this help"
	@echo ""
	@echo "Installation:"
	@echo "  make install      - Build and install to /Applications"
	@echo ""
	@echo "For best performance on Apple Silicon:"
	@echo "  make clean && make install && make download-all"
