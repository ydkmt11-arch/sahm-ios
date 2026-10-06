#!/bin/bash
# Simulator scenarios for the Sahm app. The app writes Documents/ci.json ({"stage": ...}) when launched with
# -ciReport YES; this script waits for each stage and asserts its content.
# Usage: ci/sim.sh <generic|personal-ci|wrongkey|firstlaunch|deeplink|real>   env: UDID, BID, CI_KEY, APP_KEY (real only)
set -euo pipefail
SCEN="$1"

install_variant() {   # $1 = key for pair.json ("" = the generic IPA), $2 = interface folder built into the IPA
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" "$BID" >/dev/null 2>&1 || true
  xcrun simctl keychain "$UDID" reset >/dev/null 2>&1 || true
  rm -rf simrun && mkdir simrun
  if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
    PAIR_KEY="$1" WWW_DIR="$2" WWW_BUILT_AT="2000-01-01T00:00:00Z" python3 ci/personalize.py SahmSim.ipa simrun/app.ipa
  elif [ -n "${1:-}" ]; then
    PAIR_KEY="$1" python3 ci/personalize.py SahmSim.ipa simrun/app.ipa >/dev/null
  else
    cp SahmSim.ipa simrun/app.ipa
  fi
  (cd simrun && unzip -q app.ipa)
  test -x simrun/Payload/Sahm.app/Sahm
  codesign --force --sign - --timestamp=none simrun/Payload/Sahm.app >/dev/null 2>&1
  xcrun simctl install "$UDID" simrun/Payload/Sahm.app
  echo "[$SCEN] installed $( [ -n "${1:-}" ] && echo personal || echo generic ) copy$( [ -n "${2:-}" ] && echo ' with a built-in interface' || true )"
}

container() { xcrun simctl get_app_container "$UDID" "$BID" data 2>/dev/null || true; }

shot() { xcrun simctl io "$UDID" screenshot "$1" >/dev/null 2>&1; echo "[$SCEN] screenshot $1"; }

wait_stage() {   # $1 = stage, $2 = seconds
  local c="" f=""
  for _ in $(seq 1 "$2"); do
    c=$(container)
    f="$c/Documents/ci.json"
    if [ -n "$c" ] && [ -f "$f" ] && python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get('stage')==sys.argv[2] else 1)" "$f" "$1" 2>/dev/null; then
      cp "$f" "ci-$SCEN-$1.json"
      echo "[$SCEN] stage $1: $(cat "$f")"
      return 0
    fi
    sleep 1
  done
  echo "[$SCEN] TIMEOUT waiting for stage '$1'"
  if [ -n "$c" ] && [ -f "$c/Documents/ci.json" ]; then echo "[$SCEN] last report: $(cat "$c/Documents/ci.json")"; fi
  shot "$SCEN-timeout.png"
  return 1
}

check() {   # $1 = report file, $2 = Python expression over d
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = bool(eval(sys.argv[2], {}, {"d": d}))
print(("PASS  " if ok else "FAIL  ") + sys.argv[2])
sys.exit(0 if ok else 1)
PY
}

case "$SCEN" in
  generic)        # public IPA, never paired: the pairing panel
    install_variant ""
    xcrun simctl launch "$UDID" "$BID" -ciNoPrompt YES -ciReport YES -pointerFile p_ci.json >/dev/null
    wait_stage panel 60
    check "ci-$SCEN-panel.json" "d['title'] == 'اربط التطبيق بمنصتك' and d['detail'] == ''"
    sleep 1; shot shot-1-generic-unpaired.png ;;
  personal-ci)    # interface built into the IPA, runs from the phone, then updates itself from the server
    install_variant "$CI_KEY" ci/www-test
    xcrun simctl launch "$UDID" "$BID" -ciNoPrompt YES -ciReport YES -pointerFile p_ci.json >/dev/null
    wait_stage home 60
    check "ci-$SCEN-home.json" "d['ci_marker'] == 'CI-UI-1' and d['bridge'] and d['ui_builtin'] and d['scheme'] == 'sahmui:'"
    shot shot-2-built-in-interface.png
    wait_stage updated 120
    check "ci-$SCEN-updated.json" "d['ci_marker'] == 'CI-UI-2' and d['ui_updated'] and not d['ui_builtin'] and d['proxy'] == '200:ok'"
    sleep 1; shot shot-3-self-updated.png ;;
  wrongkey)       # a key that cannot open the real pointer: red message, pairing button
    install_variant ""
    xcrun simctl launch "$UDID" "$BID" -ciNoPrompt YES -ciReport YES -sahm.pairKey "$CI_KEY" >/dev/null
    wait_stage panel 90
    check "ci-$SCEN-panel.json" "'لم يعد صالح' in d['detail']"
    sleep 1; shot shot-4-wrong-key.png ;;
  firstlaunch)    # v1.4: the system permission sheet appears by itself on the very first launch (no -ciNoPrompt)
    install_variant ""
    xcrun simctl launch "$UDID" "$BID" -ciReport YES -ciFirstReport YES -pointerFile p_ci.json >/dev/null
    wait_stage first 90
    # nobody taps in CI, so the sheet stays on screen and the status is still notDetermined: «prompted» proves the
    # app asked iOS by itself, without any switch being touched
    check "ci-$SCEN-first.json" "d['notify']['asked'] and d['notify']['prompted'] and d['notify']['device_len'] == 32 and d['notify']['status'] == 'notDetermined'"
    sleep 3; shot shot-6-first-launch-permission.png
    xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$UDID" "$BID" >/dev/null 2>&1 || true   # the system sheet goes with the app
    echo "[$SCEN] the first launch asked for notification permission by itself" ;;
  deeplink)       # ydsahm:// is registered to this app
    xcrun simctl openurl "$UDID" "ydsahm://pair?k=$CI_KEY"
    sleep 6; shot shot-5-deeplink.png    # iOS asks "Open in سهم?": the scheme belongs to this app
    echo "[$SCEN] ydsahm:// opened the system prompt for the app" ;;
  real)           # the owner's copy on the live platform: interface downloaded from the PC, admin panel, then PC "off"
    install_variant "$APP_KEY"
    xcrun simctl launch "$UDID" "$BID" -ciNoPrompt YES -ciReport YES -ciAdmin YES >/dev/null
    wait_stage home 180
    check "ci-$SCEN-home.json" "d['strategies'] and d['q1'] and d['m1'] and d['goal'] and not d['auth_error'] and not d['conn_error'] and d['bridge'] and not d['key_in_url'] and d['nav_buttons'] >= 5 and d['scheme'] == 'sahmui:' and not d['ui_builtin'] and len(d['ui_version']) == 12 and d['notify_bridge'] and d['notify_feed'].startswith('200:') and d['notify']['device_len'] == 32"
    sleep 6; shot real-1-home.png        # let a system banner (first-boot notices) clear first
    touch "$(container)/Documents/ci-next"
    wait_stage admin 60
    check "ci-$SCEN-admin.json" "d['admin_open'] and d['admin_title'] and d['admin_in_app'] and not d['admin_denied']"
    shot real-2-admin.png
    xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
    rm -f "$(container)/Documents/ci.json" "$(container)/Documents/ci-next"
    xcrun simctl launch "$UDID" "$BID" -ciNoPrompt YES -ciReport YES -ciForceOffline YES -ciStage offline >/dev/null
    wait_stage offline 90
    check "ci-$SCEN-offline.json" "d['offline'] and d['strategies'] and d['q1'] and d['m1'] and d['scheme'] == 'sahmui:'"
    sleep 2; shot real-3-offline.png ;;
  *) echo "unknown scenario $SCEN"; exit 2 ;;
esac
echo "[$SCEN] OK"
