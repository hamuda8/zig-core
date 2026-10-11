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

/// `objc_msgSend` must be called through a pointer of the exact method signature.
pub fn msgSend(comptime Fn: type) Fn {
    return @ptrCast(&objc_msgSend);
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
