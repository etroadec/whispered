.PHONY: all clean build run whisper-lib download-model xcode

# Directories
WHISPER_DIR = WhisperCpp/whisper.cpp
BUILD_DIR = build
LIB_DIR = lib
NPROC = $(shell sysctl -n hw.ncpu)
MODEL_DIR = $(HOME)/Library/Application Support/Whispered/models

all: whisper-lib build

# Build whisper.cpp library
whisper-lib:
	@echo "==> Building whisper.cpp..."
	@mkdir -p $(BUILD_DIR)/whisper
	@cd $(BUILD_DIR)/whisper && cmake ../../$(WHISPER_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
		-DGGML_METAL=ON \
		-DGGML_ACCELERATE=ON \
		-DWHISPER_COREML=OFF \
		-DBUILD_SHARED_LIBS=OFF \
		-DWHISPER_BUILD_TESTS=OFF \
		-DWHISPER_BUILD_EXAMPLES=OFF
	@cd $(BUILD_DIR)/whisper && make -j$(NPROC)
	@mkdir -p $(LIB_DIR)
	@echo "==> Copying libraries..."
	@find $(BUILD_DIR)/whisper -name "*.a" -exec cp {} $(LIB_DIR)/ \;
	@cp $(BUILD_DIR)/whisper/ggml/src/ggml-metal.metal $(LIB_DIR)/ 2>/dev/null || true
	@echo "==> Whisper library built successfully!"

# Build Swift application
build: whisper-lib
	@echo "==> Building Whispered app..."
	@swift build -c release

# Run the application
run: build
	@echo "==> Running Whispered..."
	@.build/release/Whispered

# Download Whisper model
download-model:
	@echo "==> Downloading Whisper Base model..."
	@mkdir -p "$(MODEL_DIR)"
	@curl -L --progress-bar -o "$(MODEL_DIR)/ggml-base.bin" \
		"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
	@echo "==> Model downloaded to $(MODEL_DIR)/ggml-base.bin"

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
	@echo "Whispered - Voice transcription for macOS"
	@echo ""
	@echo "Usage:"
	@echo "  make              - Build everything"
	@echo "  make whisper-lib  - Build whisper.cpp library only"
	@echo "  make build        - Build Swift application"
	@echo "  make run          - Run the application"
	@echo "  make download-model - Download Whisper Base model"
	@echo "  make clean        - Remove build artifacts"
	@echo "  make help         - Show this help"
