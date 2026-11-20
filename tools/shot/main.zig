//! shot: a headless browser driven through a shot list (steps.zig), one
//! browser for the whole list, so a picture can show what a click or a key
//! opens. tools/screenshot.shale writes the list and runs this.
//!
//!   zig build run -- <chrome> <profile folder> <shot list> <out folder>
//!
//! Each `shot` step writes <out folder>/<name>.png and prints `shot <name>
//! <ms>`; any step that fails stops the run, naming its line, and the
//! browser goes with it. The protocol is cdp.zig's.
const std = @import("std");
const Io = std.Io;
const cdp = @import("cdp.zig");
const steps = @import("steps.zig");

/// How long `wait` and a page's load may take.
const wait_ms: i64 = 5000;
const load_ms: i32 = 15_000;

var browser_pid: ?std.os.linux.pid_t = null;

fn fail(line: usize, comptime fmt: []const u8, args: anytype) noreturn {
    cdp.say("shot: line {d}: ", .{line});
    cdp.say(fmt ++ "\n", args);
    if (browser_pid) |pid| cdp.kill(pid);
    std.os.linux.exit_group(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 5) fail(0, "usage: shot <chrome> <profile folder> <shot list> <out folder>", .{});
    const cwd = Io.Dir.cwd();
    const list = try cwd.readFileAlloc(io, args[3], a, .limited(1024 * 1024));
    var bad: usize = 0;
    const plan = steps.parse(a, list, &bad) catch |e| fail(bad, "{t}", .{e});

    // The sandbox needs user namespaces, which the box refuses (the
    // script's header); one renderer, its heap capped.
    const argv = [_][]const u8{
        args[1],
        "--headless",
        "--no-sandbox",
        "--disable-gpu",
        "--disable-extensions",
        "--disable-background-networking",
        "--disable-component-update",
        "--no-first-run",
        "--mute-audio",
        "--renderer-process-limit=1",
        "--js-flags=--max-old-space-size=128",
        try std.fmt.allocPrint(a, "--user-data-dir={s}", .{args[2]}),
        "--hide-scrollbars",
        "--remote-debugging-pipe",
        "about:blank",
    };
    var b = try cdp.launch(gpa, a, &argv, try environment(a, init.environ_map));
    browser_pid = b.pid;
    b.attach() catch |e| fail(0, "no page to drive: {t}", .{e});
    call(&b, 0, "Page.enable", .{});

    var base: []const u8 = "";
    // When the last picture was saved: each `shot` line says how long its
    // steps took since then, its page's load included.
    var since = cdp.nowMs();
    for (plan) |step| {
        const started = cdp.nowMs();
        switch (step.verb) {
            .base => base = step.arg,
            .size => {
                var it = std.mem.tokenizeScalar(u8, step.arg, ' ');
                const w = std.fmt.parseInt(u32, it.next() orelse "", 10) catch fail(step.line, "size takes a width and a height", .{});
                const h = std.fmt.parseInt(u32, it.next() orelse "", 10) catch fail(step.line, "size takes a width and a height", .{});
                call(&b, step.line, "Emulation.setDeviceMetricsOverride", .{ .width = w, .height = h, .deviceScaleFactor = 1, .mobile = false });
            },
            .cookie => {
                const eq = std.mem.indexOfScalar(u8, step.arg, '=') orelse fail(step.line, "cookie takes NAME=VALUE", .{});
                var set = b.call("Network.setCookie", .{
                    .name = step.arg[0..eq],
                    .value = step.arg[eq + 1 ..],
                    .url = base,
                    .path = "/",
                    .secure = true,
                    .httpOnly = true,
                    .sameSite = "Lax",
                }) catch |e| fail(step.line, "Network.setCookie: {t}", .{e});
                defer set.deinit();
                if (set.value.object.get("result").?.object.get("success")) |ok| {
                    if (ok == .bool and !ok.bool) fail(step.line, "the browser refused the cookie for {s}", .{base});
                }
            },
            .goto => {
                const url = try std.fmt.allocPrint(a, "{s}{s}", .{ base, step.arg });
                const seen = b.loads;
                call(&b, step.line, "Page.navigate", .{ .url = url });
                b.awaitLoad(seen, load_ms) catch |e| fail(step.line, "{s} did not load: {t}", .{ url, e });
            },
            .click => {
                const at = try evaluate(&b, a, step.line, try std.fmt.allocPrint(a,
                    \\(function () {{ var e = document.querySelector({f}); if (!e) return null;
                    \\  e.scrollIntoView({{block: 'nearest'}}); var r = e.getBoundingClientRect();
                    \\  return [r.left + r.width / 2, r.top + r.height / 2]; }})()
                , .{std.json.fmt(step.arg, .{})}));
                if (at != .array) fail(step.line, "nothing matches {s}", .{step.arg});
                const x = number(at.array.items[0]);
                const y = number(at.array.items[1]);
                call(&b, step.line, "Input.dispatchMouseEvent", .{ .type = "mouseMoved", .x = x, .y = y });
                call(&b, step.line, "Input.dispatchMouseEvent", .{ .type = "mousePressed", .x = x, .y = y, .button = "left", .clickCount = 1 });
                call(&b, step.line, "Input.dispatchMouseEvent", .{ .type = "mouseReleased", .x = x, .y = y, .button = "left", .clickCount = 1 });
            },
            .key => {
                if (steps.namedKey(step.arg)) |k| {
                    call(&b, step.line, "Input.dispatchKeyEvent", .{ .type = "rawKeyDown", .key = k.name, .code = k.name, .windowsVirtualKeyCode = k.vk });
                    call(&b, step.line, "Input.dispatchKeyEvent", .{ .type = "keyUp", .key = k.name, .code = k.name, .windowsVirtualKeyCode = k.vk });
                } else if ((std.unicode.utf8CountCodepoints(step.arg) catch 0) == 1) {
                    call(&b, step.line, "Input.dispatchKeyEvent", .{ .type = "keyDown", .key = step.arg, .text = step.arg });
                    call(&b, step.line, "Input.dispatchKeyEvent", .{ .type = "keyUp", .key = step.arg });
                } else fail(step.line, "no key is named {s}", .{step.arg});
            },
            .type => call(&b, step.line, "Input.insertText", .{ .text = step.arg }),
            .wait => {
                const probe = try std.fmt.allocPrint(a, "!!document.querySelector({f})", .{std.json.fmt(step.arg, .{})});
                while (true) {
                    const found = try evaluate(&b, a, step.line, probe);
                    if (found == .bool and found.bool) break;
                    if (cdp.nowMs() - started > wait_ms) fail(step.line, "nothing matched {s} in {d} ms", .{ step.arg, wait_ms });
                    cdp.sleepMs(50);
                }
            },
            .eval => _ = try evaluate(&b, a, step.line, step.arg),
            .shot => {
                // Two frames and the fonts first, so what was just opened is drawn.
                _ = try evaluate(&b, a, step.line,
                    \\document.fonts.ready.then(function () { return new Promise(function (done) {
                    \\  requestAnimationFrame(function () { requestAnimationFrame(function () { done(true); }); }); }); })
                );
                var pic = b.call("Page.captureScreenshot", .{ .format = "png" }) catch |e| fail(step.line, "Page.captureScreenshot: {t}", .{e});
                defer pic.deinit();
                const data = pic.value.object.get("result").?.object.get("data").?.string;
                const decoder = std.base64.standard.Decoder;
                const png = try gpa.alloc(u8, try decoder.calcSizeForSlice(data));
                defer gpa.free(png);
                try decoder.decode(png, data);
                const path = try std.fmt.allocPrint(a, "{s}/{s}.png", .{ args[4], step.arg });
                try cwd.writeFile(io, .{ .sub_path = path, .data = png });
                cdp.say("shot {s} {d} ms\n", .{ step.arg, cdp.nowMs() - since });
                since = cdp.nowMs();
            },
        }
    }
    b.close();
    browser_pid = null;
}

/// A command whose answer is only its having worked.
fn call(b: *cdp.Browser, line: usize, method: []const u8, params: anytype) void {
    var answer = b.call(method, params) catch |e| fail(line, "{s}: {t}", .{ method, e });
    answer.deinit();
}

/// `script` run in the page, a promise awaited: its value, copied into `a`.
/// A script that throws stops the run with the exception's words.
fn evaluate(b: *cdp.Browser, a: std.mem.Allocator, line: usize, script: []const u8) !std.json.Value {
    var answer = b.call("Runtime.evaluate", .{ .expression = script, .returnByValue = true, .awaitPromise = true }) catch |e|
        fail(line, "Runtime.evaluate: {t}", .{e});
    defer answer.deinit();
    const result = answer.value.object.get("result").?.object;
    if (result.get("exceptionDetails")) |ex| fail(line, "the page threw: {f}", .{std.json.fmt(ex, .{})});
    const value = result.get("result").?.object.get("value") orelse return .null;
    // The answer is freed on return; a copy through JSON's text keeps the value.
    const text = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(value, .{})});
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
}

fn number(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

/// This program's environment, as execve takes it.
fn environment(a: std.mem.Allocator, map: *std.process.Environ.Map) ![*:null]const ?[*:0]const u8 {
    const keys = map.keys();
    const values = map.values();
    const env = try a.allocSentinel(?[*:0]const u8, keys.len, null);
    for (keys, values, 0..) |k, v, i| env[i] = try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ k, v }, 0);
    return env;
}

test {
    _ = steps;
}
