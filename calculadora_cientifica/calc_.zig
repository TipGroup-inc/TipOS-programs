// Freestanding ELF64 scientific calculator.
// Single file — no OS dependencies, no multi-file linking issues.
// Reads expression from input_buf, writes result to output_buf.
const math = @import("std").math;

const CalcError = error{
    UnexpectedCharacter,
    UnexpectedToken,
    UnexpectedEnd,
    DivisionByZero,
    InvalidArgument,
};

// ===========================================================================
// Buffers — placed in .bss by the linker.
// ===========================================================================

/// Input buffer: caller writes a null-terminated expression string here.
pub var input_buf: [4096]u8 = undefined;

/// Output buffer: calculator writes a null-terminated result (or error name).
pub var output_buf: [256]u8 = undefined;

// ===========================================================================
// Entry point.
// ===========================================================================

/// Freestanding _start. No CRT, no OS.
/// The compiler generates a stack frame automatically.
export fn _start() noreturn {
    // Reference calc_main from Zig code so the linker sees it.
    calc_main();
    while (true) {
        asm volatile ("cli\nhlt");
    }
}

/// Main logic — uses the existing stack set up by _start.
fn calc_main() void {
    const expr = readCString(&input_buf);

    var parser = Parser.init(expr);
    const result = parser.parse() catch |err| {
        writeErr(err);
        return;
    };

    f64ToStr(result, &output_buf);
}

// ===========================================================================
// Token
// ===========================================================================

const Token = union(enum) {
    num: f64,
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    lparen,
    rparen,
    func: Func,
    end,

    const Func = enum {
        sin,
        cos,
        tan,
        asin,
        acos,
        atan,
        log,
        ln,
        sqrt,
        abs,
    };
};

// ===========================================================================
// Lexer
// ===========================================================================

const Lexer = struct {
    input: []const u8,
    pos: usize,

    fn init(input: []const u8) Lexer {
        return .{ .input = input, .pos = 0 };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.input.len and self.input[self.pos] == ' ') {
            self.pos += 1;
        }
    }

    fn next(self: *Lexer) CalcError!Token {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return .end;

        const c = self.input[self.pos];
        switch (c) {
            '0'...'9', '.' => return self.readNumber(),
            '+' => { self.pos += 1; return .plus; },
            '-' => { self.pos += 1; return .minus; },
            '*' => { self.pos += 1; return .star; },
            '/' => { self.pos += 1; return .slash; },
            '%' => { self.pos += 1; return .percent; },
            '^' => { self.pos += 1; return .caret; },
            '(' => { self.pos += 1; return .lparen; },
            ')' => { self.pos += 1; return .rparen; },
            'a'...'z', 'A'...'Z' => return self.readIdent(),
            else => return error.UnexpectedCharacter,
        }
    }

    fn readNumber(self: *Lexer) CalcError!Token {
        const start = self.pos;
        var has_dot = false;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '.') {
                if (has_dot) break;
                has_dot = true;
                self.pos += 1;
            } else if (ch >= '0' and ch <= '9') {
                self.pos += 1;
            } else {
                break;
            }
        }
        const val = parseFloat(self.input[start..self.pos]) catch return error.UnexpectedCharacter;
        return .{ .num = val };
    }

    fn readIdent(self: *Lexer) CalcError!Token {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
                self.pos += 1;
            } else {
                break;
            }
        }
        const name = self.input[start..self.pos];
        const func = matchFunc(name) orelse return error.UnexpectedCharacter;
        return .{ .func = func };
    }
};

// ===========================================================================
// Parser
// ===========================================================================

const Parser = struct {
    lexer: Lexer,
    current: Token,

    fn init(input: []const u8) Parser {
        return .{ .lexer = Lexer.init(input), .current = .end };
    }

    fn advance(self: *Parser) CalcError!void {
        self.current = try self.lexer.next();
    }

    fn parse(self: *Parser) CalcError!f64 {
        try self.advance();
        const result = try self.expr();
        if (self.current != .end) return error.UnexpectedToken;
        return result;
    }

    fn expr(self: *Parser) CalcError!f64 {
        var left = try self.term();
        while (self.current == .plus or self.current == .minus) {
            const op = self.current;
            try self.advance();
            const right = try self.term();
            left = if (op == .plus) left + right else left - right;
        }
        return left;
    }

    fn term(self: *Parser) CalcError!f64 {
        var left = try self.power();
        while (self.current == .star or self.current == .slash or self.current == .percent) {
            const op = self.current;
            try self.advance();
            const right = try self.power();
            if (right == 0 and (op == .slash or op == .percent))
                return error.DivisionByZero;
            left = switch (op) {
                .star => left * right,
                .slash => left / right,
                .percent => @rem(left, right),
                else => unreachable,
            };
        }
        return left;
    }

    fn power(self: *Parser) CalcError!f64 {
        const base = try self.unary();
        if (self.current == .caret) {
            try self.advance();
            const exp = try self.power();
            return math.pow(f64, base, exp);
        }
        return base;
    }

    fn unary(self: *Parser) CalcError!f64 {
        if (self.current == .minus) {
            try self.advance();
            return -(try self.primary());
        }
        if (self.current == .plus) {
            try self.advance();
            return try self.primary();
        }
        return try self.primary();
    }

    fn primary(self: *Parser) CalcError!f64 {
        switch (self.current) {
            .num => |val| {
                try self.advance();
                return val;
            },
            .lparen => {
                try self.advance();
                const val = try self.expr();
                if (self.current != .rparen) return error.UnexpectedToken;
                try self.advance();
                return val;
            },
            .func => |f| {
                try self.advance();
                if (self.current != .lparen) return error.UnexpectedToken;
                try self.advance();
                const arg = try self.expr();
                if (self.current != .rparen) return error.UnexpectedToken;
                try self.advance();
                return evalFunc(f, arg);
            },
            else => return error.UnexpectedToken,
        }
    }

    fn evalFunc(f: Token.Func, arg: f64) CalcError!f64 {
        return switch (f) {
            .sin => math.sin(arg),
            .cos => math.cos(arg),
            .tan => math.tan(arg),
            .asin => blk: {
                if (arg < -1 or arg > 1) return error.InvalidArgument;
                break :blk math.asin(arg);
            },
            .acos => blk: {
                if (arg < -1 or arg > 1) return error.InvalidArgument;
                break :blk math.acos(arg);
            },
            .atan => math.atan(arg),
            .log => blk: {
                if (arg <= 0) return error.InvalidArgument;
                break :blk math.log10(arg);
            },
            .ln => blk: {
                if (arg <= 0) return error.InvalidArgument;
                break :blk @log(arg);
            },
            .sqrt => blk: {
                if (arg < 0) return error.InvalidArgument;
                break :blk math.sqrt(arg);
            },
            .abs => if (arg < 0) -arg else arg,
        };
    }
};

// ===========================================================================
// Freestanding helpers — no std.fmt, no std.meta.
// ===========================================================================

/// Freestanding float parser: "3.14" → 3.14
fn parseFloat(s: []const u8) !f64 {
    if (s.len == 0) return error.InvalidCharacter;

    var pos: usize = 0;
    var negative = false;

    if (s[0] == '-') { negative = true; pos = 1; }
    if (s[0] == '+') { pos = 1; }

    var int_part: f64 = 0;
    while (pos < s.len and s[pos] >= '0' and s[pos] <= '9') : (pos += 1) {
        int_part = int_part * 10.0 + @as(f64, @floatFromInt(s[pos] - '0'));
    }

    var frac_part: f64 = 0;
    if (pos < s.len and s[pos] == '.') {
        pos += 1;
        var denom: f64 = 10.0;
        while (pos < s.len and s[pos] >= '0' and s[pos] <= '9') : (pos += 1) {
            frac_part += @as(f64, @floatFromInt(s[pos] - '0')) / denom;
            denom *= 10.0;
        }
    }

    var result = int_part + frac_part;
    if (negative) result = -result;
    return result;
}

/// Map a function name string to Token.Func.
fn matchFunc(name: []const u8) ?Token.Func {
    const funcs = [_]struct { n: []const u8, f: Token.Func }{
        .{ .n = "sin", .f = .sin },
        .{ .n = "cos", .f = .cos },
        .{ .n = "tan", .f = .tan },
        .{ .n = "asin", .f = .asin },
        .{ .n = "acos", .f = .acos },
        .{ .n = "atan", .f = .atan },
        .{ .n = "log", .f = .log },
        .{ .n = "ln", .f = .ln },
        .{ .n = "sqrt", .f = .sqrt },
        .{ .n = "abs", .f = .abs },
    };
    for (funcs) |entry| {
        if (strEql(name, entry.n)) return entry.f;
    }
    return null;
}

/// Read a null-terminated string from a byte array.
fn readCString(buf: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buf.len and buf[len] != 0) : (len += 1) {}
    return buf[0..len];
}

/// Write the error name to output_buf as a null-terminated string.
fn writeErr(err: anyerror) void {
    const name = @errorName(err);
    var i: usize = 0;
    while (i < name.len and i < output_buf.len - 1) : (i += 1) {
        output_buf[i] = name[i];
    }
    output_buf[i] = 0;
}

/// Convert an f64 to a decimal string in `buf` (null-terminated).
fn f64ToStr(val: f64, buf: []u8) void {
    if (val != val) { // NaN
        writeStr("NaN", buf);
        return;
    }

    var pos: usize = 0;

    if (val < 0) {
        buf[0] = '-';
        pos = 1;
        f64ToStr(-val, buf[pos..]);
        while (pos < buf.len and buf[pos] != 0) : (pos += 1) {}
        return;
    }

    if (val == math.inf(f64)) {
        writeStr("inf", buf);
        return;
    }

    const int_part: u64 = @intFromFloat(val);
    const frac = val - @as(f64, @floatFromInt(int_part));

    pos += writeU64(int_part, buf[pos..]);

    if (frac > 0.0 and frac < 1.0) {
        buf[pos] = '.';
        pos += 1;
        var remaining = frac;
        var i: usize = 0;
        while (i < 9) : (i += 1) {
            remaining *= 10.0;
            const digit: u64 = @intFromFloat(remaining);
            buf[pos] = '0' + @as(u8, @intCast(digit));
            pos += 1;
            remaining -= @as(f64, @floatFromInt(digit));
            if (remaining < 1e-12) break;
        }
    }

    if (pos < buf.len) buf[pos] = 0;
}

/// Write a u64 as decimal digits. Returns number of chars written.
fn writeU64(val: u64, buf: []u8) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var v = val;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        buf[len] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    var i: usize = 0;
    while (i < len / 2) : (i += 1) {
        const tmp = buf[i];
        buf[i] = buf[len - 1 - i];
        buf[len - 1 - i] = tmp;
    }
    return len;
}

/// Copy a string literal into `buf` (null-terminated).
fn writeStr(src: []const u8, buf: []u8) void {
    var i: usize = 0;
    while (i < src.len and i < buf.len - 1) : (i += 1) {
        buf[i] = src[i];
    }
    buf[i] = 0;
}

/// Compare two string slices for equality.
fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}
