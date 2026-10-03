#!/usr/bin/env bash
# Tests only the separate validation app on an explicitly named local emulator.
set -euo pipefail
mits_project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$mits_project"
mits_device=${1:-emulator-5554}
if [[ ! "$mits_device" =~ ^emulator-[0-9]+$ ]]; then
  printf '%s\n' 'Refusing to target a physical device. Supply a local emulator ID.' >&2
  exit 1
fi
export MITS_VALIDATION_BUILD=1
flutter test integration_test/native_acceptance_test.dart --no-pub --no-uninstall -d "$mits_device" --reporter expanded
