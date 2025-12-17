# Gemini CLI - Claude Instructions

## GitHub PR Operations

Use `~/Scripts/gh-pr.bash` for all PR operations. It handles the repo
automatically and auto-detects PR number from current branch if omitted.

### Common Commands

```bash
gh-pr.bash view [pr]                     # Full PR JSON (no body)
gh-pr.bash comments [pr]                 # All comments + reviews formatted
gh-pr.bash reviews [pr]                  # Just reviews
gh-pr.bash respond [pr]                  # Check for inline comments, guide response
gh-pr.bash comment [pr] "msg"            # Post comment
gh-pr.bash reply-review [pr] "msg"       # Reply to a review (posts as new review)
gh-pr.bash reply-inline [pr] <id> "msg"  # Reply to specific inline comment
gh-pr.bash edit-comment [pr] "msg"       # Edit your last comment
gh-pr.bash inline-comments [pr]          # List inline code comments with IDs
```

### Understanding Comments vs Reviews

GitHub has two separate systems:

1. **Issue Comments** - General PR conversation thread
2. **Reviews** - Code review feedback (can be APPROVED, CHANGES_REQUESTED, or
   COMMENTED)
3. **Inline Comments** - Line-level comments within reviews

**Key behavior:**

- Review bodies cannot be replied to directly - use `reply-review` to post your
  own review as response
- Review bodies cannot be edited after posting
- Only your own regular comments can be edited with `edit-comment`

### IMPORTANT: Choosing the Right Command

**When responding to a review, ALWAYS run `respond` first:**

```bash
gh-pr.bash respond   # Shows inline comments and correct reply command
```

If the review has inline code comments, **reply to those** - don't post a
separate review:

| Situation                    | Correct Command           | Wrong Command      |
| ---------------------------- | ------------------------- | ------------------ |
| Review has inline comments   | `reply-inline <id> "msg"` | ~~`reply-review`~~ |
| Review body only (no inline) | `reply-review "msg"`      | ~~`comment`~~      |
| General conversation         | `comment "msg"`           | -                  |

**Why this matters:**

- `reply-inline` creates a **threaded reply** attached to the specific code
  comment
- `reply-review` creates a **separate review** that floats disconnected in the
  timeline
- Reviewers expect responses in the thread, not as separate reviews

### Fallback: Raw `gh` Commands

For operations not covered by the wrapper, use repo `google-gemini/gemini-cli`:

```bash
# Approve PR
gh pr review <pr> --repo google-gemini/gemini-cli --approve

# Request changes
gh pr review <pr> --repo google-gemini/gemini-cli --request-changes --body "reason"

# Merge PR
gh pr merge <pr> --repo google-gemini/gemini-cli --squash

# Create PR
gh pr create --repo google-gemini/gemini-cli --title "title" --body "body"

# List PRs
gh pr list --repo google-gemini/gemini-cli --state open

# Check CI status
gh pr checks <pr> --repo google-gemini/gemini-cli
```

### `gh` CLI Gotchas

- `-R` expects `owner/repo`, NOT full URL
- `--json` requires specifying fields explicitly
- `-c` (comments) and `--json` don't work together
- Review comments ≠ PR comments - different APIs
