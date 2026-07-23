#!/bin/bash
#
# Install proctor-skill into a project or globally.
#
# Usage:
#   bash install.sh                              # install for Claude Code into current project
#   bash install.sh /path/to/project             # install for Claude Code into a specific project
#   bash install.sh --global                     # install for Claude Code globally (~/.claude)
#   bash install.sh --copilot                    # install for Copilot in VS Code into current project
#   bash install.sh --copilot /path/to/project   # install for Copilot into a specific project
#   bash install.sh --copilot --global           # install for Copilot globally (~/.copilot)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COPILOT=false
GLOBAL=false
PROJECT_DIR=""

print_usage() {
  local cmd
  cmd=$(basename "$0")
  [ "$cmd" = "proctor-skill" ] && cmd="proctor-skill" || cmd="bash install.sh"
  echo "Usage:"
  echo "  $cmd                              # install for Claude Code into current project"
  echo "  $cmd /path/to/project             # install for Claude Code into a specific project"
  echo "  $cmd --global                     # install for Claude Code globally (~/.claude)"
  echo "  $cmd --copilot                    # install for Copilot in VS Code into current project"
  echo "  $cmd --copilot /path/to/project   # install for Copilot into a specific project"
  echo "  $cmd --copilot --global           # install for Copilot globally (~/.copilot)"
}

for arg in "$@"; do
  case "$arg" in
    --copilot) COPILOT=true ;;
    --global) GLOBAL=true ;;
    --help|-h) print_usage; exit 0 ;;
    *) PROJECT_DIR="$arg" ;;
  esac
done

if [ "$COPILOT" = true ]; then
  if [ "$GLOBAL" = true ]; then
    TARGET_DIR="$HOME/.copilot"
    HOOK_CMD="bash $HOME/.copilot/hooks/proctor.sh"
    echo "Installing proctor for Copilot globally to $TARGET_DIR"
  else
    PROJECT_DIR="${PROJECT_DIR:-.}"
    TARGET_DIR="$PROJECT_DIR/.github"
    HOOK_CMD="bash .github/hooks/proctor.sh"
    echo "Installing proctor for Copilot to $TARGET_DIR"
  fi
else
  if [ "$GLOBAL" = true ]; then
    TARGET_DIR="$HOME/.claude"
    HOOK_CMD="bash $HOME/.claude/hooks/proctor.sh"
    echo "Installing proctor globally to $TARGET_DIR"
  else
    PROJECT_DIR="${PROJECT_DIR:-.}"
    TARGET_DIR="$PROJECT_DIR/.claude"
    HOOK_CMD="bash .claude/hooks/proctor.sh"
    echo "Installing proctor to $TARGET_DIR"
  fi
fi

mkdir -p "$TARGET_DIR/hooks" "$TARGET_DIR/skills/proctor"

cp "$SCRIPT_DIR/.claude/hooks/proctor.sh" "$TARGET_DIR/hooks/proctor.sh"
chmod +x "$TARGET_DIR/hooks/proctor.sh"
echo "  Copied hooks/proctor.sh"

cp "$SCRIPT_DIR/.claude/skills/proctor/SKILL.md" "$TARGET_DIR/skills/proctor/SKILL.md"
echo "  Copied skills/proctor/SKILL.md"

if [ "$COPILOT" = true ]; then
  HOOK_CONFIG="$TARGET_DIR/hooks/proctor.json"
  cat > "$HOOK_CONFIG" <<HOOKJSON
{
  "version": 1,
  "hooks": {
    "preToolUse": [
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
    ]
  }
}
HOOKJSON
  echo "  Created hooks/proctor.json"
else
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
fi

echo ""
echo "Done! Proctor is now active."
echo ""
echo "Configuration (environment variables):"
echo "  PROCTOR_MODE=blocking|advisory        (default: blocking)"
echo "  PROCTOR_PROTECTED_BRANCHES=...        (default: main,master,develop,release/*)"
echo "  PROCTOR_COMMIT_INTERVAL=N             (default: 0 = disabled)"
echo "  PROCTOR_CHANGE_THRESHOLD=N            (default: 0 = disabled)"
