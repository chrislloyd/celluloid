const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

// Git object types from main.zig
const GitObjectType = @import("main.zig").GitObjectType;
const GitRefType = @import("main.zig").GitRefType;

// Function to open a database connection
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

// Import a git object into the database
fn importObject(allocator: std.mem.Allocator, db: *c.sqlite3, sha: []const u8) !void {
    // Get object type using git cat-file -t
    const type_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "cat-file", "-t", sha },
    });
    defer allocator.free(type_result.stdout);
    defer allocator.free(type_result.stderr);

    if (type_result.term.Exited != 0) {
        return error.GitObjectNotFound;
    }

    const obj_type_str = std.mem.trimRight(u8, type_result.stdout, "\r\n");
    const obj_type = try GitObjectType.fromString(obj_type_str);

    // Get object size using git cat-file -s
    const size_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "cat-file", "-s", sha },
    });
    defer allocator.free(size_result.stdout);
    defer allocator.free(size_result.stderr);

    const size_str = std.mem.trimRight(u8, size_result.stdout, "\r\n");
    const size = try std.fmt.parseInt(usize, size_str, 10);

    // Get object data using git cat-file <type>
    const data_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "cat-file", obj_type_str, sha },
    });
    defer allocator.free(data_result.stdout);
    defer allocator.free(data_result.stderr);

    // Store the object in the database
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
    _ = c.sqlite3_bind_blob(stmt, 4, data_result.stdout.ptr, @intCast(data_result.stdout.len), c.SQLITE_STATIC);

    // Execute
    const exec_result = c.sqlite3_step(stmt);
    if (exec_result != c.SQLITE_DONE) {
        return error.SQLExecuteError;
    }
}

// Export a git object from the database
fn exportObject(allocator: std.mem.Allocator, db: *c.sqlite3, sha: []const u8) !void {
    // Get object type and data from database
    var type_stmt: ?*c.sqlite3_stmt = null;
    const type_sql = "SELECT type FROM git_objects WHERE sha = ?";
    _ = c.sqlite3_prepare_v2(db, type_sql, @intCast(type_sql.len), &type_stmt, null);
    defer _ = c.sqlite3_finalize(type_stmt);
    _ = c.sqlite3_bind_text(type_stmt, 1, sha.ptr, @intCast(sha.len), c.SQLITE_STATIC);

    if (c.sqlite3_step(type_stmt) != c.SQLITE_ROW) {
        return error.GitObjectNotFound;
    }

    const obj_type_str = c.sqlite3_column_text(type_stmt, 0);
    const obj_type_len = c.sqlite3_column_bytes(type_stmt, 0);
    const obj_type = @as([*]const u8, @ptrCast(obj_type_str))[0..@intCast(obj_type_len)];

    // Get object data
    var data_stmt: ?*c.sqlite3_stmt = null;
    const data_sql = "SELECT data FROM git_objects WHERE sha = ?";
    _ = c.sqlite3_prepare_v2(db, data_sql, @intCast(data_sql.len), &data_stmt, null);
    defer _ = c.sqlite3_finalize(data_stmt);
    _ = c.sqlite3_bind_text(data_stmt, 1, sha.ptr, @intCast(sha.len), c.SQLITE_STATIC);

    if (c.sqlite3_step(data_stmt) != c.SQLITE_ROW) {
        return error.GitObjectNotFound;
    }

    const data_ptr = c.sqlite3_column_blob(data_stmt, 0);
    const data_len = c.sqlite3_column_bytes(data_stmt, 0);

    // Write to temp file
    const temp_path = try std.fs.path.join(allocator, &[_][]const u8{ "/tmp", "celluloid-object-XXXXXX" });
    defer allocator.free(temp_path);

    const temp_file = try std.fs.createFileAbsolute(temp_path, .{ .read = true, .truncate = true });
    defer temp_file.close();

    const data = @as([*]const u8, @ptrCast(data_ptr))[0..@intCast(data_len)];
    _ = try temp_file.writeAll(data);

    // Use git hash-object -w to import into git
    // Reset file position to start
    try temp_file.seekTo(0);
    
    var child = std.process.Child.init(&[_][]const u8{ "git", "hash-object", "-w", "--stdin", "-t", obj_type }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    
    // Copy file contents to stdin
    const file_contents = try temp_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(file_contents);
    try child.stdin.?.writeAll(file_contents);
    child.stdin.?.close();
    
    const result = try child.wait();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);    
    const run_result = .{ .term = result, .stdout = stdout, .stderr = stderr };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    switch (run_result.term) {
        .Exited => |code| if (code != 0) {
            return error.GitObjectImportFailed;
        },
        else => return error.GitObjectImportFailed,
    }
}

// Import all objects reachable from a commit
fn importCommitObjects(allocator: std.mem.Allocator, db: *c.sqlite3, commit: []const u8) !void {
    // Get all objects reachable from this commit
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-list", "--objects", commit },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, line, ' ');
        const sha = parts.next() orelse continue;

        try importObject(allocator, db, sha);
    }
}

// Main entry point for git-remote-celluloid
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: git-remote-celluloid <remote> <url>\n", .{});
        return error.InvalidArguments;
    }

    // Parse URL to extract database path
    // Format: celluloid://<db_path>
    const url = args[2];
    if (!std.mem.startsWith(u8, url, "celluloid://")) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Invalid URL: {s}, must start with celluloid://\n", .{url});
        return error.InvalidURL;
    }

    const db_path = url["celluloid://".len..];

    // Check if database file exists
    std.fs.accessAbsolute(db_path, .{}) catch {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: Database file not found: {s}\n", .{db_path});
        return error.DatabaseNotFound;
    };

    // Open database
    const db = try openDatabase(db_path);
    defer _ = c.sqlite3_close(db);

    // Handle the git protocol conversation
    var buf: [4096]u8 = undefined;
    while (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const trimmed_line = std.mem.trimRight(u8, line, "\r\n");
        if (trimmed_line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed_line, ' ');
        const command = parts.next() orelse "";

        if (std.mem.eql(u8, command, "capabilities")) {
            try stdout.print("fetch\n", .{});
            try stdout.print("push\n", .{});
            try stdout.print("option\n", .{});
            try stdout.print("\n", .{});
        } else if (std.mem.eql(u8, command, "list")) {
            try stdout.print("? HEAD\n", .{});

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
        } else if (std.mem.eql(u8, command, "fetch")) {
            _ = parts.next() orelse "";
            const ref = parts.next() orelse "";
            _ = ref; // Unused for now

            // Export objects from database to local git
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "SELECT sha FROM git_objects";
            _ = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
            defer _ = c.sqlite3_finalize(stmt);

            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const obj_sha = c.sqlite3_column_text(stmt, 0);
                const obj_sha_len = c.sqlite3_column_bytes(stmt, 0);
                const obj_sha_str = @as([*]const u8, @ptrCast(obj_sha))[0..@intCast(obj_sha_len)];

                try exportObject(allocator, db, obj_sha_str);
            }

            try stdout.print("\n", .{});
        } else if (std.mem.eql(u8, command, "push")) {
            // Handle push operations
            // Format: push [+]<src>:<dst> <ref>
            const src_dst = parts.next() orelse "";
            const ref = parts.next() orelse "";

            // Check if there's a leading + and remove it
            const src_dst_clean = if (src_dst.len > 0 and src_dst[0] == '+')
                src_dst[1..]
            else
                src_dst;

            var src_dst_parts = std.mem.splitScalar(u8, src_dst_clean, ':');
            const src = src_dst_parts.next() orelse "";
            _ = src_dst_parts.next() orelse "";

            // Import all objects from the source commit
            try importCommitObjects(allocator, db, src);

            // Get the current HEAD
            var stmt: ?*c.sqlite3_stmt = null;
            const sql = "SELECT sha FROM git_refs WHERE name = 'HEAD'";
            _ = c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null);
            defer _ = c.sqlite3_finalize(stmt);

            var old_head: []u8 = "";
            var head_owned = false;
            if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const sha = c.sqlite3_column_text(stmt, 0);
                const sha_len = c.sqlite3_column_bytes(stmt, 0);
                if (sha_len > 0) {
                    old_head = try allocator.alloc(u8, @intCast(sha_len));
                    head_owned = true;
                    @memcpy(old_head, @as([*]const u8, @ptrCast(sha))[0..@intCast(sha_len)]);
                }
            }
            defer if (head_owned) allocator.free(old_head);

            // Update the reference in the database
            var ref_type = GitRefType.branch;
            if (std.mem.startsWith(u8, ref, "refs/tags/")) {
                ref_type = GitRefType.tag;
            } else if (std.mem.startsWith(u8, ref, "refs/remotes/")) {
                ref_type = GitRefType.remote;
            }

            var update_stmt: ?*c.sqlite3_stmt = null;
            const update_sql = "INSERT OR REPLACE INTO git_refs (name, sha, type) VALUES (?, ?, ?)";
            _ = c.sqlite3_prepare_v2(db, update_sql, @intCast(update_sql.len), &update_stmt, null);
            defer _ = c.sqlite3_finalize(update_stmt);

            _ = c.sqlite3_bind_text(update_stmt, 1, ref.ptr, @intCast(ref.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(update_stmt, 2, src.ptr, @intCast(src.len), c.SQLITE_STATIC);
            _ = c.sqlite3_bind_text(update_stmt, 3, ref_type.toString().ptr, @intCast(ref_type.toString().len), c.SQLITE_STATIC);

            const update_result = c.sqlite3_step(update_stmt);
            if (update_result != c.SQLITE_DONE) {
                try stdout.print("error {s} failed to update reference\n", .{ref});
                continue;
            }

            // Update HEAD if pushing to the main branch
            if (std.mem.eql(u8, ref, "refs/heads/main") or std.mem.eql(u8, ref, "refs/heads/master")) {
                // Create a temporary directory
                const temp_dir = try std.fs.path.join(allocator, &[_][]const u8{ "/tmp", try std.fmt.allocPrint(allocator, "celluloid-{d}", .{std.time.timestamp()}) });
                defer allocator.free(temp_dir);
                defer std.fs.deleteTreeAbsolute(temp_dir) catch {};

                try std.fs.makeDirAbsolute(temp_dir);

                // Checkout the code
                const checkout_result = try std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &[_][]const u8{ "git", "--git-dir=.", "--work-tree=", temp_dir, "checkout", "-f", src },
                });
                defer allocator.free(checkout_result.stdout);
                defer allocator.free(checkout_result.stderr);

                if (checkout_result.term.Exited != 0) {
                    try stdout.print("error {s} failed to checkout code\n", .{ref});
                    continue;
                }

                // Check if code_change.sh exists
                const code_change_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "code_change.sh" });
                defer allocator.free(code_change_path);

                const has_code_change = blk: {
                    std.fs.accessAbsolute(code_change_path, .{}) catch break :blk false;
                    break :blk true;
                };

                if (has_code_change) {
                    // Begin transaction
                    _ = c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, null);

                    // Run code_change.sh
                    var env_map = try std.process.getEnvMap(allocator);
                    defer env_map.deinit();
                    try env_map.put("DATABASE_URL", db_path);

                    const code_change_result = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &[_][]const u8{ code_change_path, old_head },
                        .env_map = &env_map,
                        .cwd = temp_dir,
                    });
                    defer allocator.free(code_change_result.stdout);
                    defer allocator.free(code_change_result.stderr);

                    if (code_change_result.term.Exited != 0) {
                        // Rollback on failure
                        _ = c.sqlite3_exec(db, "ROLLBACK", null, null, null);
                        try stdout.print("error {s} code_change.sh failed\n", .{ref});
                        continue;
                    }

                    // Success - commit the transaction
                    _ = c.sqlite3_exec(db, "COMMIT", null, null, null);

                    // Update HEAD
                    var head_stmt: ?*c.sqlite3_stmt = null;
                    const head_sql = "UPDATE git_refs SET sha = ? WHERE name = 'HEAD'";
                    _ = c.sqlite3_prepare_v2(db, head_sql, @intCast(head_sql.len), &head_stmt, null);
                    defer _ = c.sqlite3_finalize(head_stmt);

                    _ = c.sqlite3_bind_text(head_stmt, 1, src.ptr, @intCast(src.len), c.SQLITE_STATIC);
                    _ = c.sqlite3_step(head_stmt);
                } else {
                    // No code_change.sh - just update HEAD
                    var head_stmt: ?*c.sqlite3_stmt = null;
                    const head_sql = "UPDATE git_refs SET sha = ? WHERE name = 'HEAD'";
                    _ = c.sqlite3_prepare_v2(db, head_sql, @intCast(head_sql.len), &head_stmt, null);
                    defer _ = c.sqlite3_finalize(head_stmt);

                    _ = c.sqlite3_bind_text(head_stmt, 1, src.ptr, @intCast(src.len), c.SQLITE_STATIC);
                    _ = c.sqlite3_step(head_stmt);
                }

                try stdout.print("ok {s}\n", .{ref});
            } else {
                try stdout.print("ok {s}\n", .{ref});
            }

            try stdout.print("\n", .{});
        } else if (std.mem.eql(u8, command, "option")) {
            try stdout.print("ok\n", .{});
        } else if (std.mem.eql(u8, command, "")) {
            break;
        } else {
            try stdout.print("error Unknown command: {s}\n", .{command});
        }
    }
}
