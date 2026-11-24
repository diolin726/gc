const std = @import("std");
const GcAllocator = @import("GcAllocator.zig");
const assert = std.debug.assert;
test "test normal usage"{
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

