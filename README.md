# proctor-skill

A skill that quizzes you about branch changes before allowing `git push` or `git merge` into protected branches. Makes sure you actually understand what your AI assistant built instead of rubber-stamping it.

Works with **Claude Code** and **Copilot in VS Code** (agent mode).

## What it does

When your AI assistant tries to run `git push`, `git merge` (into a protected branch), or `git pull` (on a protected branch), a PreToolUse hook blocks the operation and tells it to run the `/proctor` skill. The skill:

1. Diffs the branch to see what changed
2. Generates 1–5 comprehension questions (scaled by diff size)
3. Quizzes you in chat — What does this do? Why this approach? What could go wrong?
4. If you demonstrate understanding, it unblocks the operation
5. If not, it explains the correct answers and re-quizzes with new questions on the same concepts

All answers must be correct — wrong answers are never accepted, and re-quizzes use different questions so you can't just parrot back the explanation.

### Periodic quizzes

For long-running branches, you can trigger quizzes **during development** — not just at push time. Set a commit interval or line-change threshold, and the hook will block `git commit` when you hit the limit. This keeps you learning throughout the session instead of facing one massive quiz at the end.

The periodic quiz only covers changes since the last checkpoint, not the entire branch.

### Quiz summary

See your quiz history and identify areas where you've struggled:

```
/proctor summary
/proctor summary for feature/auth
```

The summary shows:
- **Overview**: total quizzes, first-attempt pass rate, per-category breakdown (What/Why/Risk)
- **Trouble spots**: files and concepts you've failed on repeatedly, with commit references so you can find the relevant code in git history
- **Recent history**: last 5–10 quizzes with date, branch, operation, and outcome

Quiz history is stored in `~/.proctor/history.jsonl` and persists across sessions. Each entry includes the commit hash and files from the diff, so the summary can point you to specific spots in your git history where you had trouble.

### Key details

- **Protected branches** (default): `main`, `master`, `develop`, `release/*`
- **Markers are content-based, not time-based.** When you pass a quiz, the marker stores the current HEAD hash and a diff content hash. Any actual code change invalidates it — so you can't pass a quiz, make 47 more commits, and push without being quizzed again. Content-preserving rebases don't invalidate markers.
- Works in all Claude Code surfaces (CLI, desktop app, web app, IDE extensions) and Copilot in VS Code (agent mode).
- Only gates operations **inside AI coding sessions**. Pushes from a plain terminal are not affected — the quiz is about ensuring you understand what *your AI assistant* built.

## Installation

### skills.sh

```bash
npx skills add brandon-haugen/proctor-skill
```

This installs the `/proctor` skill but not the hook that automatically blocks push/merge. To add the hook, also run:

```bash
npx proctor-skill /path/to/your-project
```

### npm

```bash
# Claude Code
npx proctor-skill /path/to/your-project
npx proctor-skill --global

# Copilot in VS Code
npx proctor-skill --copilot /path/to/your-project
npx proctor-skill --copilot --global
```

To update, just run the same command again — npx always fetches the latest version.

To uninstall:

```bash
npx proctor-skill uninstall /path/to/your-project
npx proctor-skill uninstall --copilot /path/to/your-project
```

### From source

```bash
git clone https://github.com/brandon-haugen/proctor-skill.git
cd proctor-skill

# Claude Code
bash install.sh /path/to/your-project
# or globally:
bash install.sh --global

# Copilot in VS Code
bash install.sh --copilot /path/to/your-project
# or globally:
bash install.sh --copilot --global
```

The install script copies the hook and skill files into your project's `.claude/` (or `.github/` for Copilot) directory and wires up the hook config — merging with your existing settings if you have them.

To update, pull the repo and re-run the install:

```bash
cd proctor-skill
git pull
bash install.sh /path/to/your-project
```

To uninstall:

```bash
bash uninstall.sh /path/to/your-project
bash uninstall.sh --copilot /path/to/your-project
```

### Manual install

#### Claude Code

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

#### Copilot in VS Code

Copy the hook and skill into your project's `.github/` directory:

```bash
mkdir -p /path/to/your-project/.github/hooks /path/to/your-project/.github/skills/proctor
cp .claude/hooks/proctor.sh /path/to/your-project/.github/hooks/
cp .claude/skills/proctor/SKILL.md /path/to/your-project/.github/skills/proctor/
```

Then create `.github/hooks/proctor.json`:

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash .github/hooks/proctor.sh",
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
You ask your AI assistant to push or merge into develop
  → It calls Bash("git push ...")
    → PreToolUse hook fires, detects git push
      → Checks for a quiz-passed marker matching current HEAD
        → No marker (or HEAD changed)? BLOCKED. "Run /proctor."
  → It invokes /proctor
    → Diffs the branch, generates questions, quizzes you
      → You answer in chat
        → All correct? Marker written, push retried automatically
        → Any wrong? Correct answers explained, re-quiz with new questions

Periodic (with PROCTOR_COMMIT_INTERVAL=5):
  → Bash("git commit ...")
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
| `git push origin 0.0.1` (a tag) | No — tag pushes are not code changes |
| `git push --tags` | No — tag pushes are not code changes |
| `git rebase main` (then push) | Only if the rebase changed the diff content |
| `git merge develop` (on a feature branch) | No — not a protected target |

## Files

```
bin/
  proctor-skill                       # npm bin entry point
.claude/                              # Source files (also used for Claude Code installs)
  hooks/
    proctor.sh                        # PreToolUse hook — detects push/merge/commit, checks markers
  skills/
    proctor/
      SKILL.md                        # Quiz logic — diff analysis, question generation, evaluation
  settings.json                       # Hook wiring (Claude Code)
install.sh                            # Installer script (supports --copilot flag)
uninstall.sh                          # Uninstaller script (supports --copilot flag)
package.json                          # npm package config
publish.sh                            # Publish to npm (handles version bump, tag, publish)

~/.proctor/
  history.jsonl                       # Quiz history log (created on first quiz)
/tmp/proctor/
  push-{branch}                       # Marker files (ephemeral, per-session)
  checkpoint-{branch}                 # Periodic quiz checkpoints
```

When installed with `--copilot`, the same hook and skill files are copied to `.github/hooks/` and `.github/skills/proctor/`, with hook config in `.github/hooks/proctor.json`.
