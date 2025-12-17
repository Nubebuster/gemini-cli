#!/usr/bin/env bash
# workflow-tool.bash - Interactive workflow tool for gemini-cli fork development
#
# Usage:
#   ./workflow-tool.bash              # Interactive menu
#   ./workflow-tool.bash merge        # Sync with upstream
#   ./workflow-tool.bash checkout     # Switch branch (interactive)
#   ./workflow-tool.bash checkout <branch>
#   ./workflow-tool.bash create       # Create branch (interactive)
#   ./workflow-tool.bash create <type/name>
#   ./workflow-tool.bash backup       # Backup local files to orphan branch
#   ./workflow-tool.bash restore      # Restore local files from orphan branch
#   ./workflow-tool.bash status       # Show current state

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

UPSTREAM_URL="https://github.com/google-gemini/gemini-cli"
UPSTREAM_BRANCH="main"
ORPHAN_BRANCH="nubebuster/local/workflow"
GH_PR_SCRIPT="$HOME/Scripts/gh-pr.bash"
GITIGNORE_LOCAL=".gitignore_local"
BACKUP_PREFS_FILE=".workflow-backup-prefs"

# Valid branch types for naming convention
BRANCH_TYPES=("fix" "feat" "refactor" "chore" "docs")

# =============================================================================
# Dynamic LOCAL_FILES from .gitignore_local
# =============================================================================

# Read local files list from .gitignore_local
get_local_files() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
    local gitignore_path="$repo_root/$GITIGNORE_LOCAL"

    if [[ ! -f "$gitignore_path" ]]; then
        echo ""
        return
    fi

    # Read non-empty, non-comment lines from .gitignore_local
    grep -v '^#' "$gitignore_path" | grep -v '^[[:space:]]*$' | while read -r line; do
        echo "$line"
    done
}

# Get list of files that should be selected by default (not in exclude prefs)
get_backup_selected() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
    local prefs_file="$repo_root/$BACKUP_PREFS_FILE"
    local all_files=()
    local selected=()

    # Get all local files
    while IFS= read -r file; do
        [[ -n "$file" ]] && all_files+=("$file")
    done < <(get_local_files)

    # If no prefs file, default to selecting common ones
    if [[ ! -f "$prefs_file" ]]; then
        for file in "${all_files[@]}"; do
            # Default: select workflow files, skip data/temp files
            case "$file" in
                *.jsonl|*.log|compacted.md|.history)
                    ;;  # Skip these by default
                *)
                    selected+=("$file")
                    ;;
            esac
        done
    else
        # Read prefs file - it contains files that SHOULD be selected
        while IFS= read -r file; do
            [[ -n "$file" ]] && selected+=("$file")
        done < "$prefs_file"
    fi

    # Return comma-separated for gum --selected
    local IFS=','
    echo "${selected[*]}"
}

# Save backup preferences (files that were selected)
save_backup_prefs() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
    local prefs_file="$repo_root/$BACKUP_PREFS_FILE"

    # Write selected files to prefs (one per line)
    printf '%s\n' "$@" > "$prefs_file"
}

# Install pre-push hook to block pushing backup branch
install_push_protection() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
    local hook_file="$repo_root/.git/hooks/pre-push"
    local marker="# workflow-tool: block backup branch push"

    # Check if our protection is already installed
    if [[ -f "$hook_file" ]] && grep -q "$marker" "$hook_file" 2>/dev/null; then
        return 0  # Already installed
    fi

    # Create or append to pre-push hook
    if [[ ! -f "$hook_file" ]]; then
        cat > "$hook_file" << 'HOOK'
#!/usr/bin/env bash
# workflow-tool: block backup branch push
BLOCKED_BRANCH="nubebuster/local/workflow"
while read -r local_ref local_sha remote_ref remote_sha; do
    if [[ "$local_ref" == "refs/heads/$BLOCKED_BRANCH" ]]; then
        echo "ERROR: Pushing '$BLOCKED_BRANCH' is blocked (contains private data)" >&2
        exit 1
    fi
done
HOOK
        chmod +x "$hook_file"
    else
        # Append to existing hook
        cat >> "$hook_file" << 'HOOK'

# workflow-tool: block backup branch push
BLOCKED_BRANCH="nubebuster/local/workflow"
while read -r local_ref local_sha remote_ref remote_sha; do
    if [[ "$local_ref" == "refs/heads/$BLOCKED_BRANCH" ]]; then
        echo "ERROR: Pushing '$BLOCKED_BRANCH' is blocked (contains private data)" >&2
        exit 1
    fi
done
HOOK
    fi
}

# =============================================================================
# Colors and Output
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}\n"; }

# =============================================================================
# Utilities
# =============================================================================

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command not found: $cmd"
        exit 1
    fi
}

ensure_repo() {
    if ! git rev-parse --git-dir &>/dev/null; then
        error "Not in a git repository"
        exit 1
    fi
}

get_repo_root() {
    git rev-parse --show-toplevel
}

current_branch() {
    git branch --show-current
}

# Check if a branch type is valid
is_valid_type() {
    local type="$1"
    for t in "${BRANCH_TYPES[@]}"; do
        [[ "$t" == "$type" ]] && return 0
    done
    return 1
}

# =============================================================================
# Core Functions
# =============================================================================

# Inject .history/** into eslint.config.js ignores
inject_eslint_ignore() {
    local eslint_file="eslint.config.js"

    if [[ ! -f "$eslint_file" ]]; then
        warn "eslint.config.js not found, skipping injection"
        return
    fi

    # Check if .history/** already in ignores (handles both quote styles)
    if grep -qE "['\"].history/\*\*['\"]" "$eslint_file" 2>/dev/null; then
        info "eslint.config.js already has .history/** ignore"
        return
    fi

    # Inject after 'dist/**' line in ignores array (handles both quote styles)
    if grep -q "'dist/\*\*'" "$eslint_file"; then
        # Single quotes - match upstream style
        sed -i "/'dist\/\*\*'/a\\      '.history/**'," "$eslint_file"
        info "Injected .history/** into eslint.config.js"
    elif grep -q '"dist/\*\*"' "$eslint_file"; then
        # Double quotes
        sed -i '/"dist\/\*\*"/a\      ".history/**",' "$eslint_file"
        info "Injected .history/** into eslint.config.js"
    else
        warn "Could not find dist/** in eslint.config.js, manual injection may be needed"
    fi
}

# Check if local files are present
check_local_files() {
    local missing=()
    local local_files=()

    # Get local files from .gitignore_local
    while IFS= read -r file; do
        [[ -n "$file" ]] && local_files+=("$file")
    done < <(get_local_files)

    for file in "${local_files[@]}"; do
        [[ ! -e "$file" ]] && missing+=("$file")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "${missing[*]}"
        return 1
    fi
    return 0
}

# Ensure local files are present, offer restore if missing
ensure_local_files() {
    local missing
    if missing=$(check_local_files); then
        return 0
    fi

    warn "Missing local files: $missing"

    if gum confirm "Restore from backup branch ($ORPHAN_BRANCH)?"; then
        cmd_restore
    else
        warn "Some local files are missing. Run './workflow-tool.bash restore' when ready."
    fi
}

# =============================================================================
# Commands
# =============================================================================

cmd_merge() {
    header "Merging with upstream"

    local repo_root
    repo_root=$(get_repo_root)
    cd "$repo_root"

    # Ensure upstream remote exists
    if ! git remote get-url upstream &>/dev/null; then
        info "Adding upstream remote: $UPSTREAM_URL"
        git remote add upstream "$UPSTREAM_URL"
    fi

    # Reset eslint.config.js before stashing - we'll re-patch it from upstream anyway
    # This prevents stash conflicts since eslint changes shouldn't be in the stash
    if git diff --name-only | grep -q '^eslint.config.js$'; then
        info "Resetting eslint.config.js (will be re-patched from upstream)"
        git checkout -- eslint.config.js
    fi

    # Stash tracked changes (eslint.config.js excluded above)
    local stash_needed=false
    if ! git diff --quiet || ! git diff --cached --quiet; then
        info "Stashing tracked changes..."
        git stash push -m "workflow-tool: auto-stash before merge"
        stash_needed=true
    fi

    # Cleanup function for error cases
    cleanup() {
        local exit_code=$?
        # Pop stash if needed
        if [[ "$stash_needed" == "true" ]]; then
            info "Restoring stashed changes..."
            git stash pop || warn "Stash pop had conflicts - resolve manually"
        fi
        return $exit_code
    }
    trap cleanup EXIT

    # Fetch from upstream (unshallow if needed)
    info "Fetching from upstream..."
    if git rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
        info "Unshallowing repository..."
        git fetch --unshallow upstream "$UPSTREAM_BRANCH"
    else
        git fetch upstream "$UPSTREAM_BRANCH"
    fi

    # Clear skip-worktree on eslint.config.js so reset can overwrite it
    git update-index --no-skip-worktree eslint.config.js 2>/dev/null || true

    # Reset to upstream
    info "Resetting to upstream/$UPSTREAM_BRANCH..."
    git reset --hard "upstream/$UPSTREAM_BRANCH"

    # Now eslint.config.js is fresh from upstream, inject our ignore
    inject_eslint_ignore

    # Re-enable skip-worktree so eslint.config.js doesn't show in git status
    git update-index --skip-worktree eslint.config.js

    # Remove trap - we're done with critical section
    trap - EXIT

    # Pop stash if needed
    if [[ "$stash_needed" == "true" ]]; then
        info "Restoring stashed changes..."
        git stash pop || warn "Stash pop had conflicts - resolve manually"
    fi

    info "Successfully synced with upstream!"
    echo ""
    git status --short
}

cmd_checkout() {
    header "Switch Branch"

    local target_branch="${1:-}"

    if [[ -z "$target_branch" ]]; then
        # Interactive branch selection with fzf
        require_cmd fzf

        target_branch=$(git branch --format='%(refname:short)' | \
            grep -v "^$ORPHAN_BRANCH$" | \
            fzf --prompt="Select branch: " --height=40% --reverse)

        if [[ -z "$target_branch" ]]; then
            info "No branch selected"
            return
        fi
    fi

    info "Switching to branch: $target_branch"
    git checkout "$target_branch"

    ensure_local_files
}

cmd_create() {
    header "Create Branch"

    require_cmd gum

    local branch_type=""
    local branch_name=""
    local full_branch=""

    # Parse arguments
    if [[ $# -gt 0 ]]; then
        local arg="$1"

        # Check if arg contains a slash (type/name format)
        if [[ "$arg" == */* ]]; then
            branch_type="${arg%%/*}"
            branch_name="${arg#*/}"
        else
            # Just a name, need to prompt for type
            branch_name="$arg"
        fi
    fi

    # Prompt for type if not provided
    if [[ -z "$branch_type" ]]; then
        branch_type=$(gum choose --header="Select branch type:" "${BRANCH_TYPES[@]}")
        if [[ -z "$branch_type" ]]; then
            info "No type selected"
            return
        fi
    fi

    # Validate type
    if ! is_valid_type "$branch_type"; then
        error "Invalid branch type: $branch_type"
        error "Valid types: ${BRANCH_TYPES[*]}"
        return 1
    fi

    # Prompt for name if not provided
    if [[ -z "$branch_name" ]]; then
        branch_name=$(gum input --placeholder="Branch name (e.g., fix-typo-in-readme)")
        if [[ -z "$branch_name" ]]; then
            info "No name provided"
            return
        fi
    fi

    # Sanitize branch name (replace spaces with dashes, lowercase)
    branch_name=$(echo "$branch_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

    full_branch="nubebuster/$branch_type/$branch_name"

    info "Creating branch: $full_branch"

    # First merge upstream
    info "Merging upstream first..."
    cmd_merge

    # Create and switch to new branch
    git checkout -b "$full_branch"

    info "Created and switched to: $full_branch"

    ensure_local_files
}

cmd_backup() {
    header "Backup Local Files"

    require_cmd gum

    local current
    current=$(current_branch)
    local repo_root
    repo_root=$(get_repo_root)
    cd "$repo_root"

    # Declare variables used in cleanup (for set -u compatibility)
    local temp_dir=""
    local stash_needed=false
    local files_to_backup=()

    # Get local files from .gitignore_local and check which exist
    local existing_files=()
    while IFS= read -r file; do
        [[ -n "$file" && -e "$file" ]] && existing_files+=("$file")
    done < <(get_local_files)

    if [[ ${#existing_files[@]} -eq 0 ]]; then
        warn "No local files found to backup (check $GITIGNORE_LOCAL)"
        return
    fi

    # Get previously saved selection preferences
    local default_selected
    default_selected=$(get_backup_selected)

    # Let user select which files to backup (multi-select)
    # Selection is remembered from last time
    local selected
    selected=$(printf '%s\n' "${existing_files[@]}" | \
        gum choose --no-limit \
            --header="Select files to backup (space to toggle, enter to confirm):" \
            --selected="$default_selected")

    if [[ -z "$selected" ]]; then
        info "No files selected, backup cancelled"
        return
    fi

    # Convert newline-separated selection to array
    while IFS= read -r file; do
        [[ -n "$file" ]] && files_to_backup+=("$file")
    done <<< "$selected"

    # Save selection preferences for next time
    save_backup_prefs "${files_to_backup[@]}"
    info "Preferences saved to $BACKUP_PREFS_FILE"

    # Always include .workflow-backup-prefs in backup
    local prefs_in_list=false
    for f in "${files_to_backup[@]}"; do
        [[ "$f" == "$BACKUP_PREFS_FILE" ]] && prefs_in_list=true
    done
    if [[ "$prefs_in_list" == "false" && -f "$BACKUP_PREFS_FILE" ]]; then
        files_to_backup+=("$BACKUP_PREFS_FILE")
    fi

    info "Will backup: ${files_to_backup[*]}"

    if ! gum confirm "Proceed with backup to $ORPHAN_BRANCH?"; then
        info "Backup cancelled"
        return
    fi

    # FIRST: Copy files to temp (before any git operations)
    temp_dir=$(mktemp -d)
    for file in "${files_to_backup[@]}"; do
        cp -r "$file" "$temp_dir/"
    done
    info "Files saved to temp directory"

    # Clear skip-worktree and restore eslint.config.js from upstream
    # (we'll re-patch it at the end, so local changes are discarded)
    git update-index --no-skip-worktree eslint.config.js 2>/dev/null || true
    git checkout upstream/main -- eslint.config.js 2>/dev/null || true

    # Stash any other tracked changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        git stash push -m "workflow-tool: stash before backup"
        stash_needed=true
    fi

    # Cleanup function to restore state on error
    cleanup_backup() {
        local exit_code=$?
        if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
            # Restore files from temp
            for file in "${files_to_backup[@]}"; do
                [[ -e "$temp_dir/$(basename "$file")" ]] && cp -r "$temp_dir/$(basename "$file")" "$file"
            done
            rm -rf "$temp_dir"
        fi
        # Try to get back to original branch
        git checkout "$current" 2>/dev/null || true
        if [[ "$stash_needed" == "true" ]]; then
            git stash pop 2>/dev/null || true
        fi
        # Re-patch eslint and restore skip-worktree
        inject_eslint_ignore 2>/dev/null || true
        git update-index --skip-worktree eslint.config.js 2>/dev/null || true
        return $exit_code
    }
    trap cleanup_backup EXIT

    # Check if orphan branch exists locally or remotely
    local orphan_exists=false
    local orphan_ref=""
    if git show-ref --verify --quiet "refs/heads/$ORPHAN_BRANCH" 2>/dev/null; then
        orphan_exists=true
        orphan_ref="$ORPHAN_BRANCH"
    elif git show-ref --verify --quiet "refs/remotes/origin/$ORPHAN_BRANCH" 2>/dev/null; then
        orphan_exists=true
        orphan_ref="origin/$ORPHAN_BRANCH"
    fi

    if [[ "$orphan_exists" == "true" ]]; then
        # Checkout existing orphan branch
        if [[ "$orphan_ref" == "origin/$ORPHAN_BRANCH" ]]; then
            git fetch origin "$ORPHAN_BRANCH"
            git checkout -B "$ORPHAN_BRANCH" "origin/$ORPHAN_BRANCH"
        else
            git checkout "$ORPHAN_BRANCH"
        fi
    else
        # Create new orphan branch
        git checkout --orphan "$ORPHAN_BRANCH"
        # Unstage everything (orphan starts with all files staged)
        git reset 2>/dev/null || true
    fi

    # Copy files from temp to working directory
    for file in "${files_to_backup[@]}"; do
        cp -r "$temp_dir/$(basename "$file")" "$file"
    done

    # Stage and commit
    git add -f "${files_to_backup[@]}"
    if git diff --cached --quiet; then
        info "No changes to commit (files unchanged)"
    else
        git commit -m "Backup local workflow files $(date +%Y-%m-%d-%H%M%S)"
        info "Committed backup"
    fi

    # Remove trap before normal exit
    trap - EXIT

    # Go back to original branch
    git checkout "$current"

    # Restore our local files from temp
    for file in "${files_to_backup[@]}"; do
        cp -r "$temp_dir/$(basename "$file")" "$file"
    done
    rm -rf "$temp_dir"

    # Restore stash
    if [[ "$stash_needed" == "true" ]]; then
        git stash pop || warn "Stash pop had conflicts"
    fi

    # Re-patch eslint.config.js and restore skip-worktree
    inject_eslint_ignore
    git update-index --skip-worktree eslint.config.js 2>/dev/null || true

    # Ensure branch has no upstream (prevents accidental push)
    git branch --unset-upstream "$ORPHAN_BRANCH" 2>/dev/null || true

    # Install pre-push hook to block pushing this branch
    install_push_protection
    info "Pre-push hook installed to block pushing backup branch"

    info "Backup complete!"
    warn "Note: Backup branch is LOCAL ONLY (never pushed) to protect private data"
}

cmd_restore() {
    header "Restore Local Files"

    local repo_root
    repo_root=$(get_repo_root)
    cd "$repo_root"

    # Check if orphan branch exists (LOCAL ONLY - never pushed for privacy)
    if ! git show-ref --verify --quiet "refs/heads/$ORPHAN_BRANCH" 2>/dev/null; then
        error "Backup branch $ORPHAN_BRANCH not found locally"
        error "Run './workflow-tool.bash backup' first to create it"
        return 1
    fi

    info "Restoring from: $ORPHAN_BRANCH (local)"

    # Get local files list
    local local_files=()
    while IFS= read -r file; do
        [[ -n "$file" ]] && local_files+=("$file")
    done < <(get_local_files)

    # Restore each file
    for file in "${local_files[@]}"; do
        if git show "$ORPHAN_BRANCH:$file" &>/dev/null; then
            git show "$ORPHAN_BRANCH:$file" > "$file"
            info "Restored: $file"
        else
            warn "File not in backup: $file"
        fi
    done

    # Make workflow-tool.bash executable
    chmod +x workflow-tool.bash 2>/dev/null || true

    info "Restore complete!"
}

cmd_status() {
    header "Workflow Status"

    local repo_root
    repo_root=$(get_repo_root)
    cd "$repo_root"

    echo -e "${BOLD}Current Branch:${NC} $(current_branch)"
    echo ""

    # Check upstream sync
    echo -e "${BOLD}Upstream Sync:${NC}"
    if git remote get-url upstream &>/dev/null; then
        local upstream_head
        upstream_head=$(git rev-parse "upstream/$UPSTREAM_BRANCH" 2>/dev/null || echo "unknown")
        local local_head
        local_head=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

        if [[ "$upstream_head" == "$local_head" ]]; then
            echo -e "  ${GREEN}Up to date with upstream/$UPSTREAM_BRANCH${NC}"
        else
            local behind
            behind=$(git rev-list --count "HEAD..upstream/$UPSTREAM_BRANCH" 2>/dev/null || echo "?")
            echo -e "  ${YELLOW}$behind commits behind upstream/$UPSTREAM_BRANCH${NC}"
        fi
    else
        echo -e "  ${YELLOW}Upstream remote not configured${NC}"
    fi
    echo ""

    # Check local files
    echo -e "${BOLD}Local Files (from $GITIGNORE_LOCAL):${NC}"
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            if [[ -e "$file" ]]; then
                echo -e "  ${GREEN}✓${NC} $file"
            else
                echo -e "  ${RED}✗${NC} $file (missing)"
            fi
        fi
    done < <(get_local_files)
    echo ""

    # Check backup branch (local only - never pushed for privacy)
    echo -e "${BOLD}Backup Branch (local only):${NC}"
    if git show-ref --verify --quiet "refs/heads/$ORPHAN_BRANCH" 2>/dev/null; then
        local commit_count
        commit_count=$(git rev-list --count "$ORPHAN_BRANCH" 2>/dev/null || echo "?")
        echo -e "  ${GREEN}✓${NC} $ORPHAN_BRANCH ($commit_count backups)"
    else
        echo -e "  ${YELLOW}✗${NC} $ORPHAN_BRANCH (not created yet)"
    fi
    echo ""

    # Git status
    echo -e "${BOLD}Git Status:${NC}"
    git status --short
}

cmd_pr_menu() {
    header "PR Operations"

    require_cmd gum

    if [[ ! -x "$GH_PR_SCRIPT" ]]; then
        error "gh-pr.bash not found at $GH_PR_SCRIPT"
        return 1
    fi

    local choice
    choice=$(gum choose --header="Select PR operation:" \
        "View PR details" \
        "Show comments/reviews" \
        "Post comment" \
        "Reply to review" \
        "Show inline comments" \
        "Reply to inline comment" \
        "Respond guide" \
        "Back to main menu")

    case "$choice" in
        "View PR details")
            "$GH_PR_SCRIPT" view
            ;;
        "Show comments/reviews")
            "$GH_PR_SCRIPT" comments
            ;;
        "Post comment")
            local body
            body=$(gum input --placeholder="Enter comment..." --width=80)
            [[ -n "$body" ]] && "$GH_PR_SCRIPT" comment "$body"
            ;;
        "Reply to review")
            local body
            body=$(gum input --placeholder="Enter reply..." --width=80)
            [[ -n "$body" ]] && "$GH_PR_SCRIPT" reply-review "$body"
            ;;
        "Show inline comments")
            "$GH_PR_SCRIPT" inline-comments
            ;;
        "Reply to inline comment")
            "$GH_PR_SCRIPT" respond
            echo ""
            local comment_id
            comment_id=$(gum input --placeholder="Enter comment ID...")
            if [[ -n "$comment_id" ]]; then
                local body
                body=$(gum input --placeholder="Enter reply..." --width=80)
                [[ -n "$body" ]] && "$GH_PR_SCRIPT" reply-inline "$comment_id" "$body"
            fi
            ;;
        "Respond guide")
            "$GH_PR_SCRIPT" respond
            ;;
        "Back to main menu"|"")
            return
            ;;
    esac

    # Loop back to PR menu
    echo ""
    gum confirm "Back to PR menu?" && cmd_pr_menu
}

# =============================================================================
# Interactive Menu
# =============================================================================

interactive_menu() {
    require_cmd gum

    while true; do
        header "Gemini CLI Workflow Tool"

        local choice
        choice=$(gum choose --header="Select action:" \
            "Merge upstream" \
            "Switch branch" \
            "Create branch" \
            "Backup local files" \
            "Restore local files" \
            "Status" \
            "PR Operations" \
            "Exit")

        case "$choice" in
            "Merge upstream")
                cmd_merge
                ;;
            "Switch branch")
                cmd_checkout
                ;;
            "Create branch")
                cmd_create
                ;;
            "Backup local files")
                cmd_backup
                ;;
            "Restore local files")
                cmd_restore
                ;;
            "Status")
                cmd_status
                ;;
            "PR Operations")
                cmd_pr_menu
                ;;
            "Exit"|"")
                info "Goodbye!"
                exit 0
                ;;
        esac

        echo ""
        read -rp "Press Enter to continue..."
    done
}

# =============================================================================
# Main
# =============================================================================

usage() {
    cat <<'EOF'
Usage: ./workflow-tool.bash [command] [args]

Commands:
  (none)              Interactive menu
  merge               Sync with upstream/main
  checkout [branch]   Switch branch (interactive if no branch given)
  create [type/name]  Create branch with naming convention
  backup              Backup local files to orphan branch
  restore             Restore local files from orphan branch
  status              Show current workflow status
  help                Show this help

Branch naming convention: nubebuster/<type>/<name>
Valid types: fix, feat, refactor, chore, docs

Examples:
  ./workflow-tool.bash create feat/new-feature
  ./workflow-tool.bash create fix/typo
  ./workflow-tool.bash checkout
  ./workflow-tool.bash merge
EOF
}

main() {
    ensure_repo

    local repo_root
    repo_root=$(get_repo_root)
    cd "$repo_root"

    if [[ $# -eq 0 ]]; then
        interactive_menu
        exit 0
    fi

    local command="$1"
    shift

    case "$command" in
        merge)
            cmd_merge
            ;;
        checkout)
            cmd_checkout "$@"
            ;;
        create)
            cmd_create "$@"
            ;;
        backup)
            cmd_backup
            ;;
        restore)
            cmd_restore
            ;;
        status)
            cmd_status
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
