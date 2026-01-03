// SPDX-License-Identifier: AGPL-3.0-or-later
//! Zig prover orchestration library
//!
//! Pure Zig implementation supporting 12 theorem provers:
//! - Tier 1: Agda, Coq, Lean, Isabelle, Z3, CVC5
//! - Tier 2: Metamath, HOL Light, Mizar
//! - Tier 3: PVS, ACL2, HOL4
//!
//! Two execution modes:
//! 1. GraphQL client to ECHIDNA Core (primary)
//! 2. Direct subprocess execution (fallback)
//!
//! C-free: No @cImport, no C headers, no Rust shim.

const std = @import("std");
const mem = std.mem;

// =============================================================================
// Types
// =============================================================================

pub const Error = error{
    InitFailed,
    ConnectionFailed,
    RequestFailed,
    ParseFailed,
    VerificationFailed,
    ProverNotFound,
    Timeout,
    AllocationFailed,
    InvalidResponse,
    SubprocessFailed,
    OutOfMemory,
};

/// Proof verification status
pub const ProofStatus = enum(u8) {
    verified = 0,
    failed = 1,
    timeout = 2,
    err = 3,
    unknown = 4,

    pub fn fromString(s: []const u8) ProofStatus {
        if (mem.eql(u8, s, "VERIFIED")) return .verified;
        if (mem.eql(u8, s, "FAILED")) return .failed;
        if (mem.eql(u8, s, "TIMEOUT")) return .timeout;
        if (mem.eql(u8, s, "ERROR")) return .err;
        return .unknown;
    }
};

/// Supported theorem provers (matches echidnabot)
pub const ProverKind = enum(u8) {
    // Tier 1 (complete in ECHIDNA)
    agda = 0,
    coq = 1,
    lean = 2,
    isabelle = 3,
    z3 = 4,
    cvc5 = 5,
    // Tier 2 (complete in ECHIDNA)
    metamath = 6,
    hol_light = 7,
    mizar = 8,
    // Tier 3 (stubs in ECHIDNA)
    pvs = 9,
    acl2 = 10,
    hol4 = 11,

    pub fn tier(self: ProverKind) u8 {
        return switch (self) {
            .agda, .coq, .lean, .isabelle, .z3, .cvc5 => 1,
            .metamath, .hol_light, .mizar => 2,
            .pvs, .acl2, .hol4 => 3,
        };
    }

    pub fn displayName(self: ProverKind) []const u8 {
        return switch (self) {
            .agda => "Agda",
            .coq => "Coq",
            .lean => "Lean 4",
            .isabelle => "Isabelle/HOL",
            .z3 => "Z3",
            .cvc5 => "CVC5",
            .metamath => "Metamath",
            .hol_light => "HOL Light",
            .mizar => "Mizar",
            .pvs => "PVS",
            .acl2 => "ACL2",
            .hol4 => "HOL4",
        };
    }

    pub fn executable(self: ProverKind) []const u8 {
        return switch (self) {
            .agda => "agda",
            .coq => "coqc",
            .lean => "lean",
            .isabelle => "isabelle",
            .z3 => "z3",
            .cvc5 => "cvc5",
            .metamath => "metamath",
            .hol_light => "hol_light",
            .mizar => "mizar",
            .pvs => "pvs",
            .acl2 => "acl2",
            .hol4 => "hol4",
        };
    }

    pub fn fileExtensions(self: ProverKind) []const []const u8 {
        return switch (self) {
            .agda => &.{ ".agda", ".lagda", ".lagda.md" },
            .coq => &.{".v"},
            .lean => &.{".lean"},
            .isabelle => &.{".thy"},
            .z3 => &.{ ".smt2", ".z3" },
            .cvc5 => &.{ ".smt2", ".cvc5" },
            .metamath => &.{".mm"},
            .hol_light => &.{".ml"},
            .mizar => &.{".miz"},
            .pvs => &.{".pvs"},
            .acl2 => &.{ ".lisp", ".acl2" },
            .hol4 => &.{".sml"},
        };
    }

    pub fn fromExtension(ext: []const u8) ?ProverKind {
        const provers = [_]ProverKind{
            .agda,     .coq,       .lean,  .isabelle, .z3,   .cvc5,
            .metamath, .hol_light, .mizar, .pvs,      .acl2, .hol4,
        };
        for (provers) |prover| {
            for (prover.fileExtensions()) |prover_ext| {
                if (mem.eql(u8, ext, prover_ext)) {
                    return prover;
                }
            }
        }
        return null;
    }

    pub fn count() u8 {
        return 12;
    }
};

/// Proof verification result
pub const ProofResult = struct {
    status: ProofStatus,
    message: []const u8,
    prover_output: []const u8,
    duration_ms: u64,

    pub fn deinit(self: *ProofResult, allocator: mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.prover_output);
    }
};

/// Tactic suggestion from ML component
pub const TacticSuggestion = struct {
    tactic: []const u8,
    confidence: f64,
    explanation: ?[]const u8,

    pub fn deinit(self: *TacticSuggestion, allocator: mem.Allocator) void {
        allocator.free(self.tactic);
        if (self.explanation) |exp| {
            allocator.free(exp);
        }
    }
};

// =============================================================================
// Prover Client
// =============================================================================

pub const ProverClient = struct {
    allocator: mem.Allocator,
    endpoint: []const u8,
    timeout_ms: u64,
    use_subprocess_fallback: bool,

    const Self = @This();

    /// Create a new prover client
    pub fn init(allocator: mem.Allocator, endpoint: []const u8) Self {
        return Self{
            .allocator = allocator,
            .endpoint = endpoint,
            .timeout_ms = 300_000, // 5 minutes default
            .use_subprocess_fallback = true,
        };
    }

    /// Verify a proof via GraphQL or subprocess
    pub fn verifyProof(
        self: *Self,
        prover: ProverKind,
        content: []const u8,
        filename: ?[]const u8,
    ) Error!ProofResult {
        // Try subprocess execution (simpler, always works if prover is installed)
        // GraphQL client can be added later when std.http stabilizes
        return self.verifyViaSubprocess(prover, content, filename);
    }

    /// Verify via direct subprocess execution
    fn verifyViaSubprocess(
        self: *Self,
        prover: ProverKind,
        content: []const u8,
        filename: ?[]const u8,
    ) Error!ProofResult {
        const start_time = std.time.milliTimestamp();

        // Write content to temp file if no filename provided
        var tmp_file: ?std.fs.File = null;
        const file_path: []const u8 = if (filename) |f| f else blk: {
            // Create temp file
            const ext = if (prover.fileExtensions().len > 0) prover.fileExtensions()[0] else ".tmp";
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/tmp/proof_input{s}", .{ext}) catch return Error.AllocationFailed;
            tmp_file = std.fs.createFileAbsolute(path, .{}) catch return Error.SubprocessFailed;
            tmp_file.?.writeAll(content) catch return Error.SubprocessFailed;
            tmp_file.?.close();
            tmp_file = null;
            break :blk self.allocator.dupe(u8, path) catch return Error.OutOfMemory;
        };
        defer if (filename == null) self.allocator.free(file_path);

        // Build command based on prover
        const result = switch (prover) {
            .z3 => self.runProver(&[_][]const u8{ "z3", file_path }),
            .cvc5 => self.runProver(&[_][]const u8{ "cvc5", file_path }),
            .coq => self.runProver(&[_][]const u8{ "coqc", file_path }),
            .lean => self.runProver(&[_][]const u8{ "lean", file_path }),
            .agda => self.runProver(&[_][]const u8{ "agda", file_path }),
            .isabelle => blk: {
                // Isabelle builds sessions from ROOT files, not individual .thy files
                // Get the directory containing the .thy file
                const dir = std.fs.path.dirname(file_path) orelse ".";
                break :blk self.runProver(&[_][]const u8{ "isabelle", "build", "-d", dir, "-a" });
            },
            .metamath => self.runProver(&[_][]const u8{ "metamath", file_path }),
            .hol_light => self.runProver(&[_][]const u8{ "hol_light", file_path }),
            .mizar => self.runProver(&[_][]const u8{ "mizar", file_path }),
            .pvs => self.runProver(&[_][]const u8{ "pvs", "-batch", file_path }),
            .acl2 => self.runProver(&[_][]const u8{ "acl2", "<", file_path }),
            .hol4 => self.runProver(&[_][]const u8{ "hol4", file_path }),
        };

        const end_time = std.time.milliTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        const exit_code = result catch {
            return ProofResult{
                .status = .err,
                .message = self.allocator.dupe(u8, "Prover execution failed") catch return Error.OutOfMemory,
                .prover_output = self.allocator.dupe(u8, "") catch return Error.OutOfMemory,
                .duration_ms = duration,
            };
        };

        const status: ProofStatus = if (exit_code == 0) .verified else .failed;

        return ProofResult{
            .status = status,
            .message = self.allocator.dupe(u8, if (status == .verified) "Proof verified" else "Proof failed") catch return Error.OutOfMemory,
            .prover_output = self.allocator.dupe(u8, "") catch return Error.OutOfMemory,
            .duration_ms = duration,
        };
    }

    /// Run a prover subprocess
    fn runProver(self: *Self, argv: []const []const u8) !u8 {
        _ = self;
        var child = std.process.Child.init(argv, std.heap.page_allocator);
        _ = child.spawn() catch return error.SubprocessFailed;
        const term = child.wait() catch return error.SubprocessFailed;
        return switch (term) {
            .Exited => |code| code,
            else => 1,
        };
    }

    /// Check if ECHIDNA Core is healthy (stub for now)
    pub fn healthCheck(self: *Self) bool {
        _ = self;
        // TODO: Implement HTTP health check when std.http stabilizes
        return false;
    }
};

// =============================================================================
// C FFI exports
// =============================================================================

var global_allocator: mem.Allocator = std.heap.c_allocator;
var global_client: ?*ProverClient = null;

/// Initialize the prover client
export fn prover_init(endpoint: [*:0]const u8) bool {
    const endpoint_slice = mem.span(endpoint);
    const client = global_allocator.create(ProverClient) catch return false;
    client.* = ProverClient.init(global_allocator, endpoint_slice);
    global_client = client;
    return true;
}

/// Shutdown the prover client
export fn prover_shutdown() void {
    if (global_client) |client| {
        global_allocator.destroy(client);
        global_client = null;
    }
}

/// Verify a proof
export fn prover_verify(
    prover_kind: u8,
    content: [*:0]const u8,
    content_len: usize,
) u8 {
    const client = global_client orelse return @intFromEnum(ProofStatus.unknown);
    const prover = @as(ProverKind, @enumFromInt(prover_kind));
    const content_slice = content[0..content_len];

    const result = client.verifyProof(prover, content_slice, null) catch {
        return @intFromEnum(ProofStatus.err);
    };
    defer {
        var r = result;
        r.deinit(global_allocator);
    }

    return @intFromEnum(result.status);
}

/// Check health of ECHIDNA Core
export fn prover_health_check() bool {
    const client = global_client orelse return false;
    return client.healthCheck();
}

/// Get prover tier
export fn prover_tier(prover_kind: u8) u8 {
    const prover = @as(ProverKind, @enumFromInt(prover_kind));
    return prover.tier();
}

/// Get number of supported provers
export fn prover_count() u8 {
    return ProverKind.count();
}

// =============================================================================
// Tests
// =============================================================================

test "ProverKind.fromExtension" {
    try std.testing.expectEqual(ProverKind.coq, ProverKind.fromExtension(".v").?);
    try std.testing.expectEqual(ProverKind.lean, ProverKind.fromExtension(".lean").?);
    try std.testing.expectEqual(ProverKind.z3, ProverKind.fromExtension(".smt2").?);
    try std.testing.expect(ProverKind.fromExtension(".xyz") == null);
}

test "ProverKind.tier" {
    try std.testing.expectEqual(@as(u8, 1), ProverKind.z3.tier());
    try std.testing.expectEqual(@as(u8, 2), ProverKind.metamath.tier());
    try std.testing.expectEqual(@as(u8, 3), ProverKind.pvs.tier());
}

test "ProofStatus.fromString" {
    try std.testing.expectEqual(ProofStatus.verified, ProofStatus.fromString("VERIFIED"));
    try std.testing.expectEqual(ProofStatus.failed, ProofStatus.fromString("FAILED"));
    try std.testing.expectEqual(ProofStatus.unknown, ProofStatus.fromString("INVALID"));
}
