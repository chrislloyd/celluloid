# Celluloid Usage Guide

Celluloid is a tool that allows you to bundle a git repository and application data into a single SQLite database, creating a self-contained application bundle.

## Installation

1. Save the `celluloid.sh` script and make it executable:
```bash
chmod +x celluloid.sh
sudo cp celluloid.sh /usr/local/bin/celluloid
```

2. Save the `git-remote-celluloid.sh` protocol helper and install it:
```bash
chmod +x git-remote-celluloid.sh
sudo cp git-remote-celluloid.sh /usr/local/bin/git-remote-celluloid
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

## Database Schema

### Git Tables

**git_objects**: Stores git objects (blobs, trees, commits, tags)
- `sha`: Object SHA-1 hash
- `type`: Object type
- `size`: Object size
- `data`: Object content (compressed)

**git_refs**: Stores git references
- `name`: Reference name (e.g., 'HEAD', 'refs/heads/main')
- `sha`: Commit SHA the ref points to
- `type`: Reference type (branch, tag, remote)

### Application Tables

**process_runs**: Tracks command executions
- `commit_sha`: The commit the command was run from
- `command`: The executed command
- `exit_code`: Command exit code
- `stdout`/`stderr`: Command output
- `status`: Execution status (running, completed, failed)

**code_changes**: Tracks code change migrations
- `from_sha`: Previous commit SHA
- `to_sha`: New commit SHA
- `status`: Migration status (pending, applied, failed)

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
