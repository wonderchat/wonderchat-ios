#!/usr/bin/env bash
# End-to-end verification of the iOS SDK against a running local Wonderchat
# server: builds the SDK, generates and builds the example app, runs the UI
# test on a simulator, then checks the database.
#
# Environment:
#   WONDERCHAT_REPO        wonderchat checkout with scripts/mobile-e2e/sql.sh
#   WONDERCHAT_BASE_URL    default http://localhost:3100
#   WONDERCHAT_CHATBOT_ID  default mobile-e2e-bot
#   SIMULATOR_NAME         default "iPhone 17 Pro"
#   HARNESS_PORT           default 8765
#   WONDERCHAT_BUILD_DIR   build output and logs, default .build/
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WONDERCHAT_REPO="${WONDERCHAT_REPO:-/Users/luketan/Desktop/wonderchat/.claude/worktrees/mobile-app-sdk}"
BASE_URL="${WONDERCHAT_BASE_URL:-http://localhost:3100}"
CHATBOT_ID="${WONDERCHAT_CHATBOT_ID:-mobile-e2e-bot}"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
HARNESS_PORT="${HARNESS_PORT:-8765}"
BUNDLE_ID="com.wonderchat.example"
FAKE_TOKEN="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
SQL="$WONDERCHAT_REPO/scripts/mobile-e2e/sql.sh"
BUILD_DIR="${WONDERCHAT_BUILD_DIR:-$ROOT/.build}"
OUT="$BUILD_DIR/verify"
DERIVED="$BUILD_DIR/example"

mkdir -p "$OUT"
RESULTS=()
FAILED=0

pass() { RESULTS+=("PASS  $1"); echo "PASS  $1"; }
fail() { RESULTS+=("FAIL  $1"); echo "FAIL  $1"; FAILED=1; }

summary() {
  echo
  echo "================ verify.sh summary ================"
  printf '%s\n' "${RESULTS[@]}"
  if [[ $FAILED -eq 0 ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL (logs in $OUT)"; fi
  echo "==================================================="
}

abort() { fail "$1"; summary; exit 1; }

sql() { (cd "$WONDERCHAT_REPO" && "$SQL"); }

json_get() { python3 -I -c 'import json,sys; rows=json.load(sys.stdin); print(rows[0].get(sys.argv[1], "") if rows else "")' "$1"; }

check_disk() {
  local free_kb
  free_kb="$(df -k "$BUILD_DIR" | awk 'NR==2 {print $4}')"
  (( free_kb > 1048576 )) || abort "less than 1 GB free disk space before $1"
}

# 0. Preconditions
[[ -x "$SQL" ]] || abort "sql.sh not found at $SQL (set WONDERCHAT_REPO)"
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$BASE_URL/chatbot/$CHATBOT_ID?wcHost=ios")"
[[ "$status" == "200" ]] || abort "Wonderchat server not reachable at $BASE_URL (HTTP $status)"
pass "server reachable at $BASE_URL"

# 1. SDK
check_disk "the SDK build"
echo "Building the SDK for iOS Simulator..."
if (cd "$ROOT" && xcodebuild -scheme Wonderchat -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$BUILD_DIR/sdk" build) >"$OUT/sdk-build.log" 2>&1; then
  pass "SDK builds (iOS Simulator)"
else
  abort "SDK build (see $OUT/sdk-build.log)"
fi

# 2. Example app
"$ROOT/scripts/generate-example.sh" >"$OUT/xcodegen.log" 2>&1 || abort "XcodeGen (see $OUT/xcodegen.log)"
pass "example project generated"

# 3. Simulator
UDID="$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
name = sys.argv[1]
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime if d["isAvailable"]]
match = [d for d in devices if d["name"] == name] or [d for d in devices if d["name"].startswith("iPhone")]
print(match[0]["udid"] if match else "")' "$SIMULATOR_NAME")"
[[ -n "$UDID" ]] || abort "no available iPhone simulator"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || abort "simulator $UDID did not boot"
open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
pass "simulator booted ($SIMULATOR_NAME, $UDID)"

check_disk "the example build"
echo "Building the example app and UI tests..."
if xcodebuild -project "$ROOT/Example/WonderchatExample.xcodeproj" -scheme WonderchatExample \
     -destination "id=$UDID" -derivedDataPath "$DERIVED" build-for-testing >"$OUT/example-build.log" 2>&1; then
  pass "example app + UI tests build"
else
  abort "example build (see $OUT/example-build.log)"
fi

# Fresh install: no stored conversation, no notification permission.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

# 4. Harness + UI test
python3 -I "$ROOT/scripts/harness_server.py" "$HARNESS_PORT" "$SQL" "$WONDERCHAT_REPO" "$CHATBOT_ID" "$UDID" "$BUNDLE_ID" \
  >"$OUT/harness.log" 2>&1 &
HARNESS_PID=$!
trap 'kill $HARNESS_PID 2>/dev/null' EXIT
sleep 1
kill -0 "$HARNESS_PID" 2>/dev/null || abort "harness server failed to start (see $OUT/harness.log)"

rm -rf "$OUT/UITests.xcresult"
echo "Running UI tests (the bot's answer uses a real LLM, allow a few minutes)..."
TEST_RUNNER_WONDERCHAT_BASE_URL="$BASE_URL" \
TEST_RUNNER_WONDERCHAT_CHATBOT_ID="$CHATBOT_ID" \
TEST_RUNNER_WONDERCHAT_HARNESS_URL="http://127.0.0.1:$HARNESS_PORT" \
xcodebuild -project "$ROOT/Example/WonderchatExample.xcodeproj" -scheme WonderchatExample \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" -resultBundlePath "$OUT/UITests.xcresult" \
  test-without-building >"$OUT/ui-tests.log" 2>&1
UI_STATUS=$?
grep -E "WONDERCHAT_E2E" "$OUT/ui-tests.log" | sed 's/^/      /' | sort -u
if [[ $UI_STATUS -eq 0 ]]; then
  pass "UI test: setup check, bot reply, close, unread badge, push opens chat"
else
  grep -E "error:|failed" "$OUT/ui-tests.log" | head -5 | sed 's/^/      /'
  fail "UI test (see $OUT/ui-tests.log and UITests.xcresult)"
fi

# 5. Database
CHATLOG_ID="$(echo "select c.id from \"Chatlog\" c join \"ChatMessage\" m on m.\"chatlogId\" = c.id
  where c.\"chatbotId\" = '$CHATBOT_ID' and m.\"userMessage\" = 'Hello from setup'
  order by m.\"createdAt\" desc limit 1;" | sql | json_get id)"
if [[ -n "$CHATLOG_ID" ]]; then
  pass "DB: ChatMessage 'Hello from setup' for $CHATBOT_ID (chatlog $CHATLOG_ID)"
else
  fail "DB: no ChatMessage 'Hello from setup' for $CHATBOT_ID"
fi

if [[ -n "$CHATLOG_ID" ]]; then
  BOT_REPLY="$(echo "select left(\"botMessage\", 80) as reply from \"ChatMessage\"
    where \"chatlogId\" = '$CHATLOG_ID' and \"userMessage\" = 'Hello from setup' and coalesce(\"botMessage\", '') <> ''
    limit 1;" | sql | json_get reply)"
  if [[ -n "$BOT_REPLY" ]]; then pass "DB: bot replied (\"$BOT_REPLY...\")"; else fail "DB: no bot reply stored"; fi

  DEVICE="$(echo "select id from \"MobileDevice\" where \"chatlogId\" = '$CHATLOG_ID'
    and provider = 'APNS' and \"pushToken\" = '$FAKE_TOKEN' limit 1;" | sql | json_get id)"
  if [[ -n "$DEVICE" ]]; then
    pass "DB: MobileDevice APNS with the fake token bound to the chatlog"
  else
    fail "DB: no MobileDevice (APNS, fake token) for chatlog $CHATLOG_ID"
  fi
fi

summary
[[ $FAILED -eq 0 ]]
