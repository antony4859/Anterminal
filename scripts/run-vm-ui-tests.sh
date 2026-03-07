#!/usr/bin/env bash
set -euo pipefail

SSH_TARGET="${CMUX_VM_SSH_TARGET:-cmux-vm}"
REMOTE_DIR="${CMUX_VM_REMOTE_DIR:-/Users/cmux/GhosttyTabs}"
PROJECT="${CMUX_VM_PROJECT:-GhosttyTabs.xcodeproj}"
SCHEME="${CMUX_VM_SCHEME:-cmux}"

usage() {
  cat <<'EOF'
Run macOS UI tests on the dedicated VM over SSH.

Environment overrides:
  CMUX_VM_SSH_TARGET   SSH target to reach the VM (default: cmux-vm)
  CMUX_VM_REMOTE_DIR   Repo path on the VM (default: /Users/cmux/GhosttyTabs)
  CMUX_VM_PROJECT      Xcode project on the VM (default: GhosttyTabs.xcodeproj)
  CMUX_VM_SCHEME       Xcode scheme on the VM (default: cmux)

Examples:
  ./scripts/run-vm-ui-tests.sh
  CMUX_VM_SSH_TARGET=cmux@192.168.1.50 ./scripts/run-vm-ui-tests.sh
  CMUX_VM_SSH_TARGET='cmux@192.168.1.50' ./scripts/run-vm-ui-tests.sh -only-testing:cmuxUITests/UpdatePillUITests test

If no xcodebuild arguments are supplied, the script runs:
  -only-testing:cmuxUITests test
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [ "$#" -eq 0 ]; then
  XCODE_ARGS=(-only-testing:cmuxUITests test)
else
  XCODE_ARGS=("$@")
fi

PRECHECK_CMD="hostname; id -un; test -d $(printf '%q' "$REMOTE_DIR")"

if ! ssh -o ConnectTimeout=5 "$SSH_TARGET" "$PRECHECK_CMD" >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: Unable to reach the VM with SSH target '$SSH_TARGET'.

Fix one of these:
  1. Configure an SSH alias named 'cmux-vm'
  2. Or set CMUX_VM_SSH_TARGET to a reachable target, for example:
       CMUX_VM_SSH_TARGET=cmux@192.168.1.50 ./scripts/run-vm-ui-tests.sh

Optional override if the repo lives elsewhere on the VM:
  CMUX_VM_REMOTE_DIR=/path/to/repo
EOF
  exit 2
fi

printf -v XCODE_CMD '%q ' \
  xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=macOS" \
  "${XCODE_ARGS[@]}"

REMOTE_CMD="cd $(printf '%q' "$REMOTE_DIR") && ${XCODE_CMD}"
exec ssh "$SSH_TARGET" "$REMOTE_CMD"
