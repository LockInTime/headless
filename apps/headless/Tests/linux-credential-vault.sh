#!/bin/sh
set -eu

RUNTIME_DIR="/run/user/$(id -u)"
BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus"
BUS_PID=""
ORIGIN="https://credentials.example.test"
ALIAS="ci-work"
RENAMED_ALIAS="ci-renamed"
ACCOUNT="vault-user@example.test"
PASSWORD="synthetic-vault-password"

cleanup() {
  gnome-keyring-daemon --shutdown >/dev/null 2>&1 || true
  if [ -n "$BUS_PID" ]; then kill "$BUS_PID" >/dev/null 2>&1 || true; fi
  rm -rf "$HOME/.local/share/headless/credential-vault"
  rm -rf "$HOME/.local/share/keyrings"
  rm -f "$RUNTIME_DIR/bus"
}
trap cleanup EXIT INT TERM

UNTRUSTED_BUS="unix:path=/tmp/headless-untrusted-session-bus"
if RESULT="$(DBUS_SESSION_BUS_ADDRESS="$UNTRUSTED_BUS" headless credentials list 2>&1)"; then
  echo "caller-selected D-Bus address was accepted without the canonical user bus" >&2
  exit 1
fi
echo "$RESULT" | grep -q 'VAULT_UNAVAILABLE'

dbus-daemon --session --address="$BUS_ADDRESS" --fork --print-pid=1 > "$RUNTIME_DIR/dbus.pid"
BUS_PID="$(cat "$RUNTIME_DIR/dbus.pid")"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export DBUS_SESSION_BUS_ADDRESS="$BUS_ADDRESS"
KEYRING_ENV="$(printf '%s' 'synthetic-keyring-password' | \
  gnome-keyring-daemon --unlock --components=secrets)"
eval "$KEYRING_ENV"

expect <<EOF
set timeout 15
log_user 0
spawn headless credentials add --origin $ORIGIN --alias $ALIAS --interactive
expect "Account username/email: "
send "$ACCOUNT\r"
expect "Password: "
send "$PASSWORD\r"
expect "Confirm password: "
send "$PASSWORD\r"
expect eof
set result [wait]
exit [lindex \$result 3]
EOF

LISTING="$(DBUS_SESSION_BUS_ADDRESS="$UNTRUSTED_BUS" \
  headless credentials list --origin "$ORIGIN")"
echo "$LISTING" | grep -q "$ALIAS"
echo "$LISTING" | grep -q "$ACCOUNT"
if echo "$LISTING" | grep -q "$PASSWORD"; then
  echo "credential listing exposed a password" >&2
  exit 1
fi
secret-tool search application com.headless.credentials.v1 >/dev/null

headless credentials rename --origin "$ORIGIN" --alias "$ALIAS" \
  --to "$RENAMED_ALIAS" | grep -q '"renamed":true'
headless credentials list --origin "$ORIGIN" | grep -q "$RENAMED_ALIAS"
headless credentials remove --origin "$ORIGIN" --alias "$RENAMED_ALIAS" \
  | grep -q '"removed":true'
if [ -n "$(secret-tool search application com.headless.credentials.v1 2>/dev/null)" ]; then
  echo "removed credential remained in Secret Service" >&2
  exit 1
fi

INDEX="$HOME/.local/share/headless/credential-vault/credentials-index.json"
test "$(stat -c %a "$INDEX")" = "600"
test "$(stat -c %a "$(dirname "$INDEX")")" = "700"
if grep -q "$PASSWORD" "$INDEX"; then
  echo "credential index contained a password" >&2
  exit 1
fi

echo "Linux Secret Service credential lifecycle passed"
