#!/usr/bin/env bash
# Install the simulator build, run the headless self-test, collect results.
#   selftest-sim.sh <Harbor.app> <results-dir> [device-type] [extra launch args...]
set -uo pipefail
APP="$1"; OUT="$2"; DEVTYPE="${3:-iPhone 15}"; shift 3 || true
mkdir -p "$OUT"
BUNDLE=app.harbor.cli
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(sorted(r,key=lambda x:x["version"])[-1]["identifier"])')
echo "runtime: $RUNTIME"
UDID=$(xcrun simctl create "selftest" "$DEVTYPE" "$RUNTIME")
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
echo "data container: $DATA"
# Optional secret for the stream-json conversation step.
SIMCTL_CHILD_CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}" \
  xcrun simctl launch "$UDID" "$BUNDLE" --selftest "$@" > "$OUT/launch.txt" 2>&1
APP_PID=$(grep -oE '[0-9]+$' "$OUT/launch.txt" | tail -1)
echo "app pid: ${APP_PID:-unknown}"
START=$(date +%s)
TIMEOUT=${SELFTEST_TIMEOUT:-1500}
while :; do
  if [ -f "$DATA/Documents/selftest/report.json" ] && grep -q '"finished"' "$DATA/Documents/selftest/report.json"; then break; fi
  # Simulator apps are host processes: check the PID simctl reported.
  if [ -n "$APP_PID" ] && ! kill -0 "$APP_PID" 2>/dev/null; then
    sleep 3
    grep -q '"finished"' "$DATA/Documents/selftest/report.json" 2>/dev/null || { echo "app (pid $APP_PID) exited before finishing"; break; }
  fi
  [ $(( $(date +%s) - START )) -gt "$TIMEOUT" ] && { echo "self-test timed out"; break; }
  sleep 5
done
echo "self-test took $(( $(date +%s) - START )) s"
cp -R "$DATA/Documents/selftest" "$OUT/" 2>/dev/null || true
cp -R "$DATA/Documents/logs" "$OUT/" 2>/dev/null || true
# Crash reports for the app process, if any.
find ~/Library/Logs/DiagnosticReports -newermt "@$START" \( -name '*Harbor*' -o -name '*.ips' \) -exec cp {} "$OUT/" \; 2>/dev/null || true
xcrun simctl spawn "$UDID" log show --last 30m --style compact --predicate 'subsystem BEGINSWITH "cli."' > "$OUT/oslog.txt" 2>/dev/null || true
# Redact anything token-shaped from every collected text file.
find "$OUT" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.json' -o -name '*.ips' \) -exec \
  perl -pi -e 's/sk-ant-[A-Za-z0-9_\-]+/sk-ant-REDACTED/g' {} +
xcrun simctl shutdown "$UDID" || true
xcrun simctl delete "$UDID" || true
test -f "$OUT/selftest/report.json" && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("PASSED" if r.get("passed") else "FAILED"); [print(("ok  " if s["ok"] else "FAIL"), s["name"], round(s["seconds"],1), s["detail"][:300]) for s in r["steps"]]' "$OUT/selftest/report.json"
