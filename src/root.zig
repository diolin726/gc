//! GcAllocator implemention
//! not support: save ptr in usize / union(not tagged) / *anyopaque 
//! maybe will only save what's in *anyopaque , any ptr inside usize / untagged union will be dropped
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const GcAllocator = @This();

child_allocator : Allocator,
state: State,

pub const State = struct{
    
    options: GcOptions = standard,//threadsafe or standard
    
    //for gc
    stack_list: ?*Frame = null,
    byte_allocated: usize = 0,
    gc_threashold:usize = 1024*1024,
    
    
    //for pagesAllocator
    page_size:u16 = 4096,
    size_clases:[]u16 = .{ 16,32,64,128,256,512,1024 },
    page_book: std.AutoHashMapUnmanaged(usize, void)=.{} ,
    free_pages: ?*Page = null,
    used_pages: ?[]Page = null,
    //large obj
    large_list: ?*LargeHeader = null,
    large_book:std.AutoHashMapUnmanaged(usize , *LargeHeader )=.{},

    //pub const init:State = .{ //init移到init函式中
    //    .stack_list = null,
    //    .byte_allocated = 0,
    //    gc_threashold = 1024*1024,
    //    page_size = 4096,
    //    size_clases = .{16,32,64,128,256,512,1024},
    //    page_book = .{},
    //    free_pages=null,
    //    used_pages=null,
    //    large_list=null,
    //    large_book=.{},
    //};
    pub fn promote(state:State , child_allocator:Allocator ) GcAllocator{
        return .{
            .child_allocator = child_allocator,
            .state = state,
            };
    }
};
const Frame = struct{
    next: ?*Frame,
    trace_fn: const *fn( self: *Frame , gc:*GcAllocator )void, 
    pub fn trace( self:*Frame , gc:*GcAllocator ) void{
        self.trace_fn( self, gc );
    }
};
const Page = packed struct{
    slot_size: u16,
    cap: u16,
    data_offset: u16,
    free_list: ?*Node,
    next_page: ?*Page,
    pub fn metaSlice(self:*Page) []Slot {
        const base: [*]u8 = @ptrCast(self);
        const meta_ptr: [*]Slot = @ptrCast(base + @sizeOf(Page) );
        return meta_ptr[0..self.cap];
    }
};
const GcOptions=enum{
    standard,
    threadsafe,
};
const Node = struct{
    next: ?*Node, 
};
const Slot = packed struct{
    mark:Mark,
    age:u6
};
const LargeHeader= packed struct{
    next:?*LargeHeader, // usize 8 bytes in 64 bit
    len: u56,
    slot: Slot, // 1 byte
};
const Mark:enum(u2){
    White,
    Black,
    Gray,
    Free
};
///default usage: const gc = GcAllocator.init( std.heap.PageAllocator , .{});
///default size class : { 16,32,64,128,256,512,1024 }, manuel size class should be power of two, bigger than 8;
///if wanna use multi threads: .{ .option=threadsafe }
///recommend to read source code yourself.
pub fn init( child_allocator:Allocator , state :State )GcAllocator { 
    var realstate=state;
    realstate.used_pages:[state.size_classes.len] = @splat(null);
    return .{ .state = realstate , child_allocator=child_allocator }; 
}
pub fn allocator(gc:*GcAllocator ) Allocator{
    return .{
        .ptr = gc,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}
pub fn getframetype( root:type ) type{
    const info = @typeInfo(root);
    assert( info == .@"struct" && info.@"struct".is_tuple );
    return struct{
        node: Frame,
    };
} 
pub fn getframe( gc:*GcAllocator , root:anytype ) getframetype(@TypeOf( root )) {
    
}
