const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

// Git object types
pub const GitObjectType = enum {
    blob,
    tree,
    commit,
    tag,

    pub fn toString(self: GitObjectType) []const u8 {
        return switch (self) {
            .blob => "blob",
            .tree => "tree",
            .commit => "commit",
            .tag => "tag",
        };
    }

    pub fn fromString(str: []const u8) !GitObjectType {
        if (std.mem.eql(u8, str, "blob")) return .blob;
        if (std.mem.eql(u8, str, "tree")) return .tree;
        if (std.mem.eql(u8, str, "commit")) return .commit;
        if (std.mem.eql(u8, str, "tag")) return .tag;
        return error.InvalidGitObjectType;
    }
};

// A simple temp directory structure to replace the temp crate
const TempDir = struct {
    basename: []const u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *const TempDir) void {
        self.allocator.free(self.basename);
    }
};

// Create a temporary directory
fn create_temp_dir(allocator: std.mem.Allocator, prefix: []const u8) !TempDir {
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);

    const rand_id = try std.fmt.allocPrint(allocator, "{s}{x}{x}{x}{x}", .{
        prefix,
        rand_bytes[0],
        rand_bytes[2],
        rand_bytes[4],
        rand_bytes[6],
    });

    const path = try std.fs.path.join(allocator, &[_][]const u8{ "/tmp", rand_id });
    defer allocator.free(path);

    try std.fs.makeDirAbsolute(path);

    return TempDir{
        .basename = rand_id,
        .allocator = allocator,
    };
}

// Git reference types
pub const GitRefType = enum {
    branch,
    tag,
    remote,

    pub fn toString(self: GitRefType) []const u8 {
        return switch (self) {
            .branch => "branch",
            .tag => "tag",
            .remote => "remote",
        };
    }

    pub fn fromString(str: []const u8) !GitRefType {
        if (std.mem.eql(u8, str, "branch")) return .branch;
        if (std.mem.eql(u8, str, "tag")) return .tag;
        if (std.mem.eql(u8, str, "remote")) return .remote;
        return error.InvalidGitRefType;
    }
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // Get args
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try stdout.print("celluloid - Bundle git repositories and application data in SQLite\n\n", .{});
        try stdout.print("Usage:\n", .{});
        try stdout.print("  celluloid init <database_file>     Initialize a new Celluloid database\n", .{});
        try stdout.print("  celluloid run <database_file> <command>  Run a command from HEAD\n", .{});
        try stdout.print("  celluloid push <database_file>     Handle git push operations\n", .{});
        try stdout.print("  celluloid checkout <database_file> <sha>  Checkout code to temp directory\n", .{});
        try stdout.print("\nExample:\n", .{});
        try stdout.print("  celluloid init myapp.db\n", .{});
        try stdout.print("  git remote add bundle celluloid://myapp.db\n", .{});
        try stdout.print("  git push bundle main\n", .{});
        try stdout.print("  celluloid run myapp.db './main.sh'\n", .{});
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "init")) {
        if (args.len < 3) {
            try stdout.print("Usage: celluloid init <database_file>\n", .{});
            return;
        }
        try initDatabase(args[2]);
    } else if (std.mem.eql(u8, command, "run")) {
        if (args.len < 4) {
            try stdout.print("Usage: celluloid run <database_file> <command>\n", .{});
            return;
        }
        try runCommand(allocator, args[2], args[3], null);
    } else if (std.mem.eql(u8, command, "push")) {
        if (args.len < 3) {
            try stdout.print("Usage: celluloid push <database_file>\n", .{});
            return;
        }
        try gitProtocolHelper(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "checkout")) {
        if (args.len < 4) {
            try stdout.print("Usage: celluloid checkout <database_file> <commit_sha>\n", .{});
            return;
        }
        const temp_dir = try checkoutCode(allocator, args[2], args[3]);
        try stdout.print("Code checked out to: {s}\n", .{temp_dir});
    } else {
        try stdout.print("Unknown command: {s}\n", .{command});
    }
}

// Database connection helper
fn openDatabase(db_path: []const u8) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    const result = c.sqlite3_open(db_path.ptr, &db);
    if (result != c.SQLITE_OK) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Failed to open database: {s}\n", .{c.sqlite3_errmsg(db)});
        _ = c.sqlite3_close(db);
        return error.DatabaseOpenFailed;
    }
    return db.?;
}

// Initialize the database with the schema
fn initDatabase(db_path: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const db = try openDatabase(db_path);
    defer _ = c.sqlite3_close(db);

    // SQL for creating the schema
    const schema = @embedFile("schema.sql");

    var error_msg: [*c]u8 = null;
    const exec_result = c.sqlite3_exec(db, schema, null, null, &error_msg);
    if (exec_result != c.SQLITE_OK) {
        try stdout.print("SQL error: {s}\n", .{error_msg});
        c.sqlite3_free(error_msg);
        return error.DatabaseInitFailed;
    }

    try stdout.print("Initialized new Celluloid database: {s}\n", .{db_path});
}

// Store a git object in the database
fn storeGitObject(db: *c.sqlite3, sha: []const u8, obj_type: GitObjectType, size: usize, data: []const u8) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT OR REPLACE INTO git_objects (sha, type, size, data) VALUES (?, ?, ?, ?)";
    const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        return error.SQLPrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters
    _ = c.sqlite3_bind_text(stmt, 1, sha.ptr, @intCast(sha.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, obj_type.toString().ptr, @intCast(obj_type.toString().len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(size));
    _ = c.sqlite3_bind_blob(stmt, 4, data.ptr, @intCast(data.len), c.SQLITE_STATIC);

    // Execute
    const exec_result = c.sqlite3_step(stmt);
    if (exec_result != c.SQLITE_DONE) {
        return error.SQLExecuteError;
    }
}

// Get a git object from the database
fn getGitObject(allocator: std.mem.Allocator, db: *c.sqlite3, sha: []const u8) ![]const u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT data FROM git_objects WHERE sha = ?";
    const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        return error.SQLPrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters
    _ = c.sqlite3_bind_text(stmt, 1, sha.ptr, @intCast(sha.len), c.SQLITE_STATIC);

    // Execute and get result
    const step_result = c.sqlite3_step(stmt);
    if (step_result == c.SQLITE_ROW) {
        const data_ptr = c.sqlite3_column_blob(stmt, 0);
        const data_len = c.sqlite3_column_bytes(stmt, 0);

        // Allocate memory for the result
        const data = try allocator.alloc(u8, @intCast(data_len));
        @memcpy(data, @as([*]const u8, @ptrCast(data_ptr))[0..@intCast(data_len)]);
        return data;
    } else {
        return error.GitObjectNotFound;
    }
}

// Update a git reference
fn updateRef(db: *c.sqlite3, ref_name: []const u8, sha: []const u8, ref_type: GitRefType) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT OR REPLACE INTO git_refs (name, sha, type) VALUES (?, ?, ?)";
    const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        return error.SQLPrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters
    _ = c.sqlite3_bind_text(stmt, 1, ref_name.ptr, @intCast(ref_name.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 2, sha.ptr, @intCast(sha.len), c.SQLITE_STATIC);
    _ = c.sqlite3_bind_text(stmt, 3, ref_type.toString().ptr, @intCast(ref_type.toString().len), c.SQLITE_STATIC);

    // Execute
    const exec_result = c.sqlite3_step(stmt);
    if (exec_result != c.SQLITE_DONE) {
        return error.SQLExecuteError;
    }
}

// Get HEAD commit SHA
fn getHeadSha(allocator: std.mem.Allocator, db: *c.sqlite3) ![]const u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT sha FROM git_refs WHERE name = 'HEAD'";
    const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        return error.SQLPrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Execute and get result
    const step_result = c.sqlite3_step(stmt);
    if (step_result == c.SQLITE_ROW) {
        const text_ptr = c.sqlite3_column_text(stmt, 0);
        const text_len = c.sqlite3_column_bytes(stmt, 0);

        // If empty HEAD, return error
        if (text_len == 0) {
            return error.EmptyHeadCommit;
        }

        // Allocate memory for the result
        const sha = try allocator.alloc(u8, @intCast(text_len));
        @memcpy(sha, @as([*]const u8, @ptrCast(text_ptr))[0..@intCast(text_len)]);
        return sha;
    } else {
        return error.HeadRefNotFound;
    }
}

// Checkout code to temporary directory
fn checkoutCode(allocator: std.mem.Allocator, db_path: []const u8, commit_sha: []const u8) ![]const u8 {
    const stdout = std.io.getStdOut().writer();
    const db = try openDatabase(db_path);
    defer _ = c.sqlite3_close(db);

    // Create temporary directory
    const temp_dir = try create_temp_dir(allocator, "celluloid-");

    // Initialize git repository in the temp directory
    try stdout.print("Initializing git repository in {s}\n", .{temp_dir.basename});

    // Get absolute path to temp directory
    const temp_path = try std.fs.path.join(allocator, &[_][]const u8{ "/tmp", temp_dir.basename });
    defer allocator.free(temp_path);

    // Initialize git repository
    const init_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "init", "--quiet", temp_path },
    });
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);

    // Change to the temp directory
    try std.process.changeCurDir(temp_path);

    // Export all objects from database
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT sha, type, data FROM git_objects";
    const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
    if (prepare_result != c.SQLITE_OK) {
        return error.SQLPrepareError;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const git_dir = try std.fs.path.join(allocator, &[_][]const u8{ temp_path, ".git" });
    defer allocator.free(git_dir);

    const objects_dir = try std.fs.path.join(allocator, &[_][]const u8{ git_dir, "objects" });
    defer allocator.free(objects_dir);

    try stdout.print("Exporting git objects...\n", .{});

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const sha = c.sqlite3_column_text(stmt, 0);
        const sha_len = c.sqlite3_column_bytes(stmt, 0);
        // Get the SHA as a string but we don't need it here since we're using the data directly
        _ = @as([*]const u8, @ptrCast(sha))[0..@intCast(sha_len)];

        const data_ptr = c.sqlite3_column_blob(stmt, 2);
        const data_len = c.sqlite3_column_bytes(stmt, 2);
        const data = @as([*]const u8, @ptrCast(data_ptr))[0..@intCast(data_len)];

        // Use git hash-object to import the object
        var child = std.process.Child.init(&[_][]const u8{ "git", "hash-object", "-w", "--stdin" }, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        if (child.stdin) |stdin| {
            try stdin.writeAll(data);
            stdin.close();
        }

        const result = try child.wait();
        _ = result; // We don't actually need to check the result
    }

    // Create a reference to the commit
    try stdout.print("Creating reference to commit {s}...\n", .{commit_sha});

    const update_ref_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "update-ref", "refs/heads/celluloid", commit_sha },
        .cwd = temp_path,
    });
    defer allocator.free(update_ref_result.stdout);
    defer allocator.free(update_ref_result.stderr);

    // Checkout the reference
    try stdout.print("Checking out commit...\n", .{});

    const checkout_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "checkout", "celluloid" },
        .cwd = temp_path,
    });
    defer allocator.free(checkout_result.stdout);
    defer allocator.free(checkout_result.stderr);

    return allocator.dupe(u8, temp_path);
}

// Run a command from a specific commit
fn runCommand(allocator: std.mem.Allocator, db_path: []const u8, command: []const u8, commit_sha_opt: ?[]const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const db = try openDatabase(db_path);
    defer _ = c.sqlite3_close(db);

    // Use provided commit SHA or get HEAD
    const commit_sha = if (commit_sha_opt) |sha| sha else try getHeadSha(allocator, db);

    // Checkout code to temporary directory
    const work_dir = try checkoutCode(allocator, db_path, commit_sha);
    defer std.fs.deleteTreeAbsolute(work_dir) catch {};

    // Record process start
    // TODO: Record process in database

    // Execute the command with DATABASE_URL set
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("DATABASE_URL", db_path);

    try stdout.print("Executing command: {s}\n", .{command});
    try stdout.print("Working directory: {s}\n", .{work_dir});

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", command },
        .env_map = &env_map,
        .cwd = work_dir,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try stdout.print("Command completed with exit code: {d}\n", .{result.term.Exited});
    try stdout.print("stdout: {s}\n", .{result.stdout});
    try stdout.print("stderr: {s}\n", .{result.stderr});

    // TODO: Update process record in database
}

// Handle git push operations
fn handlePush(allocator: std.mem.Allocator, db_path: []const u8, from_sha: []const u8, to_sha: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const db = try openDatabase(db_path);
    defer _ = c.sqlite3_close(db);

    // Begin transaction
    _ = c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, null);

    // Record code change attempt in database
    var change_id: i64 = 0;
    {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "INSERT INTO code_changes (from_sha, to_sha, status) VALUES (?, ?, 'pending') RETURNING id";
        const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
        if (prepare_result != c.SQLITE_OK) {
            return error.SQLPrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        // Bind parameters
        _ = c.sqlite3_bind_text(stmt, 1, from_sha.ptr, @intCast(from_sha.len), c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, to_sha.ptr, @intCast(to_sha.len), c.SQLITE_STATIC);

        // Execute
        const exec_result = c.sqlite3_step(stmt);
        if (exec_result == c.SQLITE_ROW) {
            change_id = c.sqlite3_column_int64(stmt, 0);
        } else {
            try stdout.print("Failed to record code change attempt: {s}\n", .{c.sqlite3_errmsg(db)});
            _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
            return error.SQLExecuteError;
        }
    }

    try stdout.print("Recorded code change attempt with ID {d}\n", .{change_id});

    // Checkout code to temporary directory
    try stdout.print("Checking out code from commit {s}...\n", .{to_sha});
    const temp_dir = try checkoutCode(allocator, db_path, to_sha);
    defer {
        // Can't use try inside defer, so use catch{} to handle errors silently
        stdout.print("Cleaning up temporary directory {s}\n", .{temp_dir}) catch {};
        std.fs.deleteTreeAbsolute(temp_dir) catch |err| {
            stdout.print("Warning: Failed to clean up temporary directory: {any}\n", .{err}) catch {};
        };
    }

    // Check if code_change.sh exists in the new commit
    const code_change_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "code_change.sh" });
    defer allocator.free(code_change_path);

    const code_change_exists = blk: {
        std.fs.accessAbsolute(code_change_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (code_change_exists) {
        try stdout.print("Running code_change.sh script from {s}...\n", .{code_change_path});
        // Execute code_change.sh script with the previous commit SHA
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();
        try env_map.put("DATABASE_URL", db_path);

        // Update code_changes record to indicate script is running
        {
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "UPDATE code_changes SET status = 'running' WHERE id = ?";
            const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
            if (prepare_result != c.SQLITE_OK) {
                _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
                return error.SQLPrepareError;
            }
            defer _ = c.sqlite3_finalize(stmt);

            // Bind parameters
            _ = c.sqlite3_bind_int64(stmt, 1, change_id);

            // Execute
            _ = c.sqlite3_step(stmt);
        }

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ code_change_path, from_sha, to_sha },
            .env_map = &env_map,
            .cwd = temp_dir,
        }) catch |err| {
            // Rollback on error and update code_changes record
            _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
            try stdout.print("Code change script failed with error: {any}\n", .{err});

            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "UPDATE code_changes SET status = 'failed', error_message = ? WHERE id = ?";
            const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
            if (prepare_result != c.SQLITE_OK) {
                return error.SQLPrepareError;
            }
            defer _ = c.sqlite3_finalize(stmt);

            // Bind parameters
            const error_msg = try std.fmt.allocPrint(allocator, "Script execution error: {any}", .{err});
            defer allocator.free(error_msg);
            _ = c.sqlite3_bind_text(stmt, 1, error_msg.ptr, @intCast(error_msg.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(stmt, 2, change_id);

            // Execute
            _ = c.sqlite3_step(stmt);

            return error.CodeChangeScriptFailed;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            // Rollback on non-zero exit code and update code_changes record
            _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
            try stdout.print("Code change script failed with exit code: {d}\n", .{result.term.Exited});
            try stdout.print("stdout: {s}\n", .{result.stdout});
            try stdout.print("stderr: {s}\n", .{result.stderr});

            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "UPDATE code_changes SET status = 'failed', error_message = ? WHERE id = ?";
            const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
            if (prepare_result != c.SQLITE_OK) {
                return error.SQLPrepareError;
            }
            defer _ = c.sqlite3_finalize(stmt);

            // Combine stdout and stderr for error message
            const error_msg = try std.fmt.allocPrint(allocator, "Exit code {d}\nstdout: {s}\nstderr: {s}", .{ result.term.Exited, result.stdout, result.stderr });
            defer allocator.free(error_msg);

            // Bind parameters
            _ = c.sqlite3_bind_text(stmt, 1, error_msg.ptr, @intCast(error_msg.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(stmt, 2, change_id);

            // Execute
            _ = c.sqlite3_step(stmt);

            return error.CodeChangeScriptFailed;
        }

        // Success - commit the transaction and update code_changes record
        _ = c.sqlite3_exec(db, "COMMIT", null, null, null);

        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "UPDATE code_changes SET status = 'applied' WHERE id = ?";
        const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
        if (prepare_result != c.SQLITE_OK) {
            return error.SQLPrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        // Bind parameters
        _ = c.sqlite3_bind_int64(stmt, 1, change_id);

        // Execute
        _ = c.sqlite3_step(stmt);

        try updateRef(db, "HEAD", to_sha, .branch);
        try stdout.print("Code change applied successfully\n", .{});
    } else {
        // No code_change.sh - just update the ref and code_changes record
        _ = c.sqlite3_exec(db, "COMMIT", null, null, null);

        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "UPDATE code_changes SET status = 'applied' WHERE id = ?";
        const prepare_result = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
        if (prepare_result != c.SQLITE_OK) {
            return error.SQLPrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        // Bind parameters
        _ = c.sqlite3_bind_int64(stmt, 1, change_id);

        // Execute
        _ = c.sqlite3_step(stmt);

        try updateRef(db, "HEAD", to_sha, .branch);
        try stdout.print("Code pushed successfully (no code_change.sh)\n", .{});
    }
}

// Git protocol helper for push operations
fn gitProtocolHelper(allocator: std.mem.Allocator, db_path: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    const db = try openDatabase(db_path);
    defer _ = c.sqlite3_close(db);

    var buf: [1024]u8 = undefined;
    while (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r\n");
        var iterator = std.mem.splitScalar(u8, trimmed, ' ');
        const cmd = iterator.next() orelse "";

        if (std.mem.eql(u8, cmd, "capabilities")) {
            try stdout.print("fetch\n", .{});
            try stdout.print("push\n", .{});
            try stdout.print("option\n", .{});
            try stdout.print("\n", .{});
        } else if (std.mem.eql(u8, cmd, "list")) {
            // List all refs
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "SELECT sha, name FROM git_refs";
            _ = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
            defer _ = c.sqlite3_finalize(stmt);

            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const sha = c.sqlite3_column_text(stmt, 0);
                const sha_len = c.sqlite3_column_bytes(stmt, 0);
                const name = c.sqlite3_column_text(stmt, 1);
                const name_len = c.sqlite3_column_bytes(stmt, 1);

                try stdout.print("{s} {s}\n", .{
                    @as([*]const u8, @ptrCast(sha))[0..@intCast(sha_len)],
                    @as([*]const u8, @ptrCast(name))[0..@intCast(name_len)],
                });
            }
            try stdout.print("\n", .{});
        } else if (std.mem.eql(u8, cmd, "push")) {
            // Handle push
            // Format: push +<from>:<to> <ref>
            const arg1 = iterator.next() orelse "";
            const from_to = if (arg1[0] == '+') arg1[1..] else arg1;

            var from_to_iter = std.mem.splitScalar(u8, from_to, ':');
            const from = from_to_iter.next() orelse "";
            const to = from_to_iter.next() orelse "";

            try handlePush(allocator, db_path, from, to);
        } else if (std.mem.eql(u8, cmd, "")) {
            break;
        }
    }
}
