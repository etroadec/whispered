.PHONY: all clean build run run-app whisper-lib download-model download-coreml xcode bundle install

# Directories
WHISPER_DIR = WhisperCpp/whisper.cpp
BUILD_DIR = build
LIB_DIR = lib
NPROC = $(shell sysctl -n hw.ncpu)
MODEL_DIR = $(HOME)/Library/Application Support/Whispered/models

all: whisper-lib build

# Build whisper.cpp library with CoreML support (Universal Binary)
# - Apple Silicon: Metal + CoreML + Neural Engine
# - Intel: Metal + CPU (CoreML fallback)
whisper-lib:
	@echo "==> Building whisper.cpp with CoreML (Universal Binary)..."
	@mkdir -p $(BUILD_DIR)/whisper
	@cd $(BUILD_DIR)/whisper && cmake ../../$(WHISPER_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
		-DGGML_METAL=ON \
		-DGGML_ACCELERATE=ON \
		-DWHISPER_COREML=ON \
		-DWHISPER_COREML_ALLOW_FALLBACK=ON \
		-DBUILD_SHARED_LIBS=OFF \
		-DWHISPER_BUILD_TESTS=OFF \
		-DWHISPER_BUILD_EXAMPLES=OFF
	@cd $(BUILD_DIR)/whisper && make -j$(NPROC)
	@mkdir -p $(LIB_DIR)
	@echo "==> Copying libraries..."
	@find $(BUILD_DIR)/whisper -name "*.a" -exec cp {} $(LIB_DIR)/ \;
	@cp $(BUILD_DIR)/whisper/ggml/src/ggml-metal.metal $(LIB_DIR)/ 2>/dev/null || true
	@echo "==> Whisper library built with CoreML support!"

# Build Swift application
build: whisper-lib
	@echo "==> Building Whispered app..."
	@swift build -c release

# Run the application
run: build
	@echo "==> Running Whispered..."
	@.build/release/Whispered

# Download Whisper model (ggml format)
download-model:
	@echo "==> Downloading Whisper Base model..."
	@mkdir -p "$(MODEL_DIR)"
	@curl -L --progress-bar -o "$(MODEL_DIR)/ggml-base.bin" \
		"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
	@echo "==> Model downloaded to $(MODEL_DIR)/ggml-base.bin"

# Download CoreML model for Neural Engine acceleration
download-coreml:
	@echo "==> Downloading CoreML encoder model for Neural Engine..."
	@mkdir -p "$(MODEL_DIR)"
	@echo "==> Downloading base encoder (ANE optimized)..."
	@curl -L --progress-bar -o "$(MODEL_DIR)/ggml-base-encoder.mlmodelc.zip" \
		"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-encoder.mlmodelc.zip"
	@echo "==> Extracting CoreML model..."
	@cd "$(MODEL_DIR)" && unzip -o ggml-base-encoder.mlmodelc.zip && rm ggml-base-encoder.mlmodelc.zip
	@echo "==> CoreML model ready! Neural Engine acceleration enabled."

# Download all models (ggml + CoreML)
download-all: download-model download-coreml
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
	@echo "Whispered - Voice transcription for macOS (M5 optimized)"
	@echo ""
	@echo "Usage:"
	@echo "  make              - Build everything (with CoreML/Neural Engine)"
	@echo "  make whisper-lib  - Build whisper.cpp library"
	@echo "  make build        - Build Swift application"
	@echo "  make bundle       - Create .app bundle"
	@echo "  make install      - Install to /Applications"
	@echo "  make run          - Run the application (dev mode)"
	@echo "  make run-app      - Run the bundled .app (test before install)"
	@echo "  make download-model   - Download Whisper Base model (ggml)"
	@echo "  make download-coreml  - Download CoreML encoder (Neural Engine)"
	@echo "  make download-all     - Download all models"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make help         - Show this help"
	@echo ""
	@echo "Installation:"
	@echo "  make install      - Build and install to /Applications"
	@echo ""
	@echo "For best performance on Apple Silicon:"
	@echo "  make clean && make install && make download-all"
