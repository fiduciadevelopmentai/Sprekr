SHELL := /bin/zsh

.PHONY: bootstrap build test integration-test run package install update uninstall doctor audit clean

# The macOS Command Line Tools bundle Swift Testing separately from the Swift
# runtime. Keep this development-only wiring in the test command rather than
# embedding machine-specific paths in Package.swift.
DEVELOPER_DIR ?= $(shell xcode-select -p)
SWIFT_TESTING_FRAMEWORKS := $(DEVELOPER_DIR)/Library/Developer/Frameworks
SWIFT_TESTING_RUNTIME := $(DEVELOPER_DIR)/Library/Developer/usr/lib
SWIFT_TEST_FLAGS := --enable-swift-testing

ifneq ($(wildcard $(SWIFT_TESTING_FRAMEWORKS)/Testing.framework),)
SWIFT_TEST_FLAGS += \
	-Xswiftc -F -Xswiftc "$(SWIFT_TESTING_FRAMEWORKS)" \
	-Xswiftc -Xlinker -Xswiftc -rpath \
	-Xswiftc -Xlinker -Xswiftc "$(SWIFT_TESTING_FRAMEWORKS)" \
	-Xswiftc -Xlinker -Xswiftc -rpath \
	-Xswiftc -Xlinker -Xswiftc "$(SWIFT_TESTING_RUNTIME)"
endif

bootstrap:
	swift package resolve

build:
	./scripts/build-app.sh debug

test:
	xcrun swift test $(SWIFT_TEST_FLAGS)
	"$$(xcrun swift build --show-bin-path)/sprekr-test-runner"

integration-test:
	./scripts/integration-test.sh

run: build
	open "./build/debug/Sprekr.app"

package:
	./scripts/package.sh

install:
	./scripts/install.sh --source

update:
	./scripts/update.sh --source

uninstall:
	./scripts/uninstall.sh

doctor:
	./scripts/doctor.sh

audit:
	./scripts/prepublish-audit.sh

clean:
	rm -rf .build build dist
