//! Minimal Objective-C runtime binding, no headers. Used by the iOS host to create UIKit
//! objects and to define delegate classes at runtime, so the iOS app needs no Swift or
//! Objective-C source.

pub const id = ?*opaque {};
pub const Class = ?*opaque {};
pub const SEL = ?*opaque {};
pub const Protocol = opaque {};

pub extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "objc" fn objc_getProtocol(name: [*:0]const u8) ?*Protocol;
pub extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
pub extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
pub extern "objc" fn objc_registerClassPair(cls: Class) void;
/// The BOOL results are one byte on every Apple ABI (bool on arm64, signed char on x86_64).
pub extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) u8;
pub extern "objc" fn class_addProtocol(cls: Class, protocol: *Protocol) u8;
extern "objc" fn objc_msgSend() void;
extern "objc" fn objc_msgSendSuper() void;
pub extern "objc" fn class_getSuperclass(cls: Class) Class;
pub extern "objc" fn object_getClass(obj: id) Class;

/// Adds a class method (to the metaclass) of a class defined with `defineClass`, e.g. +layerClass.
pub fn addClassMethod(class_name: [*:0]const u8, name: [*:0]const u8, imp: *const anyopaque, types: [*:0]const u8) void {
    _ = class_addMethod(object_getClass(@ptrCast(objc_getClass(class_name))), sel(name), imp, types);
}

/// CGFloat is a double on every 64-bit Apple platform.
pub const CGFloat = f64;
pub const CGPoint = extern struct { x: CGFloat, y: CGFloat };
pub const CGSize = extern struct { w: CGFloat, h: CGFloat };
pub const CGRect = extern struct { x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 0, h: CGFloat = 0 };
pub const UIEdgeInsets = extern struct { top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat };

/// The header of an Objective-C block (a closure), for APIs that only take a block, such as
/// NSURLSession's completion handler. Built as a "global" block, so the runtime never copies
/// or frees it: the owner frees it after its one call. Fields after the header are captures.
pub const BlockHeader = extern struct {
    isa: *const anyopaque,
    flags: i32 = block_is_global,
    reserved: i32 = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

pub const BlockDescriptor = extern struct { reserved: usize = 0, size: usize };

pub const block_is_global: i32 = 1 << 28;
pub extern "c" var _NSConcreteGlobalBlock: anyopaque;

/// `objc_msgSend` must be called through a pointer of the exact method signature.
pub fn msgSend(comptime Fn: type) Fn {
    return @ptrCast(&objc_msgSend);
}

pub const Super = extern struct { receiver: id, super_class: Class };

/// `[super name]` from a method of a class defined with `defineClass`.
pub fn sendSuper(obj: id, class_name: [*:0]const u8, name: [*:0]const u8) void {
    const s: Super = .{ .receiver = obj, .super_class = class_getSuperclass(objc_getClass(class_name)) };
    const f: *const fn (*const Super, SEL) callconv(.c) void = @ptrCast(&objc_msgSendSuper);
    f(&s, sel(name));
}

/// `[super name:a with:b]` with two object arguments.
pub fn sendSuper2(obj: id, class_name: [*:0]const u8, name: [*:0]const u8, a: id, b: id) void {
    const s: Super = .{ .receiver = obj, .super_class = class_getSuperclass(objc_getClass(class_name)) };
    const f: *const fn (*const Super, SEL, id, id) callconv(.c) void = @ptrCast(&objc_msgSendSuper);
    f(&s, sel(name), a, b);
}

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

pub fn class(name: [*:0]const u8) id {
    return @ptrCast(objc_getClass(name));
}

/// `[obj name]` returning an object.
pub fn send(obj: id, name: [*:0]const u8) id {
    return msgSend(*const fn (id, SEL) callconv(.c) id)(obj, sel(name));
}

/// `[obj name]` with no result.
pub fn sendVoid(obj: id, name: [*:0]const u8) void {
    msgSend(*const fn (id, SEL) callconv(.c) void)(obj, sel(name));
}

/// `[obj name:arg]` returning an object.
pub fn send1(obj: id, name: [*:0]const u8, arg: id) id {
    return msgSend(*const fn (id, SEL, id) callconv(.c) id)(obj, sel(name), arg);
}

/// `[obj name:arg]` with no result.
pub fn sendVoid1(obj: id, name: [*:0]const u8, arg: id) void {
    msgSend(*const fn (id, SEL, id) callconv(.c) void)(obj, sel(name), arg);
}

/// `[obj name:integer]` with no result (NSInteger arguments).
pub fn sendVoidInt(obj: id, name: [*:0]const u8, arg: isize) void {
    msgSend(*const fn (id, SEL, isize) callconv(.c) void)(obj, sel(name), arg);
}

/// `[obj name:number]` with no result (CGFloat arguments).
pub fn sendVoidFloat(obj: id, name: [*:0]const u8, arg: CGFloat) void {
    msgSend(*const fn (id, SEL, CGFloat) callconv(.c) void)(obj, sel(name), arg);
}

/// `[obj name:flag]` with no result (BOOL arguments).
pub fn sendVoidBool(obj: id, name: [*:0]const u8, arg: bool) void {
    msgSend(*const fn (id, SEL, bool) callconv(.c) void)(obj, sel(name), arg);
}

/// `[obj name]` returning an NSInteger.
pub fn sendInt(obj: id, name: [*:0]const u8) isize {
    return msgSend(*const fn (id, SEL) callconv(.c) isize)(obj, sel(name));
}

/// `[[cls alloc] init]`
pub fn new(class_name: [*:0]const u8) id {
    return send(send(class(class_name), "alloc"), "init");
}

/// NSUTF8StringEncoding
const utf8_encoding: usize = 4;

/// A +1 retained NSString with a copy of `s` (UTF-8, need not be null-terminated).
pub fn nsString(s: []const u8) id {
    const init = msgSend(*const fn (id, SEL, [*]const u8, usize, usize) callconv(.c) id);
    return init(send(class("NSString"), "alloc"), sel("initWithBytes:length:encoding:"), s.ptr, s.len, utf8_encoding);
}

pub fn release(obj: id) void {
    sendVoid(obj, "release");
}

/// Defines a class at runtime. `methods` are `.{ selector, implementation, type encoding }`.
pub fn defineClass(
    name: [*:0]const u8,
    superclass: [*:0]const u8,
    protocols: []const [*:0]const u8,
    methods: []const struct { [*:0]const u8, *const anyopaque, [*:0]const u8 },
) void {
    const cls = objc_allocateClassPair(objc_getClass(superclass), name, 0);
    for (protocols) |p| {
        if (objc_getProtocol(p)) |proto| _ = class_addProtocol(cls, proto);
    }
    for (methods) |m| _ = class_addMethod(cls, sel(m[0]), m[1], m[2]);
    objc_registerClassPair(cls);
}
