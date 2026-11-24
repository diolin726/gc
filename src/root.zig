//! GcAllocator implemention
//! not support: save ptr in usize / union(not tagged) / *anyopaque 
//! maybe will only save what's in *anyopaque , any ptr inside usize / untagged union will be dropped

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const GcAllocator = @This();

child_allocator : Allocator,
state: State,


pub const State = struct{ // TODO make some state options become a comptime const
    
    options: GcOptions = .standard,//threadsafe or standard
    
    //for gc
    stack_list:?*Frame = null,
    byte_allocated:usize = 0,
    gc_threashold:usize = 1024*1024,
    age_threashold:u7 = 10, //use with max(u7) will cause problem
    stack: std.ArrayList(WorkItem) = .empty, //trace_stack
    marked_book: std.AutoHashMapUnmanaged( struct{usize , usize} , void ) = .{} , 

    //for pagesAllocator
    page_size:u16 = 4096 ,  //should be power of two. TODO recommand to stay 4096 else we'll need to deal with aligns.
    size_clases:[]const u16 = .{ 16,32,64,128,256,512,1024 },
    page_book: std.AutoHashMapUnmanaged(usize, void)=.{} ,
    free_pages: ?*Page = null,
    used_pages: ?[]?*Page = null,
    //large obj
    //large_list: ?*LargeHeader = null, //seems to be useless
    large_book:std.AutoArrayHashMapUnmanaged(usize ,void)=.{} ,
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
    trace_fn: *const fn( self: *Frame , gc:*GcAllocator ) Allocator.Error!void, 
    pub fn trace( self:*Frame , gc:*GcAllocator ) Allocator.Error!void{
        try self.trace_fn( self, gc );
    }
};
///Type of headers of pageAllocator
const Page = packed struct{
    ///size of every slot
    slot_size: u16,
    cap: u16,
    ///pointer offset from Page to first element
    data_offset: u16,
    free_list: ?*Node,
    next: ?*Page,
    pub fn metaSlice(self:*Page) []Slot {
        const base = @intFromPtr(self);
        const meta_ptr: [*]Slot = @ptrFromInt( base + @sizeOf(Page) );
        return meta_ptr[0..self.cap];
    }
    pub fn slotToNode( self:*Page , slotPtr:*Slot ) *Node{
        const slotStart:usize = ( @intFromPtr(self) + @sizeOf(Page));
        const slotCount = ( @intFromPtr(slotPtr) - slotStart )/@sizeOf(Slot);
        return @ptrFromInt(slotCount * self.slot_size + self.data_offset + @intFromPtr(self));
    }
    pub fn ptrToSlot( self: *Page , nodePtr:*anyopaque ) *Slot{
        const nodeCount = ( @intFromPtr(nodePtr) - @intFromPtr(self) - self.data_offset ) / self.slot_size ;
        return &self.metaSlice()[nodeCount];
    }
};
const GcOptions=enum{
    ///not threadsafe , can alloc any size of obj.
    standard,
    /// i'll deal with it later , add some locks and use some atomic actions.
    threadsafe, 
    ///no alloc object > page_size bytes
    small,
    ///debug only
    debug,
};
///Type for free list in Page headers.
const Node = struct{ 
    next: ?*Node, 
};
///every metadata of element
const Slot = packed struct{
    mark:Mark,
    ///age is for minus byte allocated
    ///and age = 1 means it's new, 0 means it's dead
    ///so a memory with age = 3 means it survive 2 times
    age:u7 
};
///for Large obj bigger than page_size bytes , in small mode wont be needed
const LargeHeader = packed struct{
    //next:?*LargeHeader, // usize 8 bytes in 64 bit , seems to be useless
    len: u56, // 7 byte
    slot: Slot, // 1 byte
};
///Mark for gc
const Mark = enum(u1){ 
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
    var realstate = state;
    realstate.used_pages= @as( [ state.size_classes.len ]?*Page , @splat(null) );
    return .{ .state = realstate , .child_allocator=child_allocator }; 
}
pub fn allocator(gc:*GcAllocator ) Allocator{
   return gc.child_allocator;
   // return .{
   //     .ptr = gc,
   //     .vtable = &.{
   //         .alloc = alloc,
   //         .resize = resize,
   //         .remap = remap,
   //         .free = free,
   //     },
   // };
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
                    const frame=@as(*mkFrame(@TypeOf(root)), @fieldParentPtr( "frame" , self ));
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
    frame_ptr.frame.next.prev = &frame_ptr.frame;
    gc.state.stack_list = &frame_ptr.frame;
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
    expand_fn: *const fn( current: *WorkItem ,gc:*GcAllocator)Allocator.Error!void,
    pub fn expand( current:*WorkItem , gc:*GcAllocator )Allocator.Error!void{
        try current.expand_fn( current ,gc );
    }
    pub fn hasPtr( x:type ) bool  {
        return switch(@typeInfo(x)){
            .pointer=>true,
            .optional=>|opt| WorkItem.hasPtr(opt.child),
            .array=>|arr| WorkItem.hasPtr(arr.child),
            .vector=>|vec| WorkItem.hasPtr(vec.child),
            .@"struct" => |s| inline for(s.fields) |f|{
                if(WorkItem.hasPtr(f.type)) break true;
            }else false,
            .@"union"  => |u| inline for(u.fields) |f|{
                if(WorkItem.hasPtr(f.type)) break true;
            }else false,
           .error_union => |eu| WorkItem.hasPtr(eu.payload),
           else=>false,
        };
    }
};
fn mkWorkItem( ptr: anytype )WorkItem{ // slice a[0..2] and a[0..1] might have a race, end up a[2] being free.
    assert( @typeInfo(@TypeOf(ptr)) == .pointer  );
    return .{
        .ptr = @ptrCast(ptr) ,
        .expand_fn = struct{
            fn expand_fn( self:*WorkItem ,gc:*GcAllocator  ) !void{
                const rootType = @TypeOf(ptr) ;
                const root: rootType = @ptrCast(@constCast(@alignCast(self.ptr)));
                const childType = @typeInfo(rootType).pointer.child; 
                const childTypeInfo = @typeInfo(childType);
                if( comptime !WorkItem.hasPtr(childType) ) return;
                if( !(try gc.state.marked_book.getOrPut(gc.child_allocator , .{ @intFromPtr(root),typeId(rootType)}) ).found_existing  ) {
                    switch( childTypeInfo ){ // ensure this ptr,type is not already marked
                        .pointer =>{  
                            if( childTypeInfo.pointer.size == .one  ){
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
                            }else if(childTypeInfo.pointer.size == .slice ){
                                for( root.* )| sliceObjWrapper |{
                                    if(sliceObjWrapper)|sliceObj| // in case sliceObj is null
                                        if( gc.markSlot( sliceObj ,.Black ) ) try gc.state.stack.append(
                                                gc.child_allocator,
                                                mkWorkItem( sliceObj )    
                                            );
                                }
                            }else if(childTypeInfo.pointer.size == .many){
                                if( std.meta.sential(childType) != null){
                                    const span = std.mem.span( root.* );
                                    for( span )|sliceObjWrapper|{
                                        if(sliceObjWrapper) |sliceObj| //in case sliceObj is null
                                            if(gc.markSlot(sliceObj,.Black)) try gc.state.stack.append(
                                                gc.child_allocator,
                                                mkWorkItem(sliceObj)
                                            );
                                    }
                                }else if( !WorkItem.hasPtr( childTypeInfo.pointer.child ) ){ // [*]u8 [*]i32 or anything except a pointer
                                    _ = gc.markSlot( root.* , .Black );
                                }else{
                                    @compileError("many pointer without a sential value and contains a pointer is not supported");
                                }
                            }else{
                                @compileError("c ptr is not yet supported");
                                //TODO
                                //but c ptr is actually shouldn't care since it's control by c library
                            }
                        },
                        .optional =>{
                            if( root.* )|child|{
                                if( gc.markSlot( child, .Black ) ) try gc.state.stack.append(
                                        gc.child_allocator,
                                        mkWorkItem(child)
                                    );
                            }
                        },
                        inline .array, .vector=>{
                            inline for( root.* )|childWrapper|{
                                if(childWrapper)|child| //in case child is null
                                    if( gc.markSlot( child , .Black) ) try gc.state.stack.append(
                                        gc.child_allocator , 
                                        mkWorkItem(child)
                                    );
                            }
                        },
                        .@"struct"=>{
                            if( childTypeInfo.@"struct".layout==.@"packed" ) {
                                try gc.packedTrace(root.*);
                                return ;
                            }
                            inline for( childTypeInfo.@"struct".field_names )|field|{
                                if( comptime WorkItem.hasPtr( @TypeOf(@field(root.* , field)))){//in case is null
                                    if(@field( root.* , field ))|structObj| try gc.state.stack.append(
                                        gc.child_allocator,
                                        mkWorkItem(structObj)
                                    );
                                }
                            }
                        },
                        .@"union"=>{
                            if(childTypeInfo.@"union".layout == .@"packed" ){
                                try gc.packedTrace(root.*);
                                return;
                            }
                            if( childTypeInfo.@"union".tag_type == null ){
                                if( WorkItem.hasPtr(childType) ) 
                                    @compileError( "pointer inside an untagged union is unsafe" ); 
                                return;
                            }
                            switch( root.* ){
                                inline else=>|unionObjWrapper|{
                                    if(comptime WorkItem.hasPtr( @TypeOf(unionObjWrapper)) ){
                                        if(unionObjWrapper)|unionObj| //in case unionObj is null
                                            try gc.state.stack.append(
                                                    gc.child_allocator,
                                                    mkWorkItem(unionObj)
                                                );
                                    }
                                }
                            }
                        },

                    }
                }
            }
        }.expand_fn
    };
}
fn packedTrace( gc:*GcAllocator , obj:anytype ) !void{ //obj is a packed struct or union
    switch(@typeInfo(@TypeOf(obj))){ 
        .@"struct"=>{
            for (@typeInfo(@TypeOf(obj) ).@"struct".field_names )|field|{
                const a = @field(obj , field);
                if( !WorkItem.hasPtr( @TypeOf(a))) continue;
                switch( @typeInfo( @TypeOf(a) ) ){
                    .pointer=>|p|{
                        if(p.size == .one ){
                            if(a)|ptr|{
                                if(gc.markSlot(ptr , .Black)) 
                                    try gc.state.stack.append(
                                        gc.child_allocator,
                                        mkWorkItem(ptr)
                                    );
                            }
                        }else if(p.size == .many){
                            if( std.meta.sential(@TypeOf(a)) != null){
                                    const span = std.mem.span( a );
                                    for( span )|sliceObjWrapper|{
                                        if(sliceObjWrapper) |sliceObj| //in case sliceObj is null
                                            if(gc.markSlot(sliceObj,.Black)) try gc.state.stack.append(
                                                gc.child_allocator,
                                                mkWorkItem(sliceObj)
                                            );
                                    }
                                }else if( !WorkItem.hasPtr( p.child ) ){ // [*]u8 [*]i32 or anything except a pointer
                                    _ = gc.markSlot( a , .Black );
                                }else{
                                    @compileError("many pointer without a sential value and contains a pointer is not supported");
                                }
                        }else @compileError("c pointers not yet surported");
                        //by the way should i just dont care on c pointers since that should be used only with c librarys
                    },  
                    .@"struct"=>{
                        try gc.packedTrace( obj );
                    },
                    .@"union"=>{
                        try gc.packedTrace( obj );
                    }
                }
            }
        }, 
        .@"union"=>{
            if( WorkItem.hasPtr(@TypeOf(obj)) ) @compileError( "untagged union with ptr is unsafe" );
        },
        else=>{
            @compileError("packedTrace is only made for packed struct / union");
        }   
    }
    
}

inline fn markSlot( gc:*GcAllocator , addr:*anyopaque , marking:GcAllocator.Mark) bool {
    if( gc.foundPage( addr ) )|page|{ 
        page.metaSlice()[(@intFromPtr(addr) - @intFromPtr(page) - page.data_offset) / page.slot_size].mark = marking;
        return true;
    }
    if( gc.state.options != .small ) {
        if( gc.foundLarge( addr ) )|large|{                            
            large.mark = marking;
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
    if( self.state.page_book.contains(  pagePtrInt) ) { 
        return pagePtr;
    }
    return null;
    
}
pub fn foundLarge( self:*GcAllocator , ptr:*anyopaque)?*LargeHeader  {
    //should call sort first , assume after key is sorted
    const keyList = self.state.large_book.keys();
    if( keyList.len == 0 ) return null;
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
    return null;
}
fn mark( gc:*GcAllocator, ptr:anytype )!void{
    try gc.state.stack.append( 
        gc.child_allocator,
        mkWorkItem( ptr )  
        );
    while( gc.state.stack.pop() )|workitem|{
        var item = workitem;
        try item.expand( gc ); 
    }   
}
pub fn manualGc( gc:*GcAllocator ) !void {
    
    if( gc.state.options != .small ) gc.large_book.sort( struct{
        key:[]const usize,
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.key[a_index] < ctx.key[b_index];
        }
    }{.key = gc.large_book.keys() } );

    var cursor = gc.state.stack_list orelse assert("where\'s your stack list?");
    gc.state.marked_book.clearRetainingCapacity(); // could have been 
    while(cursor) |frame|{
        try frame.trace(gc);
        cursor = frame.next;
    }
    if(gc.state.marked_book.size() > 65536 and gc.state.marked_book.capacity() > 8 * gc.state.marked_book.size()){
        try gc.state.marked_book.clearAndFree( gc.child_allocator );
        try gc.state.stack.clearAndFree(gc.child_allocator);
    }else{
        gc.state.marked_book.clearRetainingCapacity();
    }
    for( gc.state.used_pages.? )|*first|{
        var prev:?*Page = null;
        var cursur:?*Page = first.*;
        while(cursur)|*currentPage|{ 
            var deadPage = true;
            for( currentPage.metaSlice() )|*sliceObj|{
                if(sliceObj.age == 0) continue;
                if(sliceObj.mark == .White ) {
                    if( sliceObj.age < gc.state.age_threashold ){
                        gc.state.byte_allocated -= currentPage.slot_size;
                    }
                    sliceObj.age = 0;
                    var node : *Node = currentPage.sliceToNode(sliceObj);
                    if (gc.state.options == .debug ) {
                        const x: [*]Node = node;
                        @memset( x[0..currentPage.slot_size/@sizeOf(Node)] , .{.next=null}  );//set to zero
                    }
                    node.next = currentPage.free_list;
                    currentPage.free_list = node;    
                    continue;
                }
                deadPage = false;
                sliceObj = .{.White , sliceObj.age +| 1 };
                if( sliceObj.age == gc.state.age_threashold ) gc.state.byte_allocated -= currentPage.slot_size;
            }
            if(deadPage){
                if( prev )|prevPage|{ //not null
                    prevPage.next = currentPage.next;
                }else{
                    first = currentPage.next;
                }
                currentPage.next = gc.state.free_pages;
                gc.state.free_pages = currentPage;
            }
            prev = cursur;
            cursur = cursur.next;
        }
    }
}


