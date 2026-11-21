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
    trace_stack: std.ArrayList(WorkItem) = .empty,
    marked_book: std.AutoHashMapUnmanaged( struct{usize , usize} , void ) = .{} , 

    //for pagesAllocator
    page_size:u16 = 4096 ,  //should be power of two. TODO recommand to stay 4096 else we'll need to deal with aligns.
    size_clases:[]u16 = .{ 16,32,64,128,256,512,1024 },
    page_book: std.AutoHashMapUnmanaged(usize, void)=.{} ,
    free_pages: ?*Page = null,
    used_pages: ?[]Page = null,
    //large obj
    //large_list: ?*LargeHeader = null, //seems to be useless
    large_book:std.AutoArrayHashMapUnmanaged(usize ,void)=.{},
    sorted_large_book:ArrayList(*LargeHeader)
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
///Type for registering stack vars
const Frame = struct{
    next: ?*Frame,
    prev: ?*Frame,
    trace_fn: *const fn( self: *Frame , gc:*GcAllocator )void, 
    pub fn trace( self:*Frame , gc:*GcAllocator ) void{
        self.trace_fn( self, gc );
    }
};
///Type of headers of pageAllocator
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
    ///not threadsafe , can alloc any size of obj.
    standard,
    /// i'll deal with it later , add some locks and use some atomic actions.
    threadsafe, 
    ///no alloc object > page_size bytes
    small 
}
///Type for free list in Page headers.
const Node = struct{ 
    next: ?*Node, 
};
///every metadata of element
const Slot = packed struct{
    mark:Mark,
    age:u7 
};
///for Large obj bigger than page_size bytes , in small mode wont be needed
const LargeHeader= packed struct{
    //next:?*LargeHeader, // usize 8 bytes in 64 bit , seems to be useless
    len: u56, // 7 byte
    slot: Slot, // 1 byte
};
///Mark for gc
const Mark:enum(u1){
    ///not marked
    White,
    ///marked 
    Black,
};
///default usage: const gc = GcAllocator.init( std.heap.PageAllocator , .{});
///default size class : { 16,32,64,128,256,512,1024 }, manuel size class should be power of two, bigger than 8;
///if wanna use multi threads: .{ .option=threadsafe }
///recommend to read source code yourself.
pub inline fn init( child_allocator:Allocator , state :State )GcAllocator { 
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
fn mkFrame( Tuple:type ) type {
    return struct{
        frame: Frame,
        tuple: Tuple,
    };
}
/// return a frame variable , user should use getframe(.{&a , &b});
/// to open a stack list , used for mark-sweeping
/// to register , use gc.new( &frame ); defer gc.delete(&frame);
pub fn getframe( root:anytype ) mkFrame(@TypeOf(root)) {
    return .{
        .frame=.{
            .prev = null,
            .next = null,
            .trace_fn = struct{
                fn trace ( self:*Frame , gc:*GcAllocator ) !void {
                    const frame:mkFrame(@TypeOf(root)) = @fieldParentPtr( "frame" , self ).*;
                    inline for ( 0..frame.tuple.len ) |i|{
                        const stackVar = frame.tuple[i];
                        try gc.mark(stackVar);
                    }
                }
            }.trace,
        },
        .tuple = root,
    };
}
pub fn new( gc:*GcAllocator , frame_ptr:anytype )void{
    assert( @hasField(@typeInfo( @TypeOf( frame_ptr ) ).pointer.child , "frame" )); 
    frame_ptr.frame.next = gc.state.stack_list;
    frame_ptr.frame.next.prev = &frame.frame;
    gc.state.stack_list = &frame.frame;
}

pub fn delete(gc:*GcAllocator , frame_ptr:anytype ) void{
    assert( @hasField( @typeInfo ( @TypeOf( frame_ptr )).pointer.child , "frame" )); 
    if( frame_ptr.frame.next ) |next|{
        next.prev = frame_ptr.frame.prev;
    }
    if( frame_ptr.frame.prev ) |prev|{
        prev.next = frame_ptr.frame.next;
    }else{
        gc.state.stack_list = frame_ptr.frame.next ;
    }
}
fn typeId ( T:type ) usize{
    const a=struct{
        var dummy:u8 = 0;
        comptime{
            _ = T;
        }
    };
    return @intFromPtr( &a.dummy );
}
const WorkItem = struct{
    ptr: *anyopaque,
    expaned_fn: *const fn( current: *WorkItem ,gc:*GcAllocator) !void,
    pub fn expand( current:*WorkItem , gc:*GcAllocator )!void{
        try current.expaned_fn( current ,gc, stack , allocator );
    }
    pub fn hasPtr( x:type ) bool  {
        return switch(@typeInfo(x)){
            .pointer=>true,
            .optional=>|opt| hasPtr(opt.child),
            .array=>|arr| hasPtr(arr.child),
            .vector=>|vec| hasPtr(vec.child),
            .@"struct" => |s| inline for(s.fields) |f|{
                if(hasPtr(f.type)) break true;
            }else false,
            .@"union"  => |u| inline for(u.fields) |f|{
                if(hasPtr(f.type)) break true;
            }else false,
           .error_union => |eu| hasPtr(eu.payload),
           else=>false,
        }
    }
};
fn mkWorkItem( ptr: anytype )WorkItem{ // slice a[0..2] and a[0..1] might have a race, end up a[2] being free.
    assert( @typeInfo(@TypeOf(ptr)) == .pointer  );
    return .{
        .ptr = @ptrCast(ptr) ,
        .expand_fn = struct{
            fn expand_fn( self:*WorkItem ,gc:*GcAllocator  ) !void{
                const rootType = @TypeOf(ptr) ;
                const root: rootType = @ptrCast(@alignCast(self.ptr));
                const childType = @typeInfo(rootType).pointer.child; 
                const childTypeInfo = @typeInfo(childType);
                if( !self.hasPtr(childType) ) return;
                if( !gc.state.marked_book.contains(.{ @intFromPtr(root),typeId(rootType)}){
                    gc.state.marked_book.put(gc.child_allocator,.{ @intFromPtr(root) ,typeId(rootType)} , {});
                    switch( childTypeInfo ){ // ensure this ptr,type is not already marked
                        .pointer =>{ //TODO think about sizes in .pointer , slice / many / one / c(optional) 
                            if( childTypeInfo.size == .one  ){
                                if( gc.markSlot( root.* , .Black )){ 
                                    // *anyopaque will be blocked in hasPtr section but that pointer will be marked.
                                    try gc.state.stack.append(
                                            gc.child_allocator,
                                            mkWorkItem(root.*)
                                            );
                                    //i am thinking that if a struct is a large obj, 
                                    //and a stack pointer point to a little part of that,
                                    //it'll end up saving all part of the struct.
                                    //but i guess that can be fixed with coping gc, which is not my goal
                                } 
                            }else if(childTypeInfo.size == .slice ){
                                for( root.* )| sliceObj |{
                                    if( gc.markSlot(sliceObj) ){
                                        try gc.state.stack.append(
                                                gc.child_allocator,
                                                mkWorkItem( sliceObj )    
                                            );
                                    }
                                }
                            }else if(childTypeInfo.size == .many){
                            
                            }else{
                                @compileError("c ptr is not yet supported");
                            }
                        }
                        .optional =>{
                            if( root* )|child|{
                                gc.state.stack.append(
                                    gc.child_allocator, 
                                    mkWorkItem( child )
                                    );
                            }
                        }
                        .array=>{
                        
                        }
                    }
                }
            }
        }.expand_fn
    }
}
fn markSlot( gc:*GcAllocator , addr:*anyopaque , mark:GcAllocator.Mark) bool {
    if( gc.foundPage( addr ) )|page|{ 
        page.metaSlice()[(@intFromPtr(root.*) - @intFromPtr(page) - page.data_offset) / page.slot_size].mark = mark;
        return true;
    }
    if( gc.state.options != .small ) {
        if( gc.foundLarge( addr ) )|large|{                            
            large.mark = mark;
            return true;
        }
    }
    return false;            
}
pub fn foundPage(self:*GcAllocator , ptr:*anyopaque ) ?*Page{
    //page sizes should be power of two 
    assert( std.math.isPowerOfTwo(self.state.page_size) );
    const ptrInt = @intFromPtr( ptr);
    const pagePtrInt = ptrInt & ~( self.state.page_size - 1 ); 
    
    if(pagePtrInt == 0 ) return null;
    const pagePtr:*Page = @ptrFromInt( pagePtrInt );
    if( self.state.page_book.contains(  pagePtrInt) )  return pagePtr;
    else return null;
}
pub fn foundLarge( self:*GcAllocator , ptr:*anyopaque)?*LargeHeader  {
    //should call sort first , assume after key is sorted
    const keyList = self.state.large_book.keys();
    if( keyList.len() == 0 ) return null;
    const idx = std.sort.upperBound(
            usize,
            keyList,
            @as(usize, @intFromPtr(ptr)),
            struct{
                fn cmp( a:usize , b:usize )std.math.Order{
                    return std.math.order(a,b);
                }
            }.cmp
        ) ;
    if(idx == 0 )return null;
    const start = keyList[idx-1];
    const header:*LargeHeader = @ptrFromInt(start);
    if( start + @sizeOf(LargeHeader) + header.len > @intFromPtr( ptr  )  ) return header;
    else return null;
}
fn mark( gc:*GcAllocator, ptr:anytype )!void{
    try gc.state.stack.append( 
        gc.child_allocator,
        mkWorkItem( ptr )  
        );
    while( gc.state.stack.pop() )|workitem|{
        try workitem.expand( gc ); 
    }   
}
pub fn manualGc( gc:*GcAllocator ) void {
    var cursur = gc.state.stack_list orelse return;// TODO no stack list should be a error
    while(cursur) |frame|{
        frame.trace(gc);
        cursur = frame.next;
    }
    gc.state.marked_book.clearRetainingCapacity();
    //scan pages ,if empty space mov it to free list.
    
    //TODO
}
