CORE := Packages/BiomechanicsCore
APP := Apps/FlowMac

# On a Command Line Tools-only toolchain SwiftPM only discovers the Testing framework
# when its search path is passed on the command line (manifest flags are not enough).
ACTIVE_DEVELOPER_DIR := $(shell xcode-select -p 2>/dev/null)
ifneq (,$(findstring CommandLineTools,$(ACTIVE_DEVELOPER_DIR)))
TEST_FLAGS := -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
endif

.PHONY: all test build run clean

all: test build

test:
	swift test --package-path $(CORE) $(TEST_FLAGS)

build:
	swift build --package-path $(APP)

run:
	swift run --package-path $(APP) FlowMac

clean:
	rm -rf $(CORE)/.build $(APP)/.build
