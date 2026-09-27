#!/usr/bin/env bash
# Helper to copy one of the node scripts to a Pi and run it there.
# Usage: ./run-remote.sh <script-file> <user@host>
# Example: ./run-remote.sh 01-os-prep.sh juangar@192.168.0.63
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <script-file> <user@host>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/$1"
TARGET="$2"
NAME="$(basename "$SCRIPT")"

if [ ! -f "$SCRIPT" ]; then
  echo "No such script: $SCRIPT" >&2
  exit 1
fi

echo "==> Copying $NAME to $TARGET (SSH will prompt for the node's password)"
scp "$SCRIPT" "$TARGET":/tmp/"$NAME"

echo "==> Running $NAME on $TARGET (sudo may prompt for a password too)"
ssh -t "$TARGET" "chmod +x /tmp/$NAME && /tmp/$NAME"
