# Celluloid Development Guide

## Commands

### Running Celluloid
- Initialize database: `./celluloid.sh init <database_file>`
- Run command: `./celluloid.sh run <database_file> <command>`
- Push code: `./celluloid.sh push <database_file>`
- Checkout code: `./celluloid.sh checkout <database_file> <commit_sha>`

### Git Integration
- Setup remote: `git remote add bundle celluloid://<database_file>`
- Push to database: `git push bundle <branch>`

### Testing

- Test command: `./test_celluloid.sh`

## Database Schema

### Git Tables
- `git_objects`: Stores git objects (blob, tree, commit, tag)
  - `sha`: TEXT PRIMARY KEY - Object SHA hash
  - `type`: TEXT NOT NULL - Object type (blob, tree, commit, tag)
  - `size`: INTEGER NOT NULL - Object size
  - `data`: BLOB NOT NULL - Object content
  - `created_at`: TIMESTAMP - When object was created

- `git_refs`: Stores git references
  - `name`: TEXT PRIMARY KEY - Reference name (HEAD, refs/heads/main)
  - `sha`: TEXT NOT NULL - Commit SHA the ref points to
  - `type`: TEXT NOT NULL - Reference type (branch, tag, remote)
  - `updated_at`: TIMESTAMP - When reference was updated

### Application Tables
- `process_runs`: Tracks command executions
  - `commit_sha`: TEXT NOT NULL - The commit the command was run from
  - `command`: TEXT NOT NULL - The executed command
  - `exit_code`: INTEGER - Command exit code
  - `stdout`/`stderr`: TEXT - Command output
  - `status`: TEXT - Execution status (running, completed, failed)

- `code_changes`: Tracks code change migrations
  - `from_sha`: TEXT - Previous commit SHA
  - `to_sha`: TEXT NOT NULL - New commit SHA
  - `status`: TEXT - Migration status (pending, applied, failed)

## Code Change Migrations

When pushing code to a Celluloid database, the system will:
1. Check for a `code_change.sh` script in the repository
2. If present, execute it with the previous commit SHA as an argument
3. If the script succeeds, commit the transaction and update HEAD
4. If the script fails, roll back the transaction

The script has access to the database via the `DATABASE_URL` environment variable.

## Code Style Guidelines

### Bash Scripting
- Use `set -euo pipefail` at the beginning of scripts
- Use local variables in functions when possible
- Document functions with comments explaining purpose
- Quote all variable references: `"$variable"`
- Use lowercase for variable names, underscore for word separation
- Functions should be named with snake_case

### SQL
- Use uppercase for SQL keywords
- Use single quotes for SQL string literals
- Escape single quotes in SQL strings with doubled single quotes: `''`
- Use proper SQL constraints (CHECK, FOREIGN KEY)

### Error Handling
- Exit with non-zero code on errors
- Provide helpful error messages
- Use proper SQL transaction management (BEGIN/COMMIT/ROLLBACK)
- Capture and log detailed error information