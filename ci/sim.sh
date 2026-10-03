#!/bin/bash
# Simulator scenarios for the Sahm app. The app writes Documents/ci.json ({"stage": ...}) when launched with
# -ciReport YES; this script waits for each stage and asserts its content.
# Usage: ci/sim.sh <generic|personal-ci|wrongkey|deeplink|real>   env: UDID, BID, CI_KEY, APP_KEY (real only)
set -euo pipefail
SCEN="$1"

install_variant() {   # $1 = key for pair.json ("" = the generic IPA)
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" "$BID" >/dev/null 2>&1 || true
  xcrun simctl keychain "$UDID" reset >/dev/null 2>&1 || true
  rm -rf simrun && mkdir simrun
  if [ -n "${1:-}" ]; then
    PAIR_KEY="$1" python3 ci/personalize.py SahmSim.ipa simrun/app.ipa >/dev/null
  else
    cp SahmSim.ipa simrun/app.ipa
  fi
  (cd simrun && unzip -q app.ipa)
  test -x simrun/Payload/Sahm.app/Sahm
  codesign --force --sign - --timestamp=none simrun/Payload/Sahm.app >/dev/null 2>&1
  xcrun simctl install "$UDID" simrun/Payload/Sahm.app
  echo "[$SCEN] installed $( [ -n "${1:-}" ] && echo personal || echo generic ) copy"
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
    xcrun simctl launch "$UDID" "$BID" -ciReport YES -pointerFile p_ci.json >/dev/null
    wait_stage panel 60
    check "ci-$SCEN-panel.json" "d['title'] == 'اربط التطبيق بمنصتك' and d['detail'] == ''"
    sleep 1; shot shot-1-generic-unpaired.png ;;
  personal-ci)    # personal copy (pair.json) -> pairs itself -> pointer -> page loads in the app
    install_variant "$CI_KEY"
    xcrun simctl launch "$UDID" "$BID" -ciReport YES -pointerFile p_ci.json >/dev/null
    wait_stage home 90
    check "ci-$SCEN-home.json" "d['pair_page'] and d['https'] and d['bridge']"
    shot shot-2-personal-autopaired.png ;;
  wrongkey)       # a key that cannot open the real pointer: red message, pairing button
    install_variant ""
    xcrun simctl launch "$UDID" "$BID" -ciReport YES -sahm.pairKey "$CI_KEY" >/dev/null
    wait_stage panel 90
    check "ci-$SCEN-panel.json" "'لم يعد صالح' in d['detail']"
    sleep 1; shot shot-3-wrong-key.png ;;
  deeplink)       # ydsahm:// is registered to this app
    xcrun simctl openurl "$UDID" "ydsahm://pair?k=$CI_KEY"
    sleep 6; shot shot-4-deeplink.png    # iOS asks "Open in سهم?": the scheme belongs to this app
    echo "[$SCEN] ydsahm:// opened the system prompt for the app" ;;
  real)           # the owner's personal copy against the live platform, admin panel included
    install_variant "$APP_KEY"
    xcrun simctl launch "$UDID" "$BID" -ciReport YES -ciAdmin YES >/dev/null
    wait_stage home 150
    check "ci-$SCEN-home.json" "d['strategies'] and d['q1'] and d['m1'] and d['goal'] and not d['auth_error'] and not d['conn_error'] and d['bridge'] and not d['key_in_url'] and d['nav_buttons'] >= 6"
    sleep 6; shot real-1-home.png        # let a system banner (first-boot notices) clear first
    touch "$(container)/Documents/ci-next"
    wait_stage admin 60
    check "ci-$SCEN-admin.json" "d['admin_open'] and d['admin_title'] and d['admin_in_app'] and not d['admin_denied']"
    shot real-2-admin.png ;;
  *) echo "unknown scenario $SCEN"; exit 2 ;;
esac
echo "[$SCEN] OK"
