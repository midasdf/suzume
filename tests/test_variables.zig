const std = @import("std");
const variables = @import("css").variables;

const VarMap = variables.VarMap;

test "simple var() resolution" {
    var vm = VarMap.init(std.testing.allocator);
    defer vm.deinit();
    vm.set("--color", "red");

    const result = variables.resolveVarRefs("var(--color)", &vm, std.testing.allocator).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("red", result);
}

test "var() with fallback used when not found" {
    var vm = VarMap.init(std.testing.allocator);
    defer vm.deinit();

    const result = variables.resolveVarRefs("var(--missing, blue)", &vm, std.testing.allocator).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("blue", result);
}

test "var() with fallback not used when found" {
    var vm = VarMap.init(std.testing.allocator);
    defer vm.deinit();
    vm.set("--color", "green");

    const result = variables.resolveVarRefs("var(--color, blue)", &vm, std.testing.allocator).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("green", result);
}

test "no var() returns null" {
    var vm = VarMap.init(std.testing.allocator);
    defer vm.deinit();

    const result = variables.resolveVarRefs("red", &vm, std.testing.allocator);
    try std.testing.expect(result == null);
}

test "var() in context of larger value" {
    var vm = VarMap.init(std.testing.allocator);
    defer vm.deinit();
    vm.set("--size", "10px");

    const result = variables.resolveVarRefs("calc(var(--size) + 5px)", &vm, std.testing.allocator).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("calc(10px + 5px)", result);
}

test "nested var() in fallback" {
    var vm = VarMap.init(std.testing.allocator);
    defer vm.deinit();
    vm.set("--fallback-color", "orange");

    const result = variables.resolveVarRefs("var(--primary, var(--fallback-color, pink))", &vm, std.testing.allocator).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("orange", result);
}

test "nested var() fallback to default" {
    var vm = VarMap.init(std.testing.allocator);
    defer vm.deinit();

    const result = variables.resolveVarRefs("var(--primary, var(--secondary, pink))", &vm, std.testing.allocator).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("pink", result);
}

test "parent chain lookup" {
    var parent = VarMap.init(std.testing.allocator);
    defer parent.deinit();
    parent.set("--bg", "black");

    var child = VarMap.initWithParent(std.testing.allocator, &parent);
    defer child.deinit();
    child.set("--fg", "white");

    const result1 = variables.resolveVarRefs("var(--bg)", &child, std.testing.allocator).?;
    defer std.testing.allocator.free(result1);
    try std.testing.expectEqualStrings("black", result1);

    const result2 = variables.resolveVarRefs("var(--fg)", &child, std.testing.allocator).?;
    defer std.testing.allocator.free(result2);
    try std.testing.expectEqualStrings("white", result2);
}

test "child overrides parent" {
    var parent = VarMap.init(std.testing.allocator);
    defer parent.deinit();
    parent.set("--color", "black");

    var child = VarMap.initWithParent(std.testing.allocator, &parent);
    defer child.deinit();
    child.set("--color", "white");

    const result = variables.resolveVarRefs("var(--color)", &child, std.testing.allocator).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("white", result);
}

test "multiple var() in one value" {
    var vm = VarMap.init(std.testing.allocator);
    defer vm.deinit();
    vm.set("--x", "1px");
    vm.set("--y", "2px");

    const result = variables.resolveVarRefs("var(--x) var(--y)", &vm, std.testing.allocator).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1px 2px", result);
}
