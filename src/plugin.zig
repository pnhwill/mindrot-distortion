// Based on https://github.com/ArborealAudio/arbor/tree/master/examples

const std = @import("std");
const arbor = @import("arbor");

const math = std.math;
const param = arbor.param;
const log = arbor.log;
const dsp = arbor.dsp;
const Plugin = arbor.Plugin;

const ArborExample = @This();

const allocator = std.heap.c_allocator;

const Mode = enum {
    Hard,
    Quintic,
    Cubic,
    Sine,
    Tanh,
    Sigmoid,
    Arctan,
    SineFold,
    Tan,
    TanFold,
    SinTan,
    TanSin,
    // Vintage,
    // Apocalypse,
};

const plugin_params = &[_]arbor.Parameter{
    param.Float("Gain", 0, 30, 0, .{ .flags = .{}, .value_to_text = dbValToText }),
    param.Float("Out", -12, 12, 0, .{ .flags = .{}, .value_to_text = dbValToText }),
    param.Float("Freq", 20, 18e3, 1500, .{ .flags = .{}, .value_to_text = hzValToText }),
    param.Choice("Top Mode", Mode.Hard, .{ .flags = .{} }), // Optionally pass a list of names.
    param.Choice("Bottom Mode", Mode.Hard, .{ .flags = .{} }), // Optionally pass a list of names.
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
            math.sqrt1_2,
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
    // const mode = plugin.getParamValue(Mode, "Top Mode");
    const top_mode = plugin.getParamValue(Mode, "Top Mode");
    const bottom_mode = plugin.getParamValue(Mode, "Bottom Mode");

    const in_gain = math.pow(f32, 10, in_gain_db * 0.05);
    const out_gain = math.pow(f32, 10, out_gain_db * 0.05);

    const intermediate = buffer.output;

    // For performance reasons, we shouldn't branch inside this loop. But oh well.
    for (buffer.input, 0..) |ch, ch_idx| {
        var out = intermediate[ch_idx];
        for (ch, 0..) |sample, idx| {
            if (sample >= 0) {
                out[idx] = distortSample(sample, in_gain, out_gain, top_mode);
            } else {
                out[idx] = distortSample(sample, in_gain, out_gain, bottom_mode);
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

fn distortSample(sample: f32, in_gain: f32, out_gain: f32, mode: Mode) f32 {
    var x = sample;
    x *= in_gain;
    switch (mode) {
        .Hard => {
            // Clamp.
            x = math.clamp(x, -1, 1);
        },
        .Quintic => {
            x = math.clamp(x, -1, 1);
            // Soft clip.
            x = (5.0 / 4.0) * (x - (x * x * x * x * x) / 5.0);
        },
        .Cubic => {
            x = math.clamp(x, -1, 1);
            x = (3.0 / 2.0) * (x - (x * x * x) / 3.0);
        },
        .Sine => {
            x = math.clamp(x, -1, 1);
            x = math.sin((math.pi / 2.0) * x);
        },
        .Sigmoid => {
            x = math.clamp(x, -1, 1);
            x = (2.0 / (1 + @exp(-6 * x))) - 1;
        },
        .Tanh => {
            x = math.clamp(x, -1, 1);
            x = math.tanh(math.pi * x);
        },
        .Arctan => {
            x = math.clamp(x, -1, 1);
            x = (2.0 / 3.0) * math.atan(4 * math.pi * x);
        },
        .SineFold => {
            x = math.sin((math.pi / 2.0) * x);
            x = math.clamp(x, -1, 1);
        },
        .Tan => {
            x = math.clamp(x, -1, 1);
            x = math.tan((math.pi / 4.0) * x);
        },
        .TanFold => {
            x = math.tan((math.pi / 4.0) * x);
            x = math.clamp(x, -1, 1);
        },
        .SinTan => {
            x = math.sin(math.tan(x));
            x = math.clamp(x, -1, 1);
        },
        .TanSin => {
            x = math.tan(math.sin(x));
            x = math.clamp(x, -1, 1);
        },
    }
    x *= out_gain;
    return x;
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

const SLIDER_COUNT = 3;

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
        if (!std.mem.eql(u8, param_info.name, "Top Mode") and
            !std.mem.eql(u8, param_info.name, "Bottom Mode"))
        {
            const width = (WIDTH / SLIDER_COUNT) - (slider_gap * 2);
            gui.addComponent(.{
                // Given the gui.allocator, the memory will be cleaned up
                // on global GUI deinit. Otherwise, deallocate manually.
                .sub_type = arbor.Gui.Slider.init(gui.allocator, param_info, silver),
                .interface = arbor.Gui.Slider.interface,
                .value = param_info.getNormalizedValue(plugin.params[i]),
                .bounds = .{
                    .x = @intCast(i * (WIDTH / SLIDER_COUNT) + slider_gap),
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
        } else { // Mode menus.
            const menu_width = WIDTH / 2;
            const menu_height = HEIGHT / 4;
            const bot_pad = 50;
            gui.addComponent(.{
                .sub_type = arbor.Gui.Menu.init(gui.allocator, param_info.enum_choices orelse {
                    log.err("No enum choices available.\n", .{}, @src());
                    return;
                }, silver, 3, highlight_color),
                .interface = arbor.Gui.Menu.interface,
                .value = param_info.getNormalizedValue(plugin.params[i]), // Don't bother normalizing since we just care about the int.
                .bounds = .{
                    .x = @intCast((i - SLIDER_COUNT) * menu_width),
                    .y = HEIGHT - menu_height - bot_pad,
                    .width = menu_width,
                    .height = menu_height,
                },
                .background_color = slider_dark,
                .label = .{
                    .text = param_info.name,
                    .height = menu_height / 8,
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
    draw.olivec_sprite_blend(gui.canvas, 6, 6, 128, 128, logo_canvas);
}

// Logo destination buffer.
var logo_pix: [32 * 32]u32 = undefined;
var logo_canvas: draw.Canvas = .{
    .pixels = @ptrCast(&logo_pix),
    .width = 32,
    .height = 32,
    .stride = 32,
};

// Embed the image directly cuz idk what i'm doing.
const mindrot_ent_width: usize = 32;
const mindrot_ent_height: usize = 32;
var mindrot_ent_pixels = [_]u32{
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x0FA8DDDD, 0x55A8DDDD, 0x9DA8DDDD, 0xCCA8DDDD,
    0xF5A8DDDD, 0xFFA8DDDD, 0xFFA8DDDD, 0xF5A8DDDD, 0xCCA8DDDD, 0x9CA8DDDD, 0x54A8DDDD,
    0x0EA8DDDD, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x29A8DDDD, 0xA3A8DDDD,
    0xF5A8DDDD, 0xFF96C5C5, 0xFF7CA0A0, 0xFF637E7E, 0xFF576C6C, 0xFF32302D, 0xFF32302D,
    0xFF576C6C, 0xFF637E7D, 0xFF7CA0A0, 0xFF97C6C6, 0xF5A8DDDD, 0xA3A8DDDD, 0x29A8DDDD,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x0AA8DDDD, 0x87A8DDDD, 0xFFA5D9D9, 0xFF83ABAB, 0xFF485655, 0xFF281310, 0xFF4D7A89,
    0xFF63A7BA, 0xFF63A7BB, 0xFF3F5F6A, 0xFF528696, 0xFF60A2B9, 0xFF5FA0B3, 0xFF30343B,
    0xFF27130E, 0xFF485656, 0xFF85ABAD, 0xFFA5D9D9, 0x86A8DDDD, 0x0AA8DDDD, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x1FA8DDDD, 0xD6A8DDDD, 0xFF92BFBF, 0xFF4F5965,
    0xFF2E1530, 0xFF2D1529, 0xFF5B98AA, 0xFF71BECA, 0xFF72C7DC, 0xFF6BBACD, 0xFF4C7886,
    0xFF67AEC5, 0xFF67BAD3, 0xFF6AB5C9, 0xFF66B1D0, 0xFF3F5565, 0xFF2E1529, 0xFF341738,
    0xFF4F5862, 0xFF92BFBF, 0xD6A8DDDD, 0x1FA8DDDD, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x3DA8DDDD,
    0xECA8DDDD, 0xFF7EA0A4, 0xFF3D1854, 0xFF55228F, 0xFF481E74, 0xFF56899E, 0xFF75BEC3,
    0xFF6BB1B6, 0xFF669F8C, 0xFF70A693, 0xFF43626B, 0xFF588F9E, 0xFF71A570, 0xFF68B2C4,
    0xFF71BFD0, 0xFF5DA6CA, 0xFF47376D, 0xFF52218A, 0xFF34183E, 0xFF30162D, 0xFF7BA0A0,
    0xEAA8DDDD, 0x3DA8DDDD, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x1FA8DDDD, 0xECA8DDDD, 0xFF759398, 0xFF522083, 0xFF6125A3,
    0xFF582394, 0xFF475878, 0xFF6FC2D9, 0xFF73BDC7, 0xFF6FB6BB, 0xFF6D9B5B, 0xFF71AAA4,
    0xFF496B71, 0xFF5C919D, 0xFF669B88, 0xFF6EB3B6, 0xFF5EA3B4, 0xFF56A4C6, 0xFF508CB8,
    0xFF4C206C, 0xFF56248C, 0xFF6026A4, 0xFF481D74, 0xFF729393, 0xEAA8DDDD, 0x1FA8DDDD,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x0AA8DDDD, 0xD6A8DDDD,
    0xFF7CA0A1, 0xFF37184F, 0xFF592497, 0xFF411C65, 0xFF411C61, 0xFF54899A, 0xFF6EBBC9,
    0xFF6B9E63, 0xFF73A04B, 0xFF73AD8F, 0xFF639B99, 0xFF394745, 0xFF4F7E8D, 0xFF639EA3,
    0xFF689976, 0xFF6E9634, 0xFF5DAAC4, 0xFF4B95CB, 0xFF424B79, 0xFF411D5E, 0xFF4F2085,
    0xFF5B249D, 0xFF27130B, 0xFF7CA0A0, 0xD6A8DDDD, 0x0AA8DDDD, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x87A8DDDD, 0xFF92BFBF, 0xFF431C65, 0xFF2C161F, 0xFF562393,
    0xFF451E6E, 0xFF431D67, 0xFF61A3AD, 0xFF5F9F9E, 0xFF679D84, 0xFF6F9836, 0xFF739E38,
    0xFF669670, 0xFF4A6F6F, 0xFF5792A1, 0xFF6C9232, 0xFF6D9534, 0xFF6A9F89, 0xFF508CA0,
    0xFF4D8CAB, 0xFF406187, 0xFF471D65, 0xFF461E70, 0xFF3D1B54, 0xFF291515, 0xFF3B1959,
    0xFF92BFBF, 0x86A8DDDD, 0x00000000, 0x00000000, 0x00000000, 0x29A8DDDD, 0xFFA5D9D9,
    0xFF5B5A86, 0xFF401B65, 0xFF4B1F7C, 0xFF2F1730, 0xFF371A47, 0xFF334043, 0xFF65B2B3,
    0xFF67A49A, 0xFF63A4AE, 0xFF62A4B1, 0xFF65AAB4, 0xFF6CBDCD, 0xFF4C7771, 0xFF5FA0A2,
    0xFF61A9B8, 0xFF5EAEC6, 0xFF55888B, 0xFF5596B2, 0xFF508DA8, 0xFF437990, 0xFF30192C,
    0xFF30182D, 0xFF3E1B5E, 0xFF4D207F, 0xFF3E1B5A, 0xFF505A67, 0xFFA5D9D9, 0x29A8DDDD,
    0x00000000, 0x00000000, 0xA3A8DDDD, 0xFF83ABAB, 0xFF27130B, 0xFF28140B, 0xFF3D1B5A,
    0xFF522289, 0xFF49216A, 0xFF425365, 0xFF61A081, 0xFF5A7E47, 0xFF62A8A3, 0xFF5F8137,
    0xFF4B6134, 0xFF609C89, 0xFF41574B, 0xFF527E7E, 0xFF57835C, 0xFF556F25, 0xFF518EA2,
    0xFF4C7373, 0xFF4E8788, 0xFF437267, 0xFF3C1D4A, 0xFF471F6A, 0xFF3F1C5B, 0xFF311736,
    0xFF28140B, 0xFF27130B, 0xFF83ABAB, 0xA3A8DDDD, 0x00000000, 0x0FA8DDDD, 0xF5A8DDDD,
    0xFF485655, 0xFF3F1B62, 0xFF471D71, 0xFF4C1F7D, 0xFF2F182A, 0xFF391D3C, 0xFF2B180D,
    0xFF588461, 0xFF579495, 0xFF5E9B97, 0xFF5C9FA9, 0xFF49604B, 0xFF558C86, 0xFF3F5649,
    0xFF5B949B, 0xFF465C30, 0xFF5DA5BB, 0xFF528690, 0xFF4F8C9E, 0xFF529287, 0xFF394A30,
    0xFF3C1F48, 0xFF3C1E48, 0xFF471F6F, 0xFF4C207D, 0xFF3B1A52, 0xFF27140B, 0xFF485655,
    0xF5A8DDDD, 0x0DA8DDDD, 0x55A8DDDD, 0xFF96C5C5, 0xFF3B1759, 0xFF481D77, 0xFF29150C,
    0xFF3F1C5E, 0xFF2F1920, 0xFF4C217B, 0xFF3A1E3E, 0xFF4C7062, 0xFF5B9A95, 0xFF56949B,
    0xFF6ABAC7, 0xFF6FC3CF, 0xFF65B2BE, 0xFF405A51, 0xFF5C989E, 0xFF6BC1D5, 0xFF69C2E2,
    0xFF5A95A0, 0xFF579CAB, 0xFF52959D, 0xFF3B1E47, 0xFF482361, 0xFF361C39, 0xFF3B1C50,
    0xFF3F1C5E, 0xFF3C1A57, 0xFF2F162F, 0xFF27130A, 0xFF98C7C7, 0x53A8DDDD, 0x9DA8DDDD,
    0xFF7DA0A4, 0xFF5B209F, 0xFF6725B9, 0xFF431D6A, 0xFF6127A9, 0xFF53238B, 0xFF53238B,
    0xFF321C25, 0xFF3C4A55, 0xFF69BBBF, 0xFF60ACAD, 0xFF598F85, 0xFF569184, 0xFF528170,
    0xFF3F4921, 0xFF4C715D, 0xFF588C7C, 0xFF59938A, 0xFF4F8E94, 0xFF5BACBC, 0xFF4F8C91,
    0xFF311A25, 0xFF502671, 0xFF422156, 0xFF381B48, 0xFF451E6D, 0xFF3B1A53, 0xFF491C79,
    0xFF27130B, 0xFF7BA0A0, 0x9BA8DDDD, 0xCCA8DDDD, 0xFF7D80C1, 0xFF7C29E3, 0xFF7C29E3,
    0xFF6423B3, 0xFF512287, 0xFF4A2078, 0xFF53238B, 0xFF4D2278, 0xFF3E5169, 0xFF4C869B,
    0xFF271907, 0xFF2D210A, 0xFF2C1E09, 0xFF373B11, 0xFF588C8A, 0xFF4D7C71, 0xFF2A1C08,
    0xFF2E230A, 0xFF2B1F09, 0xFF251605, 0xFF569DB4, 0xFF331D29, 0xFF462168, 0xFF4E217F,
    0xFF5A249A, 0xFF5D26A1, 0xFF471E71, 0xFF6122AD, 0xFF451A71, 0xFF637E7D, 0xCCA8DDDD,
    0xF5A8DDDD, 0xFF5B6C77, 0xFF6723B9, 0xFF5A209C, 0xFF421B67, 0xFF53228B, 0xFF562491,
    0xFF6328AD, 0xFF4D227A, 0xFF381A45, 0xFF60ABBF, 0xFF281A07, 0xFF2E230A, 0xFF2C1F09,
    0xFF57929C, 0xFF64AFB7, 0xFF599FA6, 0xFF457279, 0xFF2F2A1F, 0xFF2B1F09, 0xFF2A3136,
    0xFF4A8299, 0xFF371E3F, 0xFF4D2376, 0xFF431F65, 0xFF2C1913, 0xFF461E6F, 0xFF6222AF,
    0xFF7C29E3, 0xFF7C29E3, 0xFF6B6EA2, 0xF3A8DDDD, 0xFFA8DDDD, 0xFF32302D, 0xFF32173A,
    0xFF391852, 0xFF421C66, 0xFF552391, 0xFF481F71, 0xFF391C47, 0xFF55248E, 0xFF3D5B61,
    0xFF6CBFCD, 0xFF6DBACB, 0xFF67B1C4, 0xFF62B0B7, 0xFF5DA6A4, 0xFF538890, 0xFF4F8D9F,
    0xFF569AA7, 0xFF67B2BA, 0xFF59AAC8, 0xFF5AB1D3, 0xFF4F9EC0, 0xFF493578, 0xFF592497,
    0xFF6428AF, 0xFF592598, 0xFF5C259E, 0xFF4F1F85, 0xFF6D26C2, 0xFF5F21AA, 0xFF363635,
    0xFFA8DDDD, 0xFFA8DDDD, 0xFF32302D, 0xFF2A151C, 0xFF3A1951, 0xFF401C60, 0xFF4A2078,
    0xFF4C217B, 0xFF371B45, 0xFF3D1E4F, 0xFF341D2B, 0xFF63A8AE, 0xFF6BC3CC, 0xFF4B8477,
    0xFF4D7A62, 0xFF60A4A7, 0xFF404F36, 0xFF528990, 0xFF519CB7, 0xFF41695E, 0xFF488BA8,
    0xFF57B0D6, 0xFF3A667C, 0xFF371E3D, 0xFF52238A, 0xFF4C217A, 0xFF482071, 0xFF54238E,
    0xFF3F1C5E, 0xFF3A1A50, 0xFF27140B, 0xFF363633, 0xFFA8DDDD, 0xF5A8DDDD, 0xFF576C6B,
    0xFF27140B, 0xFF2E162F, 0xFF2B1715, 0xFF3D1C55, 0xFF331A37, 0xFF3D1D51, 0xFF57248C,
    0xFF3C1F47, 0xFF321F22, 0xFF3C5F53, 0xFF374A3A, 0xFF528D86, 0xFF5FA8A5, 0xFF4E878E,
    0xFF4A828A, 0xFF549EAE, 0xFF262D27, 0xFF3E5C50, 0xFF323D45, 0xFF371F38, 0xFF48216B,
    0xFF4C227A, 0xFF3B1D50, 0xFF4F2183, 0xFF52228A, 0xFF481F72, 0xFF3C1A54, 0xFF27140B,
    0xFF566C6B, 0xF3A8DDDD, 0xCCA8DDDD, 0xFF637E7D, 0xFF27140B, 0xFF28150B, 0xFF331A36,
    0xFF3F1D56, 0xFF441F63, 0xFF4A206E, 0xFF3B1C48, 0xFF361E30, 0xFF3A203A, 0xFF323126,
    0xFF53929A, 0xFF5494A0, 0xFF71CADA, 0xFF64B0B9, 0xFF69BFD1, 0xFF5FABB9, 0xFF262E2D,
    0xFF5593A4, 0xFF361E38, 0xFF462168, 0xFF492271, 0xFF512384, 0xFF47206F, 0xFF3C1C54,
    0xFF431D68, 0xFF29160C, 0xFF291513, 0xFF3B1856, 0xFF657E82, 0xCCA8DDDD, 0x9CA8DDDD,
    0xFF82A1AD, 0xFF4C1C80, 0xFF28140B, 0xFF29160C, 0xFF2E1826, 0xFF2B180D, 0xFF341A32,
    0xFF351B34, 0xFF2E1C11, 0xFF391E38, 0xFF311D1A, 0xFF5AA1AC, 0xFF4D8994, 0xFF66B8C7,
    0xFF64B8C7, 0xFF60B3CF, 0xFF60AFC1, 0xFF45829A, 0xFF437A94, 0xFF42215A, 0xFF351E2F,
    0xFF421F5F, 0xFF532580, 0xFF5A2598, 0xFF4E227C, 0xFF451E6C, 0xFF311837, 0xFF471C75,
    0xFF4B1D7C, 0xFF7DA0A3, 0x9BA8DDDD, 0x54A8DDDD, 0xFF97C6C6, 0xFF2D1524, 0xFF512082,
    0xFF44205D, 0xFF371B3E, 0xFF341933, 0xFF2D1919, 0xFF321A2A, 0xFF2D1B0F, 0xFF371D35,
    0xFF321D22, 0xFF456C69, 0xFF60B2C0, 0xFF5CABBC, 0xFF60B1CA, 0xFF5FB7DB, 0xFF4B92AE,
    0xFF56ADD3, 0xFF312F31, 0xFF4D256E, 0xFF2E1C0F, 0xFF2F1B19, 0xFF3C1B48, 0xFF401B54,
    0xFF401F52, 0xFF5A2792, 0xFF592399, 0xFF4F2084, 0xFF291418, 0xFF98C7C7, 0x53A8DDDD,
    0x0EA8DDDD, 0xF5A8DDDD, 0xFF485655, 0xFF2C1521, 0xFF2B161B, 0xFF2D1721, 0xFF31182A,
    0xFF2C1814, 0xFF2F1A21, 0xFF2F1A1E, 0xFF2F1B1A, 0xFF341C2D, 0xFF2E1D10, 0xFF61B1C2,
    0xFF559FB1, 0xFF529EAF, 0xFF4F99AB, 0xFF53A5C7, 0xFF37555E, 0xFF2F1D16, 0xFF3E1E4B,
    0xFF2D1B0F, 0xFF331B2C, 0xFF2E191A, 0xFF331932, 0xFF2B1710, 0xFF2D1721, 0xFF361A3D,
    0xFF2B151D, 0xFF485655, 0xF5A8DDDD, 0x0CA8DDDD, 0x00000000, 0xA3A8DDDD, 0xFF83ABAB,
    0xFF27130B, 0xFF28140B, 0xFF2B1618, 0xFF29160C, 0xFF2A170D, 0xFF2B180D, 0xFF321A2B,
    0xFF301A21, 0xFF331B2B, 0xFF2F1B1A, 0xFF364545, 0xFF509CB8, 0xFF5DBCE3, 0xFF5BB6DC,
    0xFF437791, 0xFF301B1D, 0xFF311C24, 0xFF361A38, 0xFF2D1A15, 0xFF321A2C, 0xFF2B180D,
    0xFF2A170D, 0xFF2D171C, 0xFF29150F, 0xFF28140B, 0xFF27130B, 0xFF83ABAB, 0xA2A8DDDD,
    0x00000000, 0x00000000, 0x29A8DDDD, 0xFFA5D9D9, 0xFF4A5957, 0xFF2B151F, 0xFF291513,
    0xFF29160C, 0xFF2B1714, 0xFF31192A, 0xFF536366, 0xFF546665, 0xFF5A6D6F, 0xFF44494C,
    0xFF4C5758, 0xFF596D6C, 0xFF4B5756, 0xFF586D6B, 0xFF43494A, 0xFF586D6C, 0xFF474953,
    0xFF536366, 0xFF4C5759, 0xFF56636C, 0xFF3A363D, 0xFF2A170C, 0xFF2B1614, 0xFF2B1517,
    0xFF281412, 0xFF4B5B5A, 0xFFA5D9D9, 0x29A8DDDD, 0x00000000, 0x00000000, 0x00000000,
    0x86A8DDDD, 0xFF92BFBF, 0xFF2A141A, 0xFF27140B, 0xFF28150B, 0xFF32182F, 0xFF2E1821,
    0xFF729392, 0xFF739493, 0xFF586D6B, 0xFF88B1B1, 0xFF739493, 0xFF739493, 0xFF729393,
    0xFF526361, 0xFF88B1B0, 0xFF505F5D, 0xFF86AFAF, 0xFF373633, 0xFF6D8C8B, 0xFF739493,
    0xFF331930, 0xFF2D1720, 0xFF2A1512, 0xFF27140B, 0xFF291315, 0xFF92BFBF, 0x85A8DDDD,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x0AA8DDDD, 0xD6A8DDDD, 0xFF7BA0A0,
    0xFF27130B, 0xFF28140C, 0xFF341834, 0xFF2D161F, 0xFF6E8D8D, 0xFF729393, 0xFF586D6B,
    0xFF84ABAB, 0xFF739493, 0xFF739493, 0xFF739493, 0xFF586D6B, 0xFF87B1B0, 0xFF6E8D8C,
    0xFF7DA2A2, 0xFF586C6B, 0xFF6F8D8E, 0xFF739494, 0xFF301729, 0xFF2E1721, 0xFF27140B,
    0xFF27130B, 0xFF7CA1A1, 0xD6A8DDDD, 0x0AA8DDDD, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x1FA8DDDD, 0xEAA8DDDD, 0xFF729393, 0xFF28130E, 0xFF291413,
    0xFF291413, 0xFF70908F, 0xFF729393, 0xFF4C5A59, 0xFF87AFAF, 0xFF698685, 0xFF739493,
    0xFF739493, 0xFF586C6B, 0xFF87B1B0, 0xFF586D6B, 0xFF85ADAD, 0xFF363632, 0xFF729393,
    0xFF729393, 0xFF291411, 0xFF291412, 0xFF27130B, 0xFF729393, 0xE8A8DDDD, 0x1FA8DDDD,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x3DA8DDDD, 0xEAA8DDDD, 0xFF7CA0A0, 0xFF27130A, 0xFF27140C, 0xFF729393, 0xFF729393,
    0xFF576C6B, 0xFF87B1B0, 0xFF739493, 0xFF739493, 0xFF779A99, 0xFF6E8D8C, 0xFF83AAAA,
    0xFF576C6B, 0xFF7FA6A5, 0xFF576D6C, 0xFF668281, 0xFF729393, 0xFF281411, 0xFF28130E,
    0xFF7CA1A1, 0xE8A8DDDD, 0x3EA8DDDD, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x1FA8DDDD, 0xD6A8DDDD,
    0xFF92BFBF, 0xFF4A5958, 0xFF27130B, 0xFF27140B, 0xFF28140B, 0xFF28140B, 0xFF28150B,
    0xFF28150C, 0xFF28150C, 0xFF28150C, 0xFF28150C, 0xFF28150B, 0xFF28140B, 0xFF28140B,
    0xFF27140B, 0xFF27130B, 0xFF4C5B5A, 0xFF92BFBF, 0xD6A8DDDD, 0x1FA8DDDD, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x0AA8DDDD, 0x86A8DDDD, 0xFFA5D9D9, 0xFF83ABAB,
    0xFF485655, 0xFF27130A, 0xFF27130B, 0xFF27140B, 0xFF27140B, 0xFF27140B, 0xFF27140B,
    0xFF27140B, 0xFF27140B, 0xFF27130B, 0xFF27130A, 0xFF485655, 0xFF83ABAB, 0xFFA5D9D9,
    0x85A8DDDD, 0x0AA8DDDD, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x29A8DDDD, 0xA3A8DDDD, 0xF5A8DDDD, 0xFF98C7C7, 0xFF7BA0A0,
    0xFF637E7D, 0xFF566C6B, 0xFF363633, 0xFF363633, 0xFF566C6B, 0xFF637E7D, 0xFF7BA0A0,
    0xFF98C7C7, 0xF5A8DDDD, 0xA2A8DDDD, 0x29A8DDDD, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x0DA8DDDD, 0x53A8DDDD, 0x9BA8DDDD, 0xCCA8DDDD, 0xF3A8DDDD, 0xFFA8DDDD,
    0xFFA8DDDD, 0xF3A8DDDD, 0xCCA8DDDD, 0x9BA8DDDD, 0x53A8DDDD, 0x0CA8DDDD, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000,
};

fn drawLogo() void {
    const mindrot_ent_canvas = draw.olivec_canvas(
        &mindrot_ent_pixels,
        mindrot_ent_width,
        mindrot_ent_height,
        mindrot_ent_width,
    );
    draw.olivec_sprite_copy(
        logo_canvas,
        0,
        0,
        mindrot_ent_width,
        mindrot_ent_height,
        mindrot_ent_canvas,
    );
}
