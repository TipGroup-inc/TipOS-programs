// Freestanding ELF64 calculator entry point.
// Reads expression from input_buf, writes result to output_buf.
const core = @import("calc_core");

// ---------------------------------------------------------------------------
// Buffers — placed in .bss by the linker. Addresses visible in ELF symbols.
// ---------------------------------------------------------------------------

/// Input buffer: caller writes a null-terminated expression string here.
pub var input_buf: [4096]u8 = undefined;

/// Output buffer: calculator writes a null-terminated result (or error name) here.
pub var output_buf: [256]u8 = undefined;

// ---------------------------------------------------------------------------
// Freestanding entry point.
// ---------------------------------------------------------------------------

/// Export _start as the ELF entry point. The compiler handles stack setup.
export fn _start() noreturn {
    calc_main();
    // Should never return, but halt to be safe.
    while (true) {
        asm volatile ("cli\nhlt");
    }
}

/// Actual entry logic (called with a working stack).
fn calc_main() void {
    const expr = readCString(&input_buf);

    var parser = core.Parser.init(expr);
    const result = parser.parse() catch |err| {
        writeErr(err);
        return;
    };

    f64ToStr(result, &output_buf);
}

// ---------------------------------------------------------------------------
// Helpers — no OS, no std lib beyond math.
// ---------------------------------------------------------------------------

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

/// Convert an f64 to a decimal string and write it to `buf` (null-terminated).
/// Returns the number of characters written (excluding the null terminator).
fn f64ToStr(val: f64, buf: []u8) void {
    if (val != val) { // NaN
        writeStr("NaN", buf);
        return;
    }

    var pos: usize = 0;

    // Handle negative.
    if (val < 0) {
        buf[pos] = '-';
        pos += 1;
        f64ToStr(-val, buf[pos..]);
        // Find the end of what was written and ensure null termination.
        while (pos < buf.len and buf[pos] != 0) : (pos += 1) {}
        return;
    }

    // Handle infinity.
    if (val == inf()) {
        writeStr("inf", buf);
        return;
    }

    // Split into integer and fractional parts.
    const int_part: u64 = @intFromFloat(val);
    const frac = val - @as(f64, @floatFromInt(int_part));

    // Write integer part.
    pos += writeU64(int_part, buf[pos..]);

    // Write fractional part if non-zero.
    if (frac > 0.0 and frac < 1.0) {
        buf[pos] = '.';
        pos += 1;

        // 9 decimal digits of precision.
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

    // Null terminate.
    if (pos < buf.len) {
        buf[pos] = 0;
    }
}

/// Write a u64 as decimal digits into `buf`. Returns number of chars written.
fn writeU64(val: u64, buf: []u8) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }

    // Write digits in reverse, then flip.
    var v = val;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        buf[len] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }

    // Reverse in place.
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

/// Return positive infinity.
fn inf() f64 {
    return 1.0 / 0.0;
}
