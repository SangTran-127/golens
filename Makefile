# Target Architecture Guard
UNAME_M := $(shell uname -m)
ifneq ($(UNAME_M),arm64)
$(error GoLens requires Apple Silicon (arm64, Mac M1+). Intel x86_64 ($(UNAME_M)) is not supported)
endif

.PHONY: all build run app showcase clean test test-db vm-dev release

all: run

build:
	@echo "Building Go backend core (Apple Silicon arm64)..."
	@cd core && CGO_ENABLED=1 GOARCH=arm64 GOARM64=v8.4,lse,crypto go build -buildmode=c-shared -o libgoagent.dylib .
	@install_name_tool -id @rpath/libgoagent.dylib core/libgoagent.dylib
	@echo "Building SwiftUI IDE frontend (arm64-apple-macosx)..."
	@swift build -c release --triple arm64-apple-macosx
	@scripts/bundle-app.sh >/dev/null

VM_RUNTIME_DIR ?= $(if $(GOLENS_VM_RUNTIME_DIR),$(GOLENS_VM_RUNTIME_DIR),$(HOME)/Library/Application Support/GoLens/VMRuntime)

vm-dev:
	@[ -f "$(VM_RUNTIME_DIR)/vmlinuz" ] || { echo "No Linux runtime in $(VM_RUNTIME_DIR): install it from Settings > Execution or build it with scripts/runtime/build.sh"; exit 1; }
	@cd core && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="-s -w" -o "$(VM_RUNTIME_DIR)/golens-vm-agent" ./cmd/golens-vm-agent
	@scripts/gopls/build.sh "$(VM_RUNTIME_DIR)/goroot/bin/gopls"
	@echo "Replaced the guest agent and gopls in $(VM_RUNTIME_DIR) with this checkout's (development only)"

run: build
	@echo "Launching GoLens IDE..."
	@DYLD_LIBRARY_PATH=core build/GoLens.app/Contents/MacOS/GoLensApp

app: build
	@echo "Packaging build/GoLens.app..."
	@scripts/bundle-app.sh

watch:
	@python3 scripts/watch.py

showcase:
	@echo "Serving GoLens Feature Showcase at http://localhost:8080 ..."
	@python3 -m http.server 8080 --directory site

test:
	@echo "Running core Go test suite (arm64)..."
	@cd core && GOARCH=arm64 go test ./...
	@echo "Running core end-to-end test suite (arm64)..."
	@cd tests/core_e2e && GOARCH=arm64 go test ./...
	@echo "Running Gopilot package test suite..."
	@if [ -z "$$DEVELOPER_DIR" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then \
		cd Packages/GopilotRuntime && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test; \
	else \
		cd Packages/GopilotRuntime && swift test; \
	fi
	@echo "Running Desktop foundation unit test suite..."
	@if [ -z "$$DEVELOPER_DIR" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then \
		DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --test-product GoLensPackageTests --filter GoLensDesktopTests; \
	else \
		swift test --test-product GoLensPackageTests --filter GoLensDesktopTests; \
	fi

test-db:
	@echo "Running database engine tests (PostgreSQL 17, MySQL 8.4 and MariaDB 11.4 in Docker)..."
	@eval "$$(scripts/db/engines.sh up)"; \
	cd core && go test -tags dbengines -count=1 -v ./database/; status=$$?; \
	cd .. && if [ -z "$$KEEP_DB" ]; then scripts/db/engines.sh down 2>/dev/null || true; fi; \
	exit $$status

clean:
	@rm -rf core/libgoagent.dylib core/libgoagent.h GoLensApp .build build

release:
	@scripts/release/tag.sh
