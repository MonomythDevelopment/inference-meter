PROJECT := InferenceMeter.xcodeproj
SCHEME := InferenceMeter
DESTINATION ?= platform=macOS
DERIVED_DATA ?= DerivedData

.PHONY: help check-xcodegen generate build test clean

help:
	@echo "InferenceMeter build wrapper"
	@echo ""
	@echo "Prerequisite:"
	@echo "  Full Xcode selected for xcodebuild"
	@echo "  brew install xcodegen"
	@echo ""
	@echo "Targets:"
	@echo "  make build  Generate the Xcode project and build the app"
	@echo "  make test   Generate the Xcode project and run Swift Testing tests"
	@echo "  make clean  Remove generated build artifacts"

check-xcodegen:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "Missing prerequisite: xcodegen"; \
		echo "Install it with: brew install xcodegen"; \
		exit 127; \
	}

generate: check-xcodegen
	xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) test

clean:
	rm -rf $(PROJECT) $(DERIVED_DATA) build
