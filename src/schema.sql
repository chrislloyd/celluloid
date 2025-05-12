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
