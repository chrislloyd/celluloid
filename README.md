# Celluloid

Celluloid is a tool that allows you to bundle a git repository and application data into a single SQLite database, creating a self-contained application bundle.

## Installation

1. Build the Celluloid binary using Zig:

    ```bash
    zig build
    ```

2. Copy the binary to your path:

    ```bash
    sudo cp zig-out/bin/celluloid /usr/local/bin/
    ```

3. Set up the git remote helper:

    ```bash
    sudo ln -s /usr/local/bin/celluloid /usr/local/bin/git-remote-celluloid
    ```

## Basic Usage

### 1. Initialize a New Project

Create a new Celluloid database:

```bash
celluloid init myapp.db
```

This creates a SQLite database with the necessary schema for:

- Git objects (blobs, trees, commits, tags)
- Git references (branches, tags, remotes)
- Process execution tracking
- Code change history

### 2. Use as a Git Remote

Add the database as a git remote:

```bash
# In your existing git repository
git remote add bundle celluloid://myapp.db
```

### 3. Push Code to the Bundle

Push your code to the SQLite database:

```bash
git push bundle main
```

If your repository contains a `code_change.sh` script, it will be executed automatically during the push. If the script fails, the push will be rolled back.

### 4. Run Commands from the Bundle

Execute commands from the bundled code:

```bash
celluloid run myapp.db "python main.py"
celluloid run myapp.db "./start.sh"
```

The command will:

- Extract the HEAD commit to a temporary directory
- Set `DATABASE_URL` environment variable to the SQLite database path
- Execute the command
- Record the execution in the `process_runs` table

### 5. Checkout Code from the Bundle

Checkout a specific commit from the database:

```bash
celluloid checkout myapp.db <commit_sha>
```

This extracts the specified commit to the current directory.

## Database Schema

### Git Tables

**git_objects**: Stores git objects (blobs, trees, commits, tags)

- `sha`: TEXT PRIMARY KEY - Object SHA hash
- `type`: TEXT NOT NULL - Object type (blob, tree, commit, tag)
- `size`: INTEGER NOT NULL - Object size
- `data`: BLOB NOT NULL - Object content
- `created_at`: TIMESTAMP - When object was created

**git_refs**: Stores git references

- `name`: TEXT PRIMARY KEY - Reference name (e.g., 'HEAD', 'refs/heads/main')
- `sha`: TEXT NOT NULL - Commit SHA the ref points to
- `type`: TEXT NOT NULL - Reference type (branch, tag, remote)
- `updated_at`: TIMESTAMP - When reference was updated

### Application Tables

**process_runs**: Tracks command executions

- `id`: INTEGER PRIMARY KEY AUTOINCREMENT
- `commit_sha`: TEXT NOT NULL - The commit the command was run from
- `command`: TEXT NOT NULL - The executed command
- `pid`: INTEGER - Process ID
- `parent_pid`: INTEGER - Parent process ID
- `uid`/`gid`: INTEGER - User/group IDs
- `start_time`/`end_time`: TIMESTAMP - Command execution timestamps
- `exit_code`: INTEGER - Command exit code
- `stdout`/`stderr`: TEXT - Command output
- `environment`: TEXT - Command environment variables
- `working_directory`: TEXT - Command working directory
- `status`: TEXT - Execution status (running, completed, failed)

**code_changes**: Tracks code change migrations

- `id`: INTEGER PRIMARY KEY AUTOINCREMENT
- `from_sha`: TEXT - Previous commit SHA
- `to_sha`: TEXT NOT NULL - New commit SHA
- `change_time`: TIMESTAMP - When change was applied
- `status`: TEXT - Migration status (pending, applied, failed)
- `error_message`: TEXT - Error message if migration failed

## Code Change Migrations

The `code_change.sh` script is a special file that can be included in your repository to handle code migrations. It will be executed automatically when pushing new code.

Example `code_change.sh`:

```bash
#!/bin/bash
# code_change.sh - Handle code migrations

FROM_SHA=$1

# Run database migrations
sqlite3 "$DATABASE_URL" <<EOF
-- Add new column if it doesn't exist
ALTER TABLE user_data ADD COLUMN IF NOT EXISTS last_login TIMESTAMP;
EOF

# Update application data based on code changes
if [ "$FROM_SHA" = "" ]; then
    echo "Initial deployment"
else
    echo "Upgrading from $FROM_SHA"
fi

exit 0
```

## Example Application

Here's a simple example that demonstrates the concept:

```python
# main.py
import os
import sqlite3
from datetime import datetime

db_path = os.environ.get('DATABASE_URL', 'app.db')
conn = sqlite3.connect(db_path)

# Create application table if it doesn't exist
conn.execute('''
    CREATE TABLE IF NOT EXISTS user_data (
        id INTEGER PRIMARY KEY,
        username TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
''')

# Insert sample data
conn.execute('INSERT INTO user_data (username) VALUES (?)', ('user_' + datetime.now().isoformat(),))
conn.commit()

# Query data
for row in conn.execute('SELECT * FROM user_data'):
    print(row)

conn.close()
```

## Advanced Features

### 1. Process Tracking

All executed commands are tracked in the `process_runs` table:

```sql
SELECT command, exit_code, start_time, end_time 
FROM process_runs 
ORDER BY start_time DESC;
```

### 2. Code History

View code change history:

```sql
SELECT from_sha, to_sha, change_time, status 
FROM code_changes 
ORDER BY change_time DESC;
```

### 3. Direct SQL Access

Since everything is stored in SQLite, you can query both git data and application data:

```sql
-- Find all commits
SELECT sha, datetime(created_at, 'unixepoch') as commit_time
FROM git_objects 
WHERE type = 'commit';

-- Join application data with git history
SELECT u.*, p.commit_sha, p.command
FROM user_data u
JOIN process_runs p ON p.start_time >= u.created_at
WHERE p.status = 'completed';
```

## Backup and Distribution

Since the entire application is a single SQLite file, you can:

1. Back it up with tools like Litestream:

    ```bash
    litestream replicate myapp.db s3://mybucket/myapp.db
    ```

2. Distribute it as a single file
3. Version it alongside your data
4. Run analytics across code and data together

## Limitations and Considerations

- Not designed for large repositories (all git objects are stored in SQLite)
- No built-in security/isolation between code and data
- Requires git and SQLite to be installed
- Process isolation is minimal
- Best suited for small to medium applications

## Future Enhancements

Potential improvements could include:

- Support for large files with Git LFS
- Better process isolation and sandboxing
- Performance optimizations for larger repositories
- Web interface for viewing code and data
- Integrated backup and replication
- Support for multiple applications in one database
- Improved error handling and reporting
- Cross-platform compatibility (currently requires SQLite and git)
