// Freestanding calculator engine.
// No OS dependencies — pure math on []const u8 and f64.
const std = @import("std");
const math = std.math;

// ---------------------------------------------------------------------------
// Token — the lexical building blocks the calculator recognizes.
// ---------------------------------------------------------------------------

/// A single token produced by the lexer. Each variant represents a kind of
/// lexical unit: a number literal, an operator, a parenthesis, a function
/// name, or the end of input.
pub const Token = union(enum) {
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

    /// Supported scientific function names. The lexer maps alphabetic
    /// identifiers to one of these variants via `std.meta.stringToEnum`.
    pub const Func = enum {
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

// ---------------------------------------------------------------------------
// Lexer — turns the raw input string into a stream of Tokens.
// ---------------------------------------------------------------------------

/// Tokenizer. Scans characters left-to-right and produces one Token per call
/// to `next()`. The parser calls `next()` whenever it needs the next token.
pub const Lexer = struct {
    input: []const u8,
    pos: usize,

    pub fn init(input: []const u8) Lexer {
        return .{ .input = input, .pos = 0 };
    }

    /// Advance `pos` past any space characters.
    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.input.len and self.input[self.pos] == ' ') {
            self.pos += 1;
        }
    }

    /// Read and return the next token, or `.end` if the input is exhausted.
    pub fn next(self: *Lexer) !Token {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return .end;

        const c = self.input[self.pos];
        switch (c) {
            '0'...'9', '.' => return self.readNumber(),
            '+' => {
                self.pos += 1;
                return .plus;
            },
            '-' => {
                self.pos += 1;
                return .minus;
            },
            '*' => {
                self.pos += 1;
                return .star;
            },
            '/' => {
                self.pos += 1;
                return .slash;
            },
            '%' => {
                self.pos += 1;
                return .percent;
            },
            '^' => {
                self.pos += 1;
                return .caret;
            },
            '(' => {
                self.pos += 1;
                return .lparen;
            },
            ')' => {
                self.pos += 1;
                return .rparen;
            },
            'a'...'z', 'A'...'Z' => return self.readIdent(),
            else => return error.UnexpectedCharacter,
        }
    }

    /// Parse a numeric literal: one or more digits with an optional single
    /// decimal point (e.g. "3", "3.14", ".5").
    fn readNumber(self: *Lexer) !Token {
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
        const val = std.fmt.parseFloat(f64, self.input[start..self.pos]) catch return error.UnexpectedCharacter;
        return .{ .num = val };
    }

    /// Parse an alphabetic identifier and map it to a known function name.
    fn readIdent(self: *Lexer) !Token {
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
        const func = std.meta.stringToEnum(Token.Func, name) orelse return error.UnexpectedCharacter;
        return .{ .func = func };
    }
};

// ---------------------------------------------------------------------------
// CalcError — explicit error set for the calculator pipeline.
// ---------------------------------------------------------------------------

/// All possible errors that can occur during lexing, parsing, or evaluation.
pub const CalcError = error{
    UnexpectedCharacter,
    UnexpectedToken,
    UnexpectedEnd,
    DivisionByZero,
    InvalidArgument,
};

// ---------------------------------------------------------------------------
// Parser — recursive descent parser that evaluates expressions on the fly.
// ---------------------------------------------------------------------------
//
// Grammar (precedence low → high):
//   expr   → term (('+' | '-') term)*
//   term   → power (('*' | '/' | '%') power)*
//   power  → unary ('^' power)?              // right-associative
//   unary  → ('-' | '+') unary | primary
//   primary → NUMBER | '(' expr ')' | FUNC '(' expr ')'

/// Recursive descent parser. Consumes tokens from the lexer and evaluates
/// the expression directly (no AST is built).
pub const Parser = struct {
    lexer: Lexer,
    current: Token,

    pub fn init(input: []const u8) Parser {
        const l = Lexer.init(input);
        return .{ .lexer = l, .current = .end };
    }

    /// Consume the next token from the lexer and store it in `current`.
    fn advance(self: *Parser) CalcError!void {
        self.current = try self.lexer.next();
    }

    /// Top-level entry: expect exactly one expression followed by end-of-input.
    pub fn parse(self: *Parser) CalcError!f64 {
        try self.advance();
        const result = try self.expr();
        if (self.current != .end) return error.UnexpectedToken;
        return result;
    }

    /// Handle addition and subtraction (lowest precedence, left-associative).
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

    /// Handle multiplication, division, and modulo (mid precedence,
    /// left-associative). Guards against division by zero.
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

    /// Handle exponentiation (high precedence, right-associative via
    /// recursion so that `2^2^3` == `2^(2^3)` == 256).
    fn power(self: *Parser) CalcError!f64 {
        const base = try self.unary();
        if (self.current == .caret) {
            try self.advance();
            const exp = try self.power();
            return math.pow(f64, base, exp);
        }
        return base;
    }

    /// Handle unary minus and plus (higher precedence than power).
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

    /// Parse the highest-precedence atoms: number literals, parenthesized
    /// sub-expressions, and function calls like `sin(3.14)`.
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

    /// Evaluate a named function with a single numeric argument.
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
