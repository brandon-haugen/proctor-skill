#!/bin/bash
#
# Uninstall proctor-skill from a project or globally.
#
# Usage:
#   bash uninstall.sh                     # uninstall from current project
#   bash uninstall.sh /path/to/project    # uninstall from a specific project
#   bash uninstall.sh --global            # uninstall globally (~/.claude)

set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "Usage:"
  echo "  bash uninstall.sh                     # uninstall from current project's .claude/"
  echo "  bash uninstall.sh /path/to/project    # uninstall from a specific project"
  echo "  bash uninstall.sh --global            # uninstall globally (~/.claude)"
  exit 0
fi

if [ "${1:-}" = "--global" ]; then
  TARGET_DIR="$HOME/.claude"
  echo "Uninstalling proctor from $TARGET_DIR"
else
  PROJECT_DIR="${1:-.}"
  TARGET_DIR="$PROJECT_DIR/.claude"
  echo "Uninstalling proctor from $TARGET_DIR"
fi

if [ -f "$TARGET_DIR/hooks/proctor.sh" ]; then
  rm "$TARGET_DIR/hooks/proctor.sh"
  echo "  Removed hooks/proctor.sh"
  rmdir "$TARGET_DIR/hooks" 2>/dev/null && echo "  Removed empty hooks/" || true
fi

if [ -d "$TARGET_DIR/skills/proctor" ]; then
  rm -r "$TARGET_DIR/skills/proctor"
  echo "  Removed skills/proctor/"
  rmdir "$TARGET_DIR/skills" 2>/dev/null && echo "  Removed empty skills/" || true
fi

SETTINGS_FILE="$TARGET_DIR/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
  python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    data = json.load(f)
pre = data.get('hooks', {}).get('PreToolUse', [])
data['hooks']['PreToolUse'] = [
    h for h in pre
    if not any('proctor' in hk.get('command', '') for hk in h.get('hooks', []))
]
if not data['hooks']['PreToolUse']:
    del data['hooks']['PreToolUse']
if not data.get('hooks'):
    del data['hooks']
if data:
    with open('$SETTINGS_FILE', 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    print('  Removed hook from settings.json')
else:
    import os
    os.remove('$SETTINGS_FILE')
    print('  Removed empty settings.json')
"
fi

rm -rf /tmp/proctor 2>/dev/null && echo "  Cleaned up marker files" || true

echo ""
echo "Done! Proctor has been removed."
