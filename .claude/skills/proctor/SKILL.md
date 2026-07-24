---
name: proctor
description: >
  Comprehension quiz that ensures the user understands branch changes before
  pushing, merging into a protected branch, or continuing after a periodic
  checkpoint. Invoke this skill when the proctor hook blocks a git
  operation, or when the user wants to review their understanding of changes.
  Accepts an optional argument with operation context (e.g.,
  "push from branch 'feature/foo'",
  "merge 'feature/bar' into protected branch 'develop'", or
  "periodic checkpoint on branch 'feature/foo'").
---

# Proctor — Comprehension Gate

You are running a comprehension quiz to make sure the user understands the
changes on this branch before they land. The goal is learning and code
ownership, not gatekeeping. Be encouraging, not adversarial.

## Step 1: Determine the diff

Based on `$ARGUMENTS` or the current git state, figure out what to quiz on:

- **Push**: run `git log --oneline $(git merge-base HEAD develop)..HEAD` and
  `git diff $(git merge-base HEAD develop)..HEAD` to see all branch changes.
  If the merge-base fails (e.g., no `develop`), fall back to `git diff HEAD~5..HEAD`.
- **Merge into protected branch**: the blocked message includes the incoming
  branch name. Run `git diff HEAD...{incoming-branch}` to see what's coming in.
- **Periodic checkpoint**: the blocked message includes "periodic checkpoint".
  Read the checkpoint file at `/tmp/proctor/checkpoint-{branch}` to
  get the commit hash of the last quiz. Diff from that point:
  `git diff {checkpoint}..HEAD`. If no checkpoint exists, fall back to the
  merge-base approach like a push.
- Always also run the `--stat` variant for an overview of files changed.

If the diff is empty, tell the user there's nothing to quiz on and write the
marker file so the operation can proceed.

## Step 2: Generate questions

Read the diff carefully. Generate questions that test whether the user
actually understands the code, not whether they memorized it. Target three
areas:

1. **What** — "What does [function/component/change] do?" Pick something
   central to the diff, not a trivial one-liner.
2. **Why** — "Why was [this approach] used here?" or "What problem does
   [this change] solve?" Tests design understanding.
3. **Risk** — "What could go wrong with [this change]?" or "What edge case
   does [this guard] handle?" Tests awareness of failure modes.

**Scale by diff size:**
- Small diff (< 50 lines changed): 1–2 questions
- Medium diff (50–500 lines): 3 questions
- Large diff (500+ lines): 4–5 questions

Pick questions from different files/areas when the diff spans multiple files.
Avoid asking about boilerplate, imports, or trivial formatting changes.

## Step 3: Present and wait

Present the questions numbered in a single message. Tell the user they can
answer in whatever order and level of detail they want — bullet points are
fine, essays are fine. Wait for their response.

Example intro:
> Before this push goes through, let me check that you're comfortable with
> these changes. Answer in your own words — no need to be precise, just show
> you understand what's happening.

## Step 4: Evaluate

Grade each answer individually as PASS or FAIL. Be honest — a false pass
defeats the entire purpose of this skill.

- **Pass**: The user captures the essential idea correctly, even if imprecise
  or informal. They don't need textbook language, but the core facts must be
  right. "It checks if the token is still good and refreshes it if not" is a
  valid pass for a token-refresh flow.
- **Fail**: The answer is factually wrong, vague enough to be meaningless
  ("it does stuff", "handles the data"), a guess, or demonstrates a
  misunderstanding of what the code does. An answer that is partially right
  but gets a critical detail wrong is still a fail — the user needs to
  understand the part they missed.

Do NOT round up. Do NOT pass an answer out of politeness. Do NOT treat
"close enough" as correct when the user missed the point. If you're unsure
whether an answer passes, it fails — the cost of a false pass (unreviewed
code ships) is higher than the cost of a re-quiz (the user learns more).

## Step 5: Respond

Show the user their scorecard: mark each answer PASS or FAIL with a brief
explanation of your reasoning.

### If ALL answers pass:

1. Confirm what they got right. If anything was slightly imprecise, clarify
   briefly — but the quiz is passed.
2. Write the marker file so the hook allows the operation:

```bash
mkdir -p /tmp/proctor
# Compute the diff hash (for rebase resilience)
MERGE_BASE=$(git merge-base HEAD develop 2>/dev/null || git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo "")
if [ -n "$MERGE_BASE" ]; then
  DIFF_HASH=$(git diff "$MERGE_BASE" HEAD | git hash-object --stdin)
else
  DIFF_HASH=$(git diff HEAD | git hash-object --stdin)
fi

# For a push (sanitize branch name — replace / with --):
printf '%s\n%s\n' "$(git rev-parse HEAD)" "$DIFF_HASH" > "/tmp/proctor/push-{safe_branch}"
# For a merge:
printf '%s\n%s\n' "$(git rev-parse HEAD)" "$DIFF_HASH" > "/tmp/proctor/merge-{safe_incoming}-into-{safe_target}"
# For a periodic checkpoint:
printf '%s\n%s\n' "$(git rev-parse HEAD)" "$DIFF_HASH" > "/tmp/proctor/periodic-{safe_branch}"
printf '%s\n%s\n' "$(git rev-parse HEAD)" "$DIFF_HASH" > "/tmp/proctor/checkpoint-{safe_branch}"
```

Replace `{safe_branch}`, `{safe_incoming}`, `{safe_target}` with the actual
branch names from the context, with `/` replaced by `--` (e.g.,
`feature/foo` becomes `feature--foo`). This prevents slashes in branch
names from creating subdirectories in the marker path.

**Important**: markers store both the HEAD commit hash and a diff content
hash. The hook checks the commit hash first (fast path). If the commit
hash doesn't match (e.g., after a rebase), it falls back to comparing
diff hashes — so a content-preserving rebase won't trigger a redundant
quiz. Any actual code change invalidates the marker. For periodic
checkpoints, the checkpoint file resets the commit/change counter so the
next quiz only covers new changes from this point forward.

3. Tell Claude to retry the original git operation (push, merge, or commit).

### If ANY answer fails:

1. For each failed answer, explain what the correct answer is and why their
   answer was wrong. This is a teaching moment — be clear and specific, not
   vague. Point to the exact lines or functions in the diff that answer the
   question.
2. Do NOT write the marker file — the operation stays blocked.
3. Do NOT re-ask the same questions they already answered correctly.
4. Re-quiz with new questions that target the same concepts they missed.
   The user needs to demonstrate they understand the material, not memorize
   the answer you just gave them. For example, if they failed a question
   about error handling, ask a different question about error handling in
   the same diff — not the same question with the answer fresh in mind.
5. If they fail the same concept twice, suggest they read the specific
   files and come back: point them to `git diff --stat` and name the files.

## Important notes

- Never skip the quiz or auto-pass. The whole point is human engagement.
- Never accept a wrong answer. A quiz that lets wrong answers through is
  worse than no quiz — it gives false confidence.
- If the user explicitly says "skip" or "I don't care", respect that but
  remind them the quiz exists for their benefit. In advisory mode, let them
  through. In blocking mode, require at least a genuine attempt.
- If the diff is trivially small (a one-line typo fix), acknowledge it and
  write the marker without a full quiz — use good judgment.
