const std = @import("std");
const arbor = @import("arbor");

const param = arbor.param;
const log = arbor.log;
const dsp = arbor.dsp;
const Plugin = arbor.Plugin;

const ArborExample = @This();

const allocator = std.heap.c_allocator;

const Mode = enum {
    Vintage,
    Modern,
    Apocalypse,
};

const plugin_params = &[_]arbor.Parameter{
    param.Float("Gain", 0, 30, 0, .{ .flags = .{}, .value_to_text = dbValToText }),
    param.Float("Out", -12, 12, 0, .{ .flags = .{}, .value_to_text = dbValToText }),
    param.Float("Freq", 20, 18e3, 1500, .{ .flags = .{}, .value_to_text = hzValToText }),
    param.Choice("Mode", Mode.Vintage, .{ .flags = .{} }), // Optionally pass a list of names.
};

filter: dsp.Filter,
last_cutoff: f32,

export fn init() *Plugin {
    const self = allocator.create(ArborExample) catch |e| {
        log.fatal("{!}\n", .{e}, @src());
    };
    self.* = .{
        .filter = dsp.Filter.init(
            allocator,
            2,
            .FirstOrderLowpass,
            plugin_params[0].default_value,
            std.math.sqrt1_2,
        ) catch |e| log.fatal("{!}\n", .{e}, @src()),
        .last_cutoff = plugin_params[0].default_value,
    };
    const plugin = arbor.init(allocator, plugin_params, .{
        .deinit = deinit,
        .prepare = prepare,
        .process = process,
    });
    plugin.user = self;
    return plugin;
}

fn deinit(plugin: *Plugin) void {
    // _ = plugin;
    // If we set user data in init(), you would free it here.

    // Free your user data.
    const self = plugin.getUser(ArborExample);
    self.filter.deinit();
    allocator.destroy(self);
}

fn prepare(plugin: *Plugin, sample_rate: f32, max_frames: u32) void {
    plugin.sample_rate = sample_rate;
    plugin.max_frames = max_frames;
    const self = plugin.getUser(ArborExample);
    self.filter.setSampleRate(sample_rate);
}

fn process(plugin: *Plugin, buffer: arbor.AudioBuffer(f32)) void {

    // Distortion

    const in_gain_db = plugin.getParamValue(f32, "Gain");
    const out_gain_db = plugin.getParamValue(f32, "Out");
    const mode = plugin.getParamValue(Mode, "Mode");

    const in_gain = std.math.pow(f32, 10, in_gain_db * 0.05);
    const out_gain = std.math.pow(f32, 10, out_gain_db * 0.05);

    const intermediate = buffer.output;
    for (buffer.input, 0..) |ch, ch_idx| {
        var out = intermediate[ch_idx];
        for (ch, 0..) |sample, idx| {
            // For performance reasons, you wouldn't want to branch inside
            // this loop, but...example.
            switch (mode) {
                .Modern => {
                    var x = sample;
                    x *= in_gain;
                    x = @min(1, @max(-1, x)); // Clamp.
                    // Soft clip.
                    out[idx] = (5.0 / 4.0) * (x - (x * x * x * x * x) / 5) * out_gain;
                },
                .Vintage => {
                    var x = sample;
                    x *= in_gain;
                    // Asymmetric.
                    if (x < 0) {
                        x = @max(-1, x);
                        x = (3.0 / 2.0) * (x - (x * x * x) / 3.0);
                    } else x = (3.0 / 2.0) * std.math.tanh(x); // Asymptotes at 1.
                    x *= out_gain;
                    out[idx] = x;
                },
                .Apocalypse => {
                    var x = sample;
                    x *= in_gain * 2;
                    // Sine fold?
                    x -= @abs(@sin(x / std.math.two_sqrtpi));
                    x += @abs(@sin(x / std.math.pi));
                    x = 2 * @sin(x / std.math.tau);
                    x = @min(1, @max(-1, x));
                    x *= out_gain;
                    out[idx] = x;
                },
            }
        }
    }

    // Filter

    const self = plugin.getUser(ArborExample);
    const cutoff = plugin.getParamValue(f32, "Freq");
    if (self.last_cutoff != cutoff) {
        // TODO: Param smoothing.
        self.filter.setCutoff(cutoff, plugin.sample_rate);
        self.last_cutoff = cutoff;
    }

    self.filter.process(intermediate, buffer.output);
}

fn dbValToText(value: f32, buf: []u8) usize {
    const out = std.fmt.bufPrint(buf, "{d:.2} dB", .{value}) catch |e| {
        log.err("{!}\n", .{e}, @src());
        return 0;
    };
    return out.len;
}

fn hzValToText(value: f32, buf: []u8) usize {
    const out = std.fmt.bufPrint(buf, "{d:.0} Hz", .{value}) catch |e| {
        log.err("{!}\n", .{e}, @src());
        return 0;
    };
    return out.len;
}

// GUI

const draw = arbor.Gui.draw;

pub const WIDTH = 500;
pub const HEIGHT = 600;
const background_color = draw.Color{ .r = 38, .g = 104, .b = 211, .a = 0xff };

const slider_dark = draw.Color{ .r = 37, .g = 37, .b = 156, .a = 0xff };
const silver = draw.Color.fromBits(0xff_d3_a8_d3);

const highlight_color = draw.Color{ .r = 213, .g = 34, .b = 219, .a = 0xff };
const border_color = draw.Color{ .r = 44, .g = 217, .b = 89, .a = 0xff };

const TITLE = "MINDROT";

// Export an entry to our GUI implementation.
export fn gui_init(plugin: *arbor.Plugin) void {
    const gui = arbor.Gui.init(plugin.allocator, .{
        .layout = .default,
        .width = WIDTH,
        .height = HEIGHT,
        .timer_ms = 16,
        .interface = .{
            .deinit = gui_deinit,
            .render = gui_render,
        },
    });
    plugin.gui = gui;

    // We can draw the logo here and just copy its memory to the global canvas
    // in our render function.
    drawLogo();

    const slider_height = 200;
    const slider_gap = 50; // Gap on either side of slider.

    // Create pointers, assign IDs and values.
    // This is how the components get "attached" to parameters.
    // Setup unique properties here.
    for (0..plugin.param_info.len) |i| {
        const param_info = plugin.getParamWithId(@intCast(i)) catch |e| {
            log.err("{!}\n", .{e}, @src());
            return;
        };
        if (!std.mem.eql(u8, param_info.name, "Mode")) {
            const width = (WIDTH / 3) - (slider_gap * 2);
            gui.addComponent(.{
                // Given the gui.allocator, the memory will be cleaned up
                // on global GUI deinit. Otherwise, deallocate manually.
                .sub_type = arbor.Gui.Slider.init(gui.allocator, param_info, silver),
                .interface = arbor.Gui.Slider.interface,
                .value = param_info.getNormalizedValue(plugin.params[i]),
                .bounds = .{
                    .x = @intCast(i * (WIDTH / 3) + slider_gap),
                    .y = (HEIGHT / 2) - (slider_height / 2),
                    .width = width,
                    .height = slider_height,
                },
                .background_color = slider_dark,
                .label = .{
                    .text = param_info.name,
                    .height = 18,
                    .color = draw.Color.BLACK,
                    .border = silver,
                    .flags = .{
                        .border = true,
                        .center_x = true,
                        .center_y = false,
                    },
                },
            });
        } else { // Mode menu.
            const menu_width = WIDTH / 2;
            const menu_height = HEIGHT / 8;
            const bot_pad = 50;
            gui.addComponent(.{
                .sub_type = arbor.Gui.Menu.init(gui.allocator, param_info.enum_choices orelse {
                    log.err("No enum choices available.\n", .{}, @src());
                    return;
                }, silver, 3, highlight_color),
                .interface = arbor.Gui.Menu.interface,
                .value = param_info.getNormalizedValue(plugin.params[i]), // Don't bother normalizing since we just care about the int.
                .bounds = .{
                    .x = (WIDTH - menu_width) - menu_width / 2,
                    .y = HEIGHT - menu_height - bot_pad,
                    .width = menu_width,
                    .height = menu_height,
                },
                .background_color = slider_dark,
                .label = .{
                    .text = param_info.name,
                    .height = menu_height / 2,
                    .color = draw.Color.WHITE,
                },
            });
        }
    }
}

fn gui_deinit(gui: *arbor.Gui) void {
    _ = gui;
}

fn gui_render(gui: *arbor.Gui) void {
    // Draw our background and frame.
    draw.olivec_fill(gui.canvas, background_color.toBits());
    draw.olivec_frame(gui.canvas, 2, 2, WIDTH - 4, HEIGHT - 4, 4, border_color.toBits());

    // Draw plugin title.
    const title_width = WIDTH / 3;
    draw.drawText(gui.canvas, .{
        .text = TITLE,
        .height = 25,
        .color = slider_dark,
        .background = silver,
        .flags = .{ .background = true },
    }, .{
        .x = (WIDTH / 2) - (title_width / 2),
        .y = 10,
        .width = title_width,
        .height = 50,
    });

    // Draw each component.
    for (gui.components.items) |*c| {
        c.interface.draw_proc(c, gui.canvas);
    }

    // Render logo.
    draw.olivec_sprite_blend(gui.canvas, 6, 6, 64, 64, logo_canvas);
}

var logo_pix: [32 * 32]u32 = undefined;
var logo_canvas: draw.Canvas = .{
    .pixels = @ptrCast(&logo_pix),
    .width = 32,
    .height = 32,
    .stride = 32,
};

fn drawLogo() void {
    const cx = 15;
    const cy = 15;
    draw.olivec_fill(logo_canvas, 0);
    draw.olivec_circle(logo_canvas, cx, cy, 16, silver.toBits());
    draw.olivec_line(logo_canvas, cx, 0, cx, 32, slider_dark.toBits());
}
