const std = @import("std");
const GcAllocator = @import("GcAllocator.zig");
const assert = std.debug.assert;
test "normal usage"{
    var gc = GcAllocator.init( std.heap.page_allocator ,.{.options = .standard , .page_size = 128 , .size_classes= &.{8},  });
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
test "check manual gc"{
    var gc = GcAllocator.init( std.heap.page_allocator , .{.options = .standard , });
    defer gc.deinit();

    const allocator = gc.allocator();
    const Node = *usize;
    var root:Node =  undefined;
    var frame = gc.getFrame(.{&root});
    gc.new(&frame);

    var tmp:i32 = undefined; //because no stack list will assert
    var frame2 = gc.getFrame(.{&tmp});
    gc.new(&frame2);

    {
        const first = try allocator.create(usize);
        first.* = 6767;
        root = first;
    }
    //const first = std.mem.asBytes(root) ;
    //std.debug.print( "{x}\n", .{first} );
    const first_val = root.*;
    try gc.manualGc();

    //const sec = std.mem.asBytes(root) ;
    //std.debug.print( "{x}\n",.{sec}  );
    const sec_val = root.*;
    gc.delete(&frame);
    try gc.manualGc();

    //const third = std.mem.asBytes(root) ;
    //std.debug.print( "{x}\n", .{third}  );
    const third_val = root.*;
    assert( first_val == sec_val and third_val != first_val );
}
