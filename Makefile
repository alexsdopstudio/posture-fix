CORE := Packages/BiomechanicsCore
APP := Apps/FlowMac
PHONE := Apps/FlowPhone
PHONE_SIMULATOR ?= iPhone 18 Pro

# On a Command Line Tools-only toolchain SwiftPM only discovers the Testing framework
# when its search path is passed on the command line (manifest flags are not enough).
ACTIVE_DEVELOPER_DIR := $(shell xcode-select -p 2>/dev/null)
ifneq (,$(findstring CommandLineTools,$(ACTIVE_DEVELOPER_DIR)))
TEST_FLAGS := -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
endif

.PHONY: all test build run phone phone-run clean

all: test build

test:
	swift test --package-path $(CORE) $(TEST_FLAGS)

build:
	swift build --package-path $(APP)

run:
	swift run --package-path $(APP) FlowMac

# iPhone app (simulator only for now: no Apple Developer account yet). Needs Xcode + XcodeGen.
phone:
	cd $(PHONE) && xcodegen generate
	xcodebuild -project $(PHONE)/FlowPhone.xcodeproj -scheme FlowPhone \
		-destination 'platform=iOS Simulator,name=$(PHONE_SIMULATOR)' \
		-derivedDataPath $(PHONE)/.build CODE_SIGNING_ALLOWED=NO build

phone-run: phone
	xcrun simctl boot "$(PHONE_SIMULATOR)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(PHONE_SIMULATOR)" $(PHONE)/.build/Build/Products/Debug-iphonesimulator/FlowPhone.app
	xcrun simctl launch "$(PHONE_SIMULATOR)" studio.alexsdop.FlowPhone

clean:
	rm -rf $(CORE)/.build $(APP)/.build $(PHONE)/.build
