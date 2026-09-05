//! `harpoon.*` runners — the table only; the behaviour is `harpoon.zig`.
//! Nine `goto_N` entries exist because a spec id is one command and a
//! command takes no argument (D5).

const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const harpoon = @import("harpoon.zig");

pub const table = .{
    .@"harpoon.add" = &harpoon.add,
    .@"harpoon.menu" = &harpoon.menu,
    .@"harpoon.clear" = &harpoon.clearCmd,
    .@"harpoon.goto_1" = &goto1,
    .@"harpoon.goto_2" = &goto2,
    .@"harpoon.goto_3" = &goto3,
    .@"harpoon.goto_4" = &goto4,
    .@"harpoon.goto_5" = &goto5,
    .@"harpoon.goto_6" = &goto6,
    .@"harpoon.goto_7" = &goto7,
    .@"harpoon.goto_8" = &goto8,
    .@"harpoon.goto_9" = &goto9,
};

fn goto1(app: *App) CommandError!void {
    return harpoon.goto(app, 1);
}
fn goto2(app: *App) CommandError!void {
    return harpoon.goto(app, 2);
}
fn goto3(app: *App) CommandError!void {
    return harpoon.goto(app, 3);
}
fn goto4(app: *App) CommandError!void {
    return harpoon.goto(app, 4);
}
fn goto5(app: *App) CommandError!void {
    return harpoon.goto(app, 5);
}
fn goto6(app: *App) CommandError!void {
    return harpoon.goto(app, 6);
}
fn goto7(app: *App) CommandError!void {
    return harpoon.goto(app, 7);
}
fn goto8(app: *App) CommandError!void {
    return harpoon.goto(app, 8);
}
fn goto9(app: *App) CommandError!void {
    return harpoon.goto(app, 9);
}
