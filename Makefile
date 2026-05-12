# Variables for script names
BUILD_SCRIPT = vivado_build_all.sh
CLEAN_SCRIPT = clean.sh

# .PHONY tells make that these are commands, not filenames
.PHONY: all build clean

# Default target: running 'make' will trigger 'make build'
all: build

# Build target
build:
	@echo "Starting full build process..."
	@chmod +x $(BUILD_SCRIPT)
	@./$(BUILD_SCRIPT)

# Clean target
clean:
	@echo "Starting cleanup process..."
	@chmod +x $(CLEAN_SCRIPT)
	@./$(CLEAN_SCRIPT)
