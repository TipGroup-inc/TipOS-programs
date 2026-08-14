// Calculadora científica para TipOS
// Freestanding ELF64, sem libc, syscalls via int $0x80
// Build: zig build-exe calc.zig -target x86_64-freestanding -fno-red-zone -O ReleaseSmall -femit-bin=build/calc

// ===========================================================================
// Constantes
// ===========================================================================

const PI: f64 = 3.14159265358979323846;
const HALF_PI: f64 = PI / 2.0;
const TWO_PI: f64 = 2.0 * PI;
const LN2: f64 = 0.69314718055994530942;

// ===========================================================================
// Syscalls — TipOS int $0x80
// rax=nº, rdi=a1, rsi=a2, rdx=a3, retorno em rax
// ===========================================================================

fn sys_write(fd: usize, buf: [*]const u8, count: usize) usize {
    var ret: usize = undefined;
    asm volatile ("int $0x80"
        : [ret] "={rax}" (ret),
        : [num] "{rax}" (@as(usize, 4)),
          [fd] "{rdi}" (fd),
          [buf] "{rsi}" (@intFromPtr(buf)),
          [count] "{rdx}" (count),
        : "rcx", "r11", "memory"
    );
    return ret;
}

fn sys_read(fd: usize, buf: [*]u8, count: usize) usize {
    var ret: usize = undefined;
    asm volatile ("int $0x80"
        : [ret] "={rax}" (ret),
        : [num] "{rax}" (@as(usize, 3)),
          [fd] "{rdi}" (fd),
          [buf] "{rsi}" (@intFromPtr(buf)),
          [count] "{rdx}" (count),
        : "rcx", "r11", "memory"
    );
    return ret;
}

fn sys_exit(code: usize) noreturn {
    asm volatile ("int $0x80"
        :
        : [num] "{rax}" (@as(usize, 1)),
          [code] "{rdi}" (code),
        : "rcx", "r11"
    );
    unreachable;
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
// Parser — precedência: expr → term → power → unary → primary
// ===========================================================================

const CalcError = error{
    UnexpectedCharacter,
    UnexpectedToken,
    DivisionByZero,
    InvalidArgument,
};

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
            left = switch (op) {
                .star => left * right,
                .slash => if (right == 0.0) return error.DivisionByZero else left / right,
                .percent => if (right == 0.0) return error.DivisionByZero else @rem(left, right),
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
            return math_pow(base, exp);
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
            .sin => math_sin(arg),
            .cos => math_cos(arg),
            .tan => math_tan(arg),
            .asin => blk: {
                if (arg < -1.0 or arg > 1.0) return error.InvalidArgument;
                break :blk math_asin(arg);
            },
            .acos => blk: {
                if (arg < -1.0 or arg > 1.0) return error.InvalidArgument;
                break :blk math_acos(arg);
            },
            .atan => math_atan(arg),
            .log => blk: {
                if (arg <= 0.0) return error.InvalidArgument;
                break :blk math_log(arg);
            },
            .ln => blk: {
                if (arg <= 0.0) return error.InvalidArgument;
                break :blk math_ln(arg);
            },
            .sqrt => blk: {
                if (arg < 0.0) return error.InvalidArgument;
                break :blk math_sqrt(arg);
            },
            .abs => if (arg < 0.0) -arg else arg,
        };
    }
};

// ===========================================================================
// Funções matemáticas — tudo do zero, sem std
// ===========================================================================

// --- Range reduction para trig ---

fn reduceAngle(x: f64) f64 {
    var a = x;
    // Reduz para [-2π, 2π]
    a = a - @as(f64, @floatFromInt(@as(i64, @intFromFloat(a / TWO_PI)))) * TWO_PI;
    // Reduz para [-π, π]
    if (a > PI) a -= TWO_PI;
    if (a < -PI) a += TWO_PI;
    return a;
}

// --- sin/cos via Taylor series ---
// sin(x) = x - x³/3! + x⁵/5! - x⁷/7! + ... (|x| ≤ π/2, 13 termos ≈ 15 dígitos)

fn math_sin(x: f64) f64 {
    var a = reduceAngle(x);
    // Reduz para [-π/2, π/2]
    var sign: f64 = 1.0;
    if (a > HALF_PI) {
        a = PI - a;
    } else if (a < -HALF_PI) {
        a = -PI - a;
        sign = -1.0;
    }

    const x2 = a * a;
    var term = a;
    var sum = a;
    term *= -x2 / (2.0 * 3.0); sum += term;
    term *= -x2 / (4.0 * 5.0); sum += term;
    term *= -x2 / (6.0 * 7.0); sum += term;
    term *= -x2 / (8.0 * 9.0); sum += term;
    term *= -x2 / (10.0 * 11.0); sum += term;
    term *= -x2 / (12.0 * 13.0); sum += term;
    term *= -x2 / (14.0 * 15.0); sum += term;
    term *= -x2 / (16.0 * 17.0); sum += term;
    term *= -x2 / (18.0 * 19.0); sum += term;
    term *= -x2 / (20.0 * 21.0); sum += term;
    term *= -x2 / (22.0 * 23.0); sum += term;
    term *= -x2 / (24.0 * 25.0); sum += term;

    return sign * sum;
}

// cos(x) = 1 - x²/2! + x⁴/4! - x⁶/6! + ...

fn math_cos(x: f64) f64 {
    var a = reduceAngle(x);
    if (a > HALF_PI) a = PI - a;
    if (a < -HALF_PI) a = -PI - a;

    const x2 = a * a;
    var term: f64 = 1.0;
    var sum: f64 = 1.0;
    term *= -x2 / (1.0 * 2.0); sum += term;
    term *= -x2 / (3.0 * 4.0); sum += term;
    term *= -x2 / (5.0 * 6.0); sum += term;
    term *= -x2 / (7.0 * 8.0); sum += term;
    term *= -x2 / (9.0 * 10.0); sum += term;
    term *= -x2 / (11.0 * 12.0); sum += term;
    term *= -x2 / (13.0 * 14.0); sum += term;
    term *= -x2 / (15.0 * 16.0); sum += term;
    term *= -x2 / (17.0 * 18.0); sum += term;
    term *= -x2 / (19.0 * 20.0); sum += term;
    term *= -x2 / (21.0 * 22.0); sum += term;
    term *= -x2 / (23.0 * 24.0); sum += term;
    term *= -x2 / (25.0 * 26.0); sum += term;

    return sum;
}

fn math_tan(x: f64) f64 {
    return math_sin(x) / math_cos(x);
}

// --- atan via polinômio racional (Ganssle) ---
// atan(x) para |x| ≤ tan(π/12), ~14 dígitos de precisão

const TAN_PI_12: f64 = 0.267949192431123;

fn atan_small(x: f64) f64 {
    const x2 = x * x;
    const num = x * (0.995385998084412 + x2 * (0.2839464530 + x2 * (-0.0261653264)));
    const den = 1.0 + x2 * (0.5891309564 + x2 * (0.0855315310 + x2 * 0.0038385860));
    return (num / den) * HALF_PI;
}

fn math_atan(x: f64) f64 {
    var val = x;
    var sign: f64 = 1.0;
    if (val < 0.0) {
        val = -val;
        sign = -1.0;
    }

    var inverse = false;
    if (val > TAN_PI_12) {
        val = 1.0 / val;
        inverse = true;
    }

    var result = atan_small(val);

    if (inverse) {
        result = HALF_PI - result;
    }

    return sign * result;
}

fn math_asin(x: f64) f64 {
    return math_atan(x / math_sqrt(1.0 - x * x));
}

fn math_acos(x: f64) f64 {
    return HALF_PI - math_asin(x);
}

// --- ln via decomposição IEEE 754 + polinômio minimax ---
// Decompoem x = m * 2^e, onde 0.5 ≤ m < 1.0, approxima ln(m)

fn math_ln(x: f64) f64 {
    // Decomposição: x = m * 2^e
    const bits = @as(u64, @bitCast(x));
    const e_int = @as(i64, @intCast((bits >> 52) & 0x7FF)) - 1023;

    // Força m para [0.5, 1.0)
    const m_bits = (bits & 0x000FFFFFFFFFFFFF) | 0x3FE0000000000000;
    const m = @as(f64, @bitCast(m_bits));

    // Aproximação polinomial para ln(m)
    const p = -0.1278333324573208 +
        m * (1.467958585802343 +
        m * (-0.739625285297586 +
        m * 0.237648857009516));

    // Ajuste para m próximo de 1.0 (log1p)
    const u = m - 1.0;
    const ln_m = if (u < 1e-4) blk: {
        const u_sq = u * u;
        break :blk u * (1.0 - 0.5 * u + u_sq / 3.0);
    } else p;

    return ln_m + @as(f64, @floatFromInt(e_int)) * LN2;
}

fn math_log(x: f64) f64 {
    // log base 10 = ln(x) / ln(10)
    return math_ln(x) / 2.30258509299404568402;
}

// --- exp via Taylor series + range reduction ---

fn math_exp(x: f64) f64 {
    if (x < 0.0) return 1.0 / math_exp(-x);

    var xr = x;
    var n: i64 = 0;
    while (xr > 1.0) : (n += 1) {
        xr *= 0.5;
    }

    // Taylor para e^z, z pequeno
    var sum: f64 = 1.0;
    var term: f64 = 1.0;
    var i: i64 = 1;
    while (i < 20) : (i += 1) {
        term *= xr / @as(f64, @floatFromInt(i));
        sum += term;
    }

    // Refaz a redução: eleva ao quadrado n vezes
    var result = sum;
    var j: i64 = 0;
    while (j < n) : (j += 1) {
        result *= result;
    }
    return result;
}

// --- pow via exp(y * ln(x)) com fast path para inteiros ---

fn math_pow(base: f64, exp: f64) f64 {
    if (exp == 0.0) return 1.0;
    if (base == 0.0) return 0.0;
    if (exp == 1.0) return base;
    if (base == 1.0) return 1.0;

    // Fast path: expoente inteiro positivo
    const exp_i = @as(i64, @intFromFloat(exp));
    if (@as(f64, @floatFromInt(exp_i)) == exp and exp > 0.0) {
        var result: f64 = 1.0;
        var b = base;
        var n = exp_i;
        while (n > 0) : (n >>= 1) {
            if (n & 1 != 0) result *= b;
            b *= b;
        }
        return result;
    }

    // Geral: e^(y * ln(x))
    return math_exp(exp * math_ln(base));
}

// --- sqrt via Newton-Raphson ---

fn math_sqrt(x: f64) f64 {
    if (x < 0.0) return 0.0 / 0.0;
    if (x == 0.0) return 0.0;

    // Guess inicial via bit manipulation IEEE 754
    const ix = @as(u64, @bitCast(x));
    const bx = 0x5FE6EB50C7B537A9 +% (ix >> 1);
    var guess = @as(f64, @bitCast(bx));

    // 8 iterações Newton-Raphson (suficiente para f64)
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        guess = 0.5 * (guess + x / guess);
    }
    return guess;
}

// ===========================================================================
// Helpers — parsing e formatação sem std
// ===========================================================================

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

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn strLen(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and s[i] != 0) : (i += 1) {}
    return i;
}

fn writeStr(src: []const u8, buf: []u8) void {
    var i: usize = 0;
    while (i < src.len and i < buf.len - 1) : (i += 1) {
        buf[i] = src[i];
    }
    buf[i] = 0;
}

fn writeErr(err: anyerror, buf: []u8) void {
    const name = @errorName(err);
    var i: usize = 0;
    while (i < name.len and i < buf.len - 1) : (i += 1) {
        buf[i] = name[i];
    }
    buf[i] = 0;
}

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

    if (math_is_inf(val)) {
        writeStr("inf", buf);
        return;
    }

    const int_part: u64 = @intFromFloat(val);
    const frac = val - @as(f64, @floatFromInt(int_part));

    pos += writeU64(int_part, buf[pos..]);

    if (frac > 0.000000001 and frac < 1.0) {
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

fn math_is_inf(x: f64) bool {
    return x != 0.0 and x == x and (x * 2.0 == x);
}

// ===========================================================================
// Main — loop REPL interativo
// ===========================================================================

fn main() void {
    while (true) {
        _ = sys_write(1, "calc> ", 6);

        var buf: [256]u8 = undefined;
        const n = sys_read(0, &buf, 255);

        // Linha vazia ou só \n
        if (n <= 1) continue;

        // Remove \n
        const len = n - 1;
        buf[len] = 0;

        // "exit" ou "quit" sai
        if (len == 4 and strEql(buf[0..4], "exit")) sys_exit(0);
        if (len == 4 and strEql(buf[0..4], "quit")) sys_exit(0);

        // Parse e avalia
        var parser = Parser.init(buf[0..len]);
        const result = parser.parse() catch |err| {
            var err_buf: [64]u8 = undefined;
            writeErr(err, &err_buf);
            _ = sys_write(1, "Error: ", 7);
            _ = sys_write(1, &err_buf, strLen(&err_buf));
            _ = sys_write(1, "\n", 1);
            continue;
        };

        // Formata e imprime resultado
        var out: [64]u8 = undefined;
        f64ToStr(result, &out);
        _ = sys_write(1, &out, strLen(&out));
        _ = sys_write(1, "\n", 1);
    }
}

// ===========================================================================
// Entry point
// ===========================================================================

export fn _start() callconv(.C) noreturn {
    main();
    sys_exit(0);
}
