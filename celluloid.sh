#!/bin/bash
# celluloid - A tool for bundling git repositories and application data in SQLite

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# Create the initial database schema
init_database() {
    local db_file="$1"
    
    sqlite3 "$db_file" <<'EOF'
-- Git object database (odb)
CREATE TABLE IF NOT EXISTS git_objects (
    sha TEXT PRIMARY KEY,
    type TEXT NOT NULL CHECK(type IN ('blob', 'tree', 'commit', 'tag')),
    size INTEGER NOT NULL,
    data BLOB NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Git references database (refdb)
CREATE TABLE IF NOT EXISTS git_refs (
    name TEXT PRIMARY KEY,
    sha TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('branch', 'tag', 'remote')),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (sha) REFERENCES git_objects(sha)
);

-- Process execution tracking
CREATE TABLE IF NOT EXISTS process_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    commit_sha TEXT NOT NULL,
    command TEXT NOT NULL,
    pid INTEGER,
    parent_pid INTEGER,
    uid INTEGER,
    gid INTEGER,
    start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    end_time TIMESTAMP,
    exit_code INTEGER,
    stdout TEXT,
    stderr TEXT,
    environment TEXT,
    working_directory TEXT,
    status TEXT CHECK(status IN ('running', 'completed', 'failed')),
    FOREIGN KEY (commit_sha) REFERENCES git_objects(sha)
);

-- Code change tracking
CREATE TABLE IF NOT EXISTS code_changes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_sha TEXT,
    to_sha TEXT NOT NULL,
    change_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT CHECK(status IN ('pending', 'applied', 'failed')),
    error_message TEXT,
    FOREIGN KEY (from_sha) REFERENCES git_objects(sha),
    FOREIGN KEY (to_sha) REFERENCES git_objects(sha)
);

-- Set up initial HEAD reference
INSERT OR REPLACE INTO git_refs (name, sha, type) 
VALUES ('HEAD', '', 'branch');
EOF
    
    echo "Initialized new Celluloid database: $db_file"
}

# Store a git object in the database
store_git_object() {
    local db_file="$1"
    local sha="$2"
    local type="$3"
    local size="$4"
    local data="$5"
    
    sqlite3 "$db_file" "INSERT OR REPLACE INTO git_objects (sha, type, size, data) 
                        VALUES ('$sha', '$type', $size, X'$data')"
}

# Extract a git object from the database
get_git_object() {
    local db_file="$1"
    local sha="$2"
    
    sqlite3 "$db_file" "SELECT hex(data) FROM git_objects WHERE sha = '$sha'"
}

# Update a git reference
update_ref() {
    local db_file="$1"
    local ref_name="$2"
    local sha="$3"
    local ref_type="$4"
    
    sqlite3 "$db_file" "INSERT OR REPLACE INTO git_refs (name, sha, type) 
                        VALUES ('$ref_name', '$sha', '$ref_type')"
}

# Get HEAD commit SHA
get_head_sha() {
    local db_file="$1"
    sqlite3 "$db_file" "SELECT sha FROM git_refs WHERE name = 'HEAD'"
}

# Checkout code to temporary directory
checkout_code() {
    local db_file="$1"
    local commit_sha="$2"
    local temp_dir=$(mktemp -d)
    
    # Create a git repository in temp
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    git init
    
    # Export objects from SQLite to git
    sqlite3 "$db_file" "SELECT sha, hex(data) FROM git_objects" | while IFS='|' read -r sha hex_data; do
        if [ -n "$sha" ] && [ -n "$hex_data" ]; then
            echo -n "$hex_data" | xxd -r -p | git hash-object -w --stdin
        fi
    done
    
    # Create a temporary branch and checkout
    git update-ref "refs/heads/temp" "$commit_sha"
    git checkout temp
    
    echo "$temp_dir"
}

# Run a command from a specific commit
run_command() {
    local db_file="$1"
    local command="$2"
    local commit_sha="${3:-$(get_head_sha "$db_file")}"
    
    if [ -z "$commit_sha" ]; then
        echo "Error: No HEAD commit found. Push some code first."
        exit 1
    fi
    
    # Checkout code to temporary directory
local work_dir=$(checkout_code "$db_file" "$commit_sha")
    
# Record process start
local process_id=$(sqlite3 "$db_file" "INSERT INTO process_runs 
    (commit_sha, command, pid, status, working_directory) 
    VALUES ('$commit_sha', '$command', $$, 'running', '$work_dir')
    RETURNING id")

# Execute the command with DATABASE_URL set
export DATABASE_URL="$db_file"
# We're already in the work_dir from checkout_code
    
    # Capture stdout, stderr, and exit code
    local stdout_file=$(mktemp)
    local stderr_file=$(mktemp)
    local exit_code=0
    
    if eval "$command" >"$stdout_file" 2>"$stderr_file"; then
        exit_code=0
    else
        exit_code=$?
    fi
    
    # Update process record - escape stdout/stderr content
    stdout_content=$(cat "$stdout_file" | sed "s/'/''/g")
    stderr_content=$(cat "$stderr_file" | sed "s/'/''/g")

    sqlite3 "$db_file" "UPDATE process_runs SET 
        end_time = CURRENT_TIMESTAMP,
        exit_code = $exit_code,
        stdout = '$stdout_content',
        stderr = '$stderr_content',
        status = CASE WHEN $exit_code = 0 THEN 'completed' ELSE 'failed' END
        WHERE id = $process_id"
    
    # Cleanup
    rm -rf "$work_dir" "$stdout_file" "$stderr_file"
    
    return $exit_code
}

# Handle git push operations
handle_push() {
    local db_file="$1"
    local from_sha="$2"
    local to_sha="$3"
    
    # Record code change attempt
    local change_id=$(sqlite3 "$db_file" "INSERT INTO code_changes 
        (from_sha, to_sha, status) 
        VALUES ('$from_sha', '$to_sha', 'pending')
        RETURNING id")
    
    # Begin transaction
    sqlite3 "$db_file" "BEGIN TRANSACTION"
    
    # Check if code_change.sh exists in the new commit
    local temp_dir=$(checkout_code "$db_file" "$to_sha")
    
    if [ -f "$temp_dir/code_change.sh" ]; then
        # Run code_change.sh
        cd "$temp_dir"
        export DATABASE_URL="$db_file"
        
        if ./code_change.sh "$from_sha"; then
            # Success - commit the transaction
            sqlite3 "$db_file" "COMMIT"
            sqlite3 "$db_file" "UPDATE code_changes SET status = 'applied' WHERE id = $change_id"
            update_ref "$db_file" "HEAD" "$to_sha" "branch"
            echo "Code change applied successfully"
        else
            # Failure - rollback
            local exit_code=$?
            sqlite3 "$db_file" "ROLLBACK"
            sqlite3 "$db_file" "UPDATE code_changes SET 
                status = 'failed',
                error_message = 'code_change.sh failed with exit code '||$exit_code
                WHERE id = $change_id"
            echo "Code change failed, transaction rolled back"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        # No code_change.sh - just update the ref
        sqlite3 "$db_file" "COMMIT"
        sqlite3 "$db_file" "UPDATE code_changes SET status = 'applied' WHERE id = $change_id"
        update_ref "$db_file" "HEAD" "$to_sha" "branch"
        echo "Code pushed successfully (no code_change.sh)"
    fi
    
    rm -rf "$temp_dir"
}

# Git protocol helper for push operations
git_protocol_helper() {
    local db_file="$1"
    
    # This is a simplified implementation of git protocol helper
    # In a real implementation, you'd need to handle the full git protocol
    
    while IFS=' ' read -r command arg1 arg2 arg3; do
        case "$command" in
            "capabilities")
                echo "fetch"
                echo "push"
                echo "option"
                echo ""
                ;;
            "list")
                # List all refs
                sqlite3 "$db_file" "SELECT sha || ' ' || name FROM git_refs" || true
                echo ""
                ;;
            "push")
                # Handle push
                # Format: push +<from>:<to> <ref>
                local from_to="${arg1#\+}"
                local from="${from_to%:*}"
                local to="${from_to#*:}"
                handle_push "$db_file" "$from" "$to"
                ;;
            "")
                break
                ;;
        esac
    done
}

# Main command dispatcher
case "${1:-}" in
    "init")
        if [ -z "${2:-}" ]; then
            echo "Usage: $SCRIPT_NAME init <database_file>"
            exit 1
        fi
        init_database "$2"
        ;;
    
    "run")
        if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
            echo "Usage: $SCRIPT_NAME run <database_file> <command>"
            exit 1
        fi
        run_command "$2" "$3"
        ;;
    
    "push")
        if [ -z "${2:-}" ]; then
            echo "Usage: $SCRIPT_NAME push <database_file>"
            exit 1
        fi
        # This would typically be called by git's transport mechanism
        git_protocol_helper "$2"
        ;;
    
    "checkout")
        if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
            echo "Usage: $SCRIPT_NAME checkout <database_file> <commit_sha>"
            exit 1
        fi
        checkout_code "$2" "$3"
        ;;
    
    *)
        echo "celluloid - Bundle git repositories and application data in SQLite"
        echo ""
        echo "Usage:"
        echo "  $SCRIPT_NAME init <database_file>     Initialize a new Celluloid database"
        echo "  $SCRIPT_NAME run <database_file> <command>  Run a command from HEAD"
        echo "  $SCRIPT_NAME push <database_file>     Handle git push operations"
        echo "  $SCRIPT_NAME checkout <database_file> <sha>  Checkout code to temp directory"
        echo ""
        echo "Example:"
        echo "  $SCRIPT_NAME init myapp.db"
        echo "  git remote add bundle celluloid://myapp.db"
        echo "  git push bundle main"
        echo "  $SCRIPT_NAME run myapp.db './main.sh'"
        exit 1
        ;;
esac
