# proctor-skill

A Claude Code skill that quizzes you about branch changes before allowing `git push` or `git merge` into protected branches. Makes sure you actually understand what Claude built instead of rubber-stamping it.

## What it does

When Claude tries to run `git push`, `git merge` (into a protected branch), or `git pull` (on a protected branch), a PreToolUse hook blocks the operation and tells Claude to run the `/proctor` skill. The skill:

1. Diffs the branch to see what changed
2. Generates 1–5 comprehension questions (scaled by diff size)
3. Quizzes you in chat — What does this do? Why this approach? What could go wrong?
4. If you demonstrate understanding, it unblocks the operation
5. If not, it explains the correct answers and re-quizzes with new questions on the same concepts

All answers must be correct — wrong answers are never accepted, and re-quizzes use different questions so you can't just parrot back the explanation.

### Periodic quizzes

For long-running branches, you can trigger quizzes **during development** — not just at push time. Set a commit interval or line-change threshold, and the hook will block `git commit` when you hit the limit. This keeps you learning throughout the session instead of facing one massive quiz at the end.

The periodic quiz only covers changes since the last checkpoint, not the entire branch.

### Key details

- **Protected branches** (default): `main`, `master`, `develop`, `release/*`
- **Markers are commit-based, not time-based.** When you pass a quiz, the marker stores the current HEAD hash. Any new commit automatically invalidates it — so you can't pass a quiz, make 47 more commits, and push without being quizzed again.
- Works in all Claude Code surfaces: CLI, desktop app, web app (claude.ai/code), and IDE extensions.
- Only gates operations **inside Claude Code sessions**. Pushes from a plain terminal or IDE are not affected — the quiz is about ensuring you understand what *Claude* built.

## Installation

### Quick install

```bash
git clone https://github.com/brandon-haugen/proctor-skill.git
cd proctor-skill
bash install.sh /path/to/your-project
```

### Install globally (all projects)

```bash
bash install.sh --global
```

The install script copies the hook and skill files into your project's `.claude/` directory and wires up `settings.json` — merging with your existing settings if you have them.

### Update

To update to the latest version, pull the repo and re-run the install:

```bash
cd proctor-skill
git pull
bash install.sh /path/to/your-project
```

### Uninstall

```bash
bash uninstall.sh /path/to/your-project
# or
bash uninstall.sh --global
```

### Manual install

Copy the hook and skill into your project's `.claude/` directory:

```bash
cp -r .claude/hooks /path/to/your-project/.claude/
cp -r .claude/skills /path/to/your-project/.claude/
```

Then add the hook config to your project's `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/proctor.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PROCTOR_MODE` | `blocking` | `blocking` = must pass quiz. `advisory` = reminder only, doesn't block. |
| `PROCTOR_PROTECTED_BRANCHES` | `main,master,develop,release/*` | Comma-separated branch patterns to protect from unreviewed merges. |
| `PROCTOR_COMMIT_INTERVAL` | `0` (disabled) | Quiz every N commits. E.g., `5` = quiz after every 5 commits on the branch. |
| `PROCTOR_CHANGE_THRESHOLD` | `0` (disabled) | Quiz when total lines changed since last checkpoint exceeds N. E.g., `300` = quiz after 300+ lines of change accumulate. |

### Periodic quiz examples

```bash
# Quiz every 5 commits
export PROCTOR_COMMIT_INTERVAL=5

# Quiz when 300+ lines have changed
export PROCTOR_CHANGE_THRESHOLD=300

# Both — whichever threshold hits first
export PROCTOR_COMMIT_INTERVAL=5
export PROCTOR_CHANGE_THRESHOLD=300
```

## How it works

```
You ask Claude to push or merge into develop
  → Claude calls Bash("git push ...")
    → PreToolUse hook fires, detects git push
      → Checks for a quiz-passed marker matching current HEAD
        → No marker (or HEAD changed)? BLOCKED. "Run /proctor."
  → Claude invokes /proctor
    → Diffs the branch, generates questions, quizzes you
      → You answer in chat
        → All correct? Marker written, push retried automatically
        → Any wrong? Correct answers explained, re-quiz with new questions

Periodic (with PROCTOR_COMMIT_INTERVAL=5):
  → Claude calls Bash("git commit ...")
    → Hook counts 5 commits since last checkpoint
      → BLOCKED. "Run /proctor."
  → Quiz covers only changes since last checkpoint
    → Pass? Checkpoint updated to current HEAD, commit proceeds
```

### What gets caught

| Command | Blocked? |
|---------|----------|
| `git push` | Always |
| `git push origin feature/foo` | Always |
| `git commit && git push` | Always (push gate) |
| `git merge feature/foo` (on `develop`) | Always (protected branch) |
| `git checkout develop && git merge feature/foo` | Always (detects checkout target) |
| `git switch develop && git merge feature/foo` | Always (detects switch target) |
| `git pull` (on `develop`) | Always (protected branch) |
| `git -C /path/to/repo push` | Always (detects -C flag) |
| `git commit -m "fix"` | Only if periodic thresholds are set and exceeded |
| `git merge develop` (on a feature branch) | No — not a protected target |

## Files

```
.claude/
  hooks/
    proctor.sh             # PreToolUse hook — detects push/merge/commit, checks markers
  skills/
    proctor/
      SKILL.md             # Quiz logic — diff analysis, question generation, evaluation
  settings.json            # Hook wiring
install.sh                 # Installer script
uninstall.sh               # Uninstaller script
```
