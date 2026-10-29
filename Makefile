PYTHON ?= python3
APP := build/Cubicon Native.app

.PHONY: build test check-settings check-runtime check-workflow open clean

build:
	$(PYTHON) scripts/build-native.py --output "$(APP)"

check-settings:
	$(PYTHON) native/Tests/check-settings-resolver.py

check-runtime:
	$(PYTHON) native/scripts/verify-native.py --app "$(APP)"

check-workflow:
	$(PYTHON) native/scripts/verify-workflow.py --app "$(APP)"

test: check-settings check-runtime check-workflow

open:
	open "$(APP)"

clean:
	rm -rf build native/build reports
