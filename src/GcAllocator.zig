//! GcAllocator implemention
//! not support: save ptr in usize / union(not tagged) / *anyopaque 
//! maybe will only save what's in *anyopaque , any ptr inside usize / untagged union will be dropped

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;

const AllocatorOptions = struct {
    ///options: standard , small , threadsafe(TODO) , debug
    ///standard:can alloc with obj over 4096 bytes, not threadsafe
    ///small:for fast alloc and gc with no obj over 4096 bytes , not threadsafe
    ///threadsafe:for multi threads , still working on
    ///debug: for debug , don't use unless debugging
    options: modeOptions = .standard,
    ///trigger gc if young gen is bigger than this number(byte)
    gc_threashold:usize = 1024*1024,
    ///if a obj is older than >= this number, it won't be count in gc_threashold
    age_threashold:u7 = 10,
    ///size of every page , power of two only
    page_size:u16 = 4096 ,
    ///size of classes in BiBoP , should be power of twos only, sort in ascending
    ///smallest 8 , largest is recommand smaller than page_size/2
    size_classes:[]const u16 = &.{ 16,32,64,128,256,512,1024 },
};

const modeOptions=enum{
    ///not threadsafe , can alloc any size of obj.
    standard,
    /// TODO , add some locks and use some atomic actions.
    threadsafe,
    ///no alloc object > page_size bytes
    small,
    ///debug only
    debug,
};

pub fn init( child_allocator:Allocator , comptime Gcoptions :AllocatorOptions)mkGcAllocator(Gcoptions) {
    return .{ .child_allocator=child_allocator , .state=.{}};
}
fn mkGcAllocator( comptime Gcoptions:AllocatorOptions ) type {
    comptime{
        assert( Gcoptions.age_threashold < std.math.maxInt(u7) );
        assert( std.math.isPowerOfTwo(Gcoptions.page_size));
        var prev = 0;
        for( Gcoptions.size_classes )|cursur|{
            assert( cursur > prev );
            prev = cursur;
            assert( std.math.isPowerOfTwo(cursur));
        }
    }
    const LargeBook = if (Gcoptions.options == .small) void else std.AutoArrayHashMapUnmanaged(usize, void);

    return struct {
        const GcAllocator = @This();
        child_allocator : Allocator,
        state:State,

const State = struct {
    const options = Gcoptions.options;
    const gc_threashold = Gcoptions.gc_threashold;
    const age_threashold = Gcoptions.age_threashold;
    const page_size = Gcoptions.page_size;
    const size_classes = Gcoptions.size_classes;
    //for gc
    stack_list:?*Frame = null,
    byte_allocated:usize = 0,
    marked_book: std.AutoHashMapUnmanaged( struct{usize , usize} , void ) = .{},
    stack: std.ArrayList(WorkItem) = .empty,
    //for pagesAllocator
    page_book: std.AutoArrayHashMapUnmanaged(usize, void)=.{} ,
    free_pages: ?*Page = null,
    used_pages: [Gcoptions.size_classes.len]?*Page = @splat(null),
    //large obj
    large_book:LargeBook = .{},
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
const Page = struct{
    ///size of every slot
    slot_size: u16,
    cap: u16,
    ///pointer offset from Page to first element
    data_offset: u32,
    free_list: ?*Node,
    next: ?*Page,
    pub fn metaSlice( self:*Page ) []Slot {
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
    pub fn allocatedSliceUnsafe(self:*Page) []u8{
        return @as([*]u8 , @ptrCast(self))[0..(self.slot_size*self.cap + self.data_offset )]; // i dont wanna use gc , or gc.page_size will be faster
    }

    pub fn initPage( page:*Page , slot_size:u16 )*Page{
        const page_size = State.page_size;
        page.free_list = null;
        page.next = null;
        page.slot_size = slot_size;

        page.cap = @intCast(( page_size - @sizeOf(Page)) / (@sizeOf(Slot) + slot_size));
        assert(page.cap > 0); //structure : page , metaSlice , padding(to slot_size) , slots
        page.data_offset = @intCast(std.mem.alignForward(usize, @intFromPtr(page) + @sizeOf(Page) + @sizeOf(Slot) * page.cap , slot_size) - @intFromPtr(page));
        var first = @intFromPtr(page) + page.data_offset ;
        var prev:?*Node = null;
        for( 0..page.cap )|_|{
            page.free_list = @ptrFromInt(first);
            page.free_list.?.next = prev;
            first += slot_size ;
            prev = page.free_list ;
        }
        @memset( page.metaSlice() , .{.mark = .White , .age = 0} );
        return page;
    }
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
    len: u50,     // total 7 byte
    align_log2:u6,
    slot: Slot = .{.mark=.White , .age = 1}, // 1 byte
    pub fn allocatedSliceUnsafe( self:*LargeHeader )[]u8{
        var ptr = @intFromPtr(self);
        if( self.align_log2 > 3 ) //need padding
            ptr -= @as(usize , 1 ) << self.align_log2 ;
        const start:[*]u8 = @ptrFromInt(ptr);
        return start[0..(self.len + @max( self.align_log2 , @sizeOf(LargeHeader)))];
    }
};
///Mark for gc
const Mark = enum(u1){ 
    ///not marked
    White,
    ///marked 
    Black,
};
///default usage: const gc = GcAllocator.init( std.heap.PageAllocator , .{});
///default size class : { 16,32,64,128,256,512,1024 }, manual size class should be power of two, bigger than 8;
///if wanna use multi threads: .{ .option=threadsafe }
///recommend to read source code yourself.


pub fn deinit(gc:*GcAllocator)void{
    for( gc.state.page_book.keys() )|pageInt|{ //free all pages
        const page :*Page = @ptrFromInt(pageInt);
        gc.child_allocator.rawFree(page.allocatedSliceUnsafe(), comptime @fromBackingInt(std.math.log2(State.page_size))  ,@returnAddress() );
    }
    for(gc.state.large_book.keys())|largeInt|{
        const large:*LargeHeader = @ptrFromInt(largeInt);
        gc.child_allocator.rawFree(large.allocatedSliceUnsafe(), @fromBackingInt( large.align_log2 )  ,@returnAddress() );
    }
    gc.state.stack.clearAndFree(gc.child_allocator);
    gc.state.page_book.clearAndFree(gc.child_allocator);
    gc.state.large_book.clearAndFree(gc.child_allocator);
    gc.state.marked_book.clearAndFree(gc.child_allocator);

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
/// return a frame variable , user should use getFrame(.{&a , &b});
/// to open a stack list , used for mark-sweeping
/// to register , use gc.new( &frame ); defer gc.delete(&frame);
pub fn getFrame(_ : *GcAllocator , root:anytype ) mkFrame(@TypeOf(root)) {
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
    if(gc.state.stack_list)|stack_head|{
        frame_ptr.frame.next = stack_head;
        stack_head.prev = &frame_ptr.frame;
    }
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
            .@"struct" => |s| inline for(s.field_types) |f|{
                if(WorkItem.hasPtr(f)) break true;
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
                const rootType = @TypeOf(ptr) ;//*struct
                const childType = @typeInfo(rootType).pointer.child;//struct
                if( comptime !WorkItem.hasPtr(childType) ) return;
                const root: rootType = @ptrCast(@constCast(@alignCast(self.ptr)));
                const childTypeInfo = @typeInfo(childType);
                if( !(try gc.state.marked_book.getOrPut(gc.child_allocator , .{ @intFromPtr(root),typeId(rootType)}) ).found_existing  ) {
                    switch( childTypeInfo ){ // ensure this ptr,type is not already marked
                        .pointer =>{  
                            if( childTypeInfo.pointer.size == .one  ){
                                if( @typeInfo(childTypeInfo.pointer.child) != .optional  ){ // in case sliceObj is null
                                    if( gc.markSlot( root.* ,.Black ) ) try gc.state.stack.append(
                                        gc.child_allocator,
                                        mkWorkItem( root.* )
                                    );
                                }else if(root.*)|opt|{
                                    if( gc.markSlot( opt ,.Black ) ) try gc.state.stack.append(
                                        gc.child_allocator,
                                        mkWorkItem( opt )
                                    );
                                }
                                    //i am thinking that if a struct is a large obj, 
                                    //and a stack pointer point to a little part of that,
                                    //it'll end up saving all part of the struct.
                                    //but i guess that can be fixed with coping gc, which is not my goal

                            }else if(childTypeInfo.pointer.size == .slice ){
                                for( root.* )| sliceObj |{
                                    if( @typeInfo(childTypeInfo.pointer.child) != .optional  ){ // in case sliceObj is null
                                        if( gc.markSlot( sliceObj ,.Black ) ) try gc.state.stack.append(
                                                gc.child_allocator,
                                                mkWorkItem( sliceObj )    
                                            );
                                    }else if(sliceObj)|opt|{
                                        if( gc.markSlot( opt ,.Black ) ) try gc.state.stack.append(
                                            gc.child_allocator,
                                            mkWorkItem( opt )
                                        );
                                    }
                                }
                            }else if(childTypeInfo.pointer.size == .many){
                                if( std.meta.sential(childType) != null){
                                    const span = std.mem.span( root.* );
                                    for( span )|sliceObj|{
                                        if(@typeInfo(childTypeInfo.pointer.child) != .optional){ //in case sliceObj is null
                                            if(gc.markSlot(sliceObj,.Black)) try gc.state.stack.append(
                                                gc.child_allocator,
                                                mkWorkItem(sliceObj)
                                            );
                                        }else if(sliceObj)|opt|{
                                            if(gc.markSlot(opt,.Black)) try gc.state.stack.append(
                                                gc.child_allocator,
                                                mkWorkItem(opt)
                                            );
                                        }
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
                            inline for( childTypeInfo.@"struct".field_names ,0..)|field , idx|{
                                if( comptime WorkItem.hasPtr( childTypeInfo.@"struct".field_types[idx] )){//in case is null
                                    if(@typeInfo(childTypeInfo.@"struct".field_types[idx] ) != .optional ) {
                                        try gc.state.stack.append(
                                            gc.child_allocator,
                                            mkWorkItem(@field( root.* , field ))
                                        );
                                    }else if(@field( root.* , field ))|opt|{
                                        try gc.state.stack.append(
                                            gc.child_allocator,
                                            mkWorkItem(opt)
                                        );
                                    }
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
                                inline else=>|unionObj|{
                                    if(comptime WorkItem.hasPtr( @TypeOf(unionObj)) ){
                                        if(@typeInfo(@TypeOf(unionObj)) != .optional or unionObj!=null) //in case unionObj is null
                                            try gc.state.stack.append(
                                                    gc.child_allocator,
                                                    mkWorkItem(unionObj)
                                                );
                                    }
                                }
                            }
                        },
                        else =>{unreachable;}
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
    if( State.options != .small ) {
        if( gc.foundLarge( addr ) )|large|{                            
            large.mark = marking;
            return true;
        }
    }
    return false;            
}
pub fn foundPage(self:*GcAllocator , ptr:*anyopaque ) ?*Page{
    const ptrInt = @intFromPtr( ptr);
    const pagePtrInt = ptrInt & ~( State.page_size - 1 );
    
    if(pagePtrInt == 0 ) return null;
    const pagePtr:*Page = @ptrFromInt( pagePtrInt );
    if( self.state.page_book.contains( pagePtrInt ) ) { 
        return pagePtr;
    }
    return null;
    
}
pub fn foundLarge( self:*GcAllocator , ptr:*anyopaque)?*LargeHeader{
    if( self.state.large_book.contains(@intFromPtr(ptr) - @sizeOf( LargeHeader))) return @ptrFromInt( @intFromPtr(ptr) - @sizeOf(LargeHeader) );
    //this part should call sort first , assume after key is sorted
    //upperboud is for checking slices, since a pointer might point to middle of a slice
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
    
    if( State.options != .small ) gc.state.large_book.sort( struct{
        key:[]const usize,
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.key[a_index] < ctx.key[b_index];
        }
    }{.key = gc.state.large_book.keys() } );
    assert(gc.state.stack_list != null); // where's your stack list
    var cursor = gc.state.stack_list ;
    gc.state.marked_book.clearRetainingCapacity(); // could have been 
    while(cursor) |frame|{
        try frame.trace(gc);
        cursor = frame.next;
    }
    if(gc.state.marked_book.size > 65536 and gc.state.marked_book.capacity() > 8 * gc.state.marked_book.size){
        gc.state.marked_book.clearAndFree( gc.child_allocator );
        gc.state.stack.clearAndFree(gc.child_allocator);
    }else{
        gc.state.marked_book.clearRetainingCapacity();
    }
    for( &gc.state.used_pages )|*first|{
        var prev:?*Page = null;
        var cursur:?*Page = first.*;
        while(cursur)|currentPage|{
            var deadPage = true;
            for( currentPage.metaSlice() )|*sliceObj|{
                if(sliceObj.age == 0) continue;
                if(sliceObj.mark == .White ) {
                    if( sliceObj.age < State.age_threashold ){
                        gc.state.byte_allocated -= currentPage.slot_size;
                    }
                    sliceObj.age = 0;
                    var node : *Node = currentPage.slotToNode(sliceObj);
                    if (State.options == .debug ) {
                        const x: [*]Node = @ptrCast(node);
                        @memset( x[0..currentPage.slot_size/@sizeOf(Node)] , .{.next=null}  );//set to zero
                    }
                    node.next = currentPage.free_list;
                    currentPage.free_list = node;    
                    continue;
                }
                deadPage = false;
                sliceObj.* = .{.mark = .White , .age = sliceObj.age +| 1 };
                if( sliceObj.age == State.age_threashold ) gc.state.byte_allocated -= currentPage.slot_size;
            }
            if(deadPage){
                if( prev )|prevPage|{ //not null
                    prevPage.next = currentPage.next;
                }else{
                    first.* = currentPage.next;
                }
                currentPage.next = gc.state.free_pages;
                gc.state.free_pages = currentPage;
            }
            prev = cursur;
            cursur = cursur.?.next;
        }
    }
    if(comptime State.options != .small ){
        var i = gc.state.large_book.count();
        while( i > 0 ){
            i-=1;

            const large:*LargeHeader = @ptrFromInt(gc.state.large_book.keys()[i]);
            if(large.slot.mark == .White){
                if( large.slot.age <  State.age_threashold) gc.state.byte_allocated -= large.len;
                gc.state.large_book.swapRemoveAt(i);
                gc.child_allocator.rawFree(
                    large.allocatedSliceUnsafe(),
                    @fromBackingInt(large.align_log2),
                    @returnAddress()
                );
            }else{
                large.slot = .{.mark = .White ,.age = large.slot.age +| 1};
                if( large.slot.age == State.age_threashold ) gc.state.byte_allocated -= large.len;
            }
        }
    }
}

fn free( ctx:*anyopaque , memory:[]u8 , alignment:Alignment , ret_addr:usize ) void{
    const gc:*GcAllocator = @ptrCast( @alignCast(ctx));
    _ = alignment;
    _ = ret_addr;
    assert(memory.len > 0);
    if(gc.foundPage( memory.ptr ))|page|{
        const slot = page.ptrToSlot( memory.ptr );
        if(slot.age < State.age_threashold ){
            gc.state.byte_allocated -= page.slot_size;
        }
        slot.age = 0;
        const node = @as(*Node , @ptrCast(@alignCast(memory.ptr)));
        node.next = page.free_list;
        page.free_list = node;
    }
    if( State.options != .small and gc.state.large_book.contains( @intFromPtr(memory.ptr) - @sizeOf(LargeHeader) )){
        const head:*LargeHeader = @ptrFromInt( @intFromPtr(memory.ptr) - @sizeOf(LargeHeader) );
        _ = gc.state.large_book.swapRemove( @intFromPtr(head) );
        gc.child_allocator.rawFree(
            head.allocatedSliceUnsafe(),
            @fromBackingInt(head.align_log2),
            @returnAddress()
        );
    }
}

fn resize( ctx:*anyopaque , memory:[]u8 , alignment:Alignment , new_len:usize , ret_addr:usize ) bool{
    const gc:*GcAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;
    assert(memory.len > 0);
    assert( new_len > 0 ); 
    if(gc.foundPage(memory.ptr))|page| return new_len <= page.slot_size ;
    if( new_len < memory.len ) return true;
    return false; //large obj can only shrink
}

fn remap(ctx:*anyopaque , memory:[]u8 , alignment:Alignment , new_len:usize , ret_addr:usize ) ?[*]u8{
    return if(resize(ctx, memory, alignment, new_len ,ret_addr))memory.ptr else null;
}

fn alloc( ctx:*anyopaque , n:usize , alignment:Alignment , ret_addr:usize ) ?[*]u8 {
    const gc:*GcAllocator = @ptrCast( @alignCast(ctx));
    _ = ret_addr;
    assert( n > 0 );
    if( gc.state.byte_allocated >= State.gc_threashold ){
        gc.manualGc() catch {};
    }
    const alignBytes = alignment.toByteUnits();
    const biggestSize = State.size_classes[State.size_classes.len - 1 ];
    if( @max(n ,  alignBytes) > biggestSize ){//align want more bytes than biggest size class
        if(State.options != .small ) return gc.allocLarge( n , alignment );
        return null;
    }
    return gc.allocPage( n , alignment );
}
fn allocLarge( gc:*GcAllocator , n:usize , alignment:Alignment ) ?[*]u8{
    const alignBytes = @max(alignment.toByteUnits() , @sizeOf(LargeHeader));//size of largeheader is 8
    var header:*LargeHeader= @alignCast(@ptrCast( gc.child_allocator.rawAlloc( n+alignBytes , alignment , @returnAddress()) orelse return null )) ;
    header = @as(*LargeHeader ,(@ptrFromInt(@intFromPtr(header) + alignBytes - @sizeOf(LargeHeader))));
    header.* = .{ .len = @intCast(n) , .align_log2 = @intCast(@backingInt(alignment)) , .slot = .{ .mark = .White , .age = 0 }  };
    gc.state.byte_allocated += n;
    return @ptrFromInt( @intFromPtr( header ) + @sizeOf(LargeHeader));
}
fn allocPage( gc:*GcAllocator , n:usize , alignment:Alignment ) ?[*]u8{
    const alignBytes = alignment.toByteUnits();
    const choosedClass = @max( alignBytes , n );
    const idx = idxInit:{
        for( State.size_classes , 0.. )| class, idx|{
            if(class >= choosedClass){
                break :idxInit idx;
            }
        }
        unreachable;
    };
    gc.state.byte_allocated += State.size_classes[idx];
    var cursur = gc.state.used_pages[idx];
    while( cursur )|currentPage| : (cursur = currentPage.next){
        if(currentPage.free_list)|freePtr|{
            currentPage.free_list = freePtr.next;
            return @ptrCast(@alignCast(freePtr));
        }
    }
    //no free space , alloc new page or get page from free pages
    if( gc.state.free_pages )|page|{
        gc.state.free_pages = page.next;
        const prev = gc.state.used_pages[idx];
        gc.state.used_pages[idx] = page.initPage( State.size_classes[idx] );
        gc.state.used_pages[idx] = prev;
        return gc.allocPage( n , alignment );
    }

    const tmp = gc.state.used_pages[idx];
    gc.state.used_pages[idx] = gc.newPage() orelse return null;
    _ = gc.state.used_pages[idx].?.initPage( State.size_classes[idx] );
    gc.state.used_pages[idx].?.next = tmp;
    //register everytime a page is allocated
    gc.state.page_book.put( gc.child_allocator , @intFromPtr(gc.state.used_pages[idx]) , {}  ) catch {};
    return gc.allocPage( n , alignment );
}
fn newPage( gc:*GcAllocator )?*Page{
    const pageSize = State.page_size;
    const alignment = Alignment.fromByteUnits( pageSize );
    return @ptrCast(@alignCast( gc.child_allocator.rawAlloc( pageSize , alignment , @returnAddress() )));
} 

    };
}
