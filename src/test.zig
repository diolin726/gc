const std = @import("std");
const assert = std.debug.assert;
fn typeId( x : type ) usize {
    const a = struct{
        var dummy:u8=0;
        comptime{
            _ = x ;
        }
    };
    return @intFromPtr( &a.dummy );
}
test "test type"{
    std.debug.print( "{} , {} , {}\n" , .{ typeId(i32) , typeId(usize) , typeId(struct{i32})} );
    assert( typeId(i32) == typeId(i32) );
    assert( typeId(i32) != typeId(usize));
    assert( typeId(i32) != typeId( struct{ a:i32 }  ) );
}   

