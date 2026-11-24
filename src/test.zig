const std = @import("std");
const GcAllocator = @import("GcAllocator.zig");
const assert = std.debug.assert;
test "normal usage"{
    var gc = GcAllocator.init( std.heap.page_allocator ,.{.options = .debug , .page_size = 128 , .size_classes= &.{8},  });
    defer gc.deinit();
    const allocator = gc.allocator();
    var a :std.ArrayList(i32) = .empty;
    defer a.deinit(allocator);
    var frame = gc.getFrame(.{&a});
    gc.new(&frame);
    defer gc.delete(&frame);

    for(0..1000)|i|{
        try a.append( allocator ,@intCast(i));
    }
}   
const Node = struct{
    next: ?*Node,
};
test "check manual gc"{
    var gc = GcAllocator.init( std.heap.page_allocator , .{.options = .debug , });
    defer gc.deinit();

    const allocator = gc.allocator();

    var root = Node{.next = null};
    var frame = gc.getFrame(.{&root});
    gc.new(&frame);

    var tmp:i32 = undefined; //because no stack list will assert;
    var frame2 = gc.getFrame(.{&tmp});
    gc.new(&frame2);

    {
        const first = try allocator.create(Node);
        first.* = .{ .next = null };
        root.next = first;
    }
    {
        const sec = try allocator.create(Node);
        sec.* = .{ .next = null };
        root.next.?.next = sec;
    }
    const first = std.mem.asBytes(root.next.?) ;
    std.debug.print( "{x}\n", .{std.mem.asBytes(root.next.?)} );
    try gc.manualGc();

    const sec = std.mem.asBytes(root.next.?) ;
    std.debug.print( "{x}\n",.{std.mem.asBytes(root.next.?)}  );

    gc.delete(&frame);
    try gc.manualGc();

    const thrid = std.mem.asBytes(root.next.?) ;
    std.debug.print( "{x}\n", .{std.mem.asBytes(root.next.?)}  );

    assert( first==sec and thrid != first );
}
