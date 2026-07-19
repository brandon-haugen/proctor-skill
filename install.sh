#!/bin/bash
#
# Install proctor-skill into a project or globally.
#
# Usage:
#   bash install.sh                     # install into current project
#   bash install.sh /path/to/project    # install into a specific project
#   bash install.sh --global            # install globally (~/.claude)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

print_usage() {
  echo "Usage:"
  echo "  bash install.sh                     # install into current project's .claude/"
  echo "  bash install.sh /path/to/project    # install into a specific project"
  echo "  bash install.sh --global            # install globally (~/.claude)"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  print_usage
  exit 0
fi

if [ "${1:-}" = "--global" ]; then
  TARGET_DIR="$HOME/.claude"
  HOOK_CMD="bash $SCRIPT_DIR/.claude/hooks/proctor.sh"
  echo "Installing proctor globally to $TARGET_DIR"
else
  PROJECT_DIR="${1:-.}"
  TARGET_DIR="$PROJECT_DIR/.claude"
  HOOK_CMD="bash .claude/hooks/proctor.sh"
  echo "Installing proctor to $TARGET_DIR"
fi

mkdir -p "$TARGET_DIR/hooks" "$TARGET_DIR/skills/proctor"

cp "$SCRIPT_DIR/.claude/hooks/proctor.sh" "$TARGET_DIR/hooks/proctor.sh"
chmod +x "$TARGET_DIR/hooks/proctor.sh"
echo "  Copied hooks/proctor.sh"

cp "$SCRIPT_DIR/.claude/skills/proctor/SKILL.md" "$TARGET_DIR/skills/proctor/SKILL.md"
echo "  Copied skills/proctor/SKILL.md"

SETTINGS_FILE="$TARGET_DIR/settings.json"

HOOK_ENTRY=$(cat <<HOOKJSON
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "$HOOK_CMD",
      "timeout": 10
    }
  ]
}
HOOKJSON
)

if [ -f "$SETTINGS_FILE" ]; then
  HAS_HOOKS=$(python3 -c "
import json, sys
with open('$SETTINGS_FILE') as f:
    data = json.load(f)
hooks = data.get('hooks', {}).get('PreToolUse', [])
for h in hooks:
    if any('proctor' in hk.get('command', '') for hk in h.get('hooks', [])):
        print('yes')
        sys.exit()
print('no')
")
  if [ "$HAS_HOOKS" = "yes" ]; then
    echo "  Hook already configured in settings.json — skipping"
  else
    python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    data = json.load(f)
hook = json.loads('''$HOOK_ENTRY''')
data.setdefault('hooks', {}).setdefault('PreToolUse', []).append(hook)
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
    echo "  Added hook to existing settings.json"
  fi
else
  cat > "$SETTINGS_FILE" <<SETTINGSJSON
{
  "hooks": {
    "PreToolUse": [
      $HOOK_ENTRY
    ]
  }
}
SETTINGSJSON
  echo "  Created settings.json with hook"
fi

echo ""
echo "Done! Proctor is now active."
echo ""
echo "Configuration (environment variables):"
echo "  PROCTOR_MODE=blocking|advisory        (default: blocking)"
echo "  PROCTOR_PROTECTED_BRANCHES=...        (default: main,master,develop,release/*)"
echo "  PROCTOR_COMMIT_INTERVAL=N             (default: 0 = disabled)"
echo "  PROCTOR_CHANGE_THRESHOLD=N            (default: 0 = disabled)"
