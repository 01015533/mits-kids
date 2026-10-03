#!/usr/bin/env bash
set -euo pipefail
mits_project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$mits_project"
mits_device=${1:-emulator-5554}
[[ "$mits_device" =~ ^emulator-[0-9]+$ ]] || { printf '%s\n' 'Only a local emulator ID is accepted.' >&2; exit 1; }
mits_adb=${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}/platform-tools/adb
export MITS_VALIDATION_BUILD=1
flutter test integration_test/live_download_test.dart --no-pub --no-uninstall -d "$mits_device" --reporter expanded
mits_wifi=$("$mits_adb" -s "$mits_device" shell settings get global wifi_on | tr -d '\r')
mits_data=$("$mits_adb" -s "$mits_device" shell settings get global mobile_data | tr -d '\r')
mits_cellular=$("$mits_adb" -s "$mits_device" shell pm list features | tr -d '\r' | rg -c '^feature:android.hardware.telephony$' || true)
restore_network() {
  if [[ "$mits_wifi" != "0" ]]; then "$mits_adb" -s "$mits_device" shell svc wifi enable; fi
  if [[ "$mits_cellular" == "1" && "$mits_data" == "1" ]]; then "$mits_adb" -s "$mits_device" shell svc data enable; fi
}
trap restore_network EXIT
"$mits_adb" -s "$mits_device" shell am force-stop com.example.mits_kids_youtube.validation
"$mits_adb" -s "$mits_device" shell svc wifi disable
if [[ "$mits_cellular" == "1" ]]; then
  "$mits_adb" -s "$mits_device" shell svc data disable
fi
test "$("$mits_adb" -s "$mits_device" shell settings get global wifi_on | tr -d '\r')" = 0
if [[ "$mits_cellular" == "1" ]]; then
  test "$("$mits_adb" -s "$mits_device" shell settings get global mobile_data | tr -d '\r')" = 0
  printf '%s\n' 'Verified inside Android: Wi-Fi off, mobile data off; validation app force-stopped.'
else
  printf '%s\n' 'Verified inside Android: Wi-Fi off, no cellular hardware feature; validation app force-stopped.'
fi
flutter test integration_test/live_download_test.dart --no-pub --no-uninstall -d "$mits_device" --dart-define=MITS_OFFLINE_CHECK=true --reporter expanded
