// One-off generator: node gen_jni.js <slots.txt> > zig-core/zui/platform/jni.zig
const slots = require('fs').readFileSync(process.argv[2], 'utf8').trim().split(/\r?\n/);
const A = '[*]const jvalue';
const T = {
  GetVersion: 'fn (*Env) callconv(.c) jint',
  FindClass: 'fn (*Env, [*:0]const u8) callconv(.c) jclass',
  Throw: 'fn (*Env, jthrowable) callconv(.c) jint',
  ExceptionOccurred: 'fn (*Env) callconv(.c) jthrowable',
  ExceptionDescribe: 'fn (*Env) callconv(.c) void',
  ExceptionClear: 'fn (*Env) callconv(.c) void',
  PushLocalFrame: 'fn (*Env, jint) callconv(.c) jint',
  PopLocalFrame: 'fn (*Env, jobject) callconv(.c) jobject',
  NewGlobalRef: 'fn (*Env, jobject) callconv(.c) jobject',
  DeleteGlobalRef: 'fn (*Env, jobject) callconv(.c) void',
  DeleteLocalRef: 'fn (*Env, jobject) callconv(.c) void',
  IsSameObject: 'fn (*Env, jobject, jobject) callconv(.c) jboolean',
  NewObjectA: `fn (*Env, jclass, jmethodID, ${A}) callconv(.c) jobject`,
  GetObjectClass: 'fn (*Env, jobject) callconv(.c) jclass',
  IsInstanceOf: 'fn (*Env, jobject, jclass) callconv(.c) jboolean',
  GetMethodID: 'fn (*Env, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID',
  CallObjectMethodA: `fn (*Env, jobject, jmethodID, ${A}) callconv(.c) jobject`,
  CallBooleanMethodA: `fn (*Env, jobject, jmethodID, ${A}) callconv(.c) jboolean`,
  CallIntMethodA: `fn (*Env, jobject, jmethodID, ${A}) callconv(.c) jint`,
  CallLongMethodA: `fn (*Env, jobject, jmethodID, ${A}) callconv(.c) jlong`,
  CallFloatMethodA: `fn (*Env, jobject, jmethodID, ${A}) callconv(.c) jfloat`,
  CallDoubleMethodA: `fn (*Env, jobject, jmethodID, ${A}) callconv(.c) jdouble`,
  CallVoidMethodA: `fn (*Env, jobject, jmethodID, ${A}) callconv(.c) void`,
  GetFieldID: 'fn (*Env, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jfieldID',
  GetObjectField: 'fn (*Env, jobject, jfieldID) callconv(.c) jobject',
  GetIntField: 'fn (*Env, jobject, jfieldID) callconv(.c) jint',
  GetStaticMethodID: 'fn (*Env, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID',
  CallStaticObjectMethodA: `fn (*Env, jclass, jmethodID, ${A}) callconv(.c) jobject`,
  CallStaticIntMethodA: `fn (*Env, jclass, jmethodID, ${A}) callconv(.c) jint`,
  CallStaticLongMethodA: `fn (*Env, jclass, jmethodID, ${A}) callconv(.c) jlong`,
  CallStaticVoidMethodA: `fn (*Env, jclass, jmethodID, ${A}) callconv(.c) void`,
  GetStaticFieldID: 'fn (*Env, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jfieldID',
  GetStaticObjectField: 'fn (*Env, jclass, jfieldID) callconv(.c) jobject',
  GetStaticIntField: 'fn (*Env, jclass, jfieldID) callconv(.c) jint',
  NewString: 'fn (*Env, [*]const jchar, jsize) callconv(.c) jstring',
  NewStringUTF: 'fn (*Env, [*:0]const u8) callconv(.c) jstring',
  GetStringLength: 'fn (*Env, jstring) callconv(.c) jsize',
  GetStringRegion: 'fn (*Env, jstring, jsize, jsize, [*]jchar) callconv(.c) void',
  GetStringUTFLength: 'fn (*Env, jstring) callconv(.c) jsize',
  GetStringUTFChars: 'fn (*Env, jstring, ?*jboolean) callconv(.c) ?[*:0]const u8',
  ReleaseStringUTFChars: 'fn (*Env, jstring, [*:0]const u8) callconv(.c) void',
  GetArrayLength: 'fn (*Env, jobject) callconv(.c) jsize',
  NewByteArray: 'fn (*Env, jsize) callconv(.c) jobject',
  GetByteArrayRegion: 'fn (*Env, jobject, jsize, jsize, [*]u8) callconv(.c) void',
  SetByteArrayRegion: 'fn (*Env, jobject, jsize, jsize, [*]const u8) callconv(.c) void',
  NewFloatArray: 'fn (*Env, jsize) callconv(.c) jobject',
  SetFloatArrayRegion: 'fn (*Env, jobject, jsize, jsize, [*]const f32) callconv(.c) void',
  RegisterNatives: 'fn (*Env, jclass, [*]const NativeMethod, jint) callconv(.c) jint',
  GetJavaVM: 'fn (*Env, **VM) callconv(.c) jint',
  ExceptionCheck: 'fn (*Env) callconv(.c) jboolean',
  NewDirectByteBuffer: 'fn (*Env, *anyopaque, jlong) callconv(.c) jobject',
  GetDirectBufferAddress: 'fn (*Env, jobject) callconv(.c) ?*anyopaque',
};
const out = [];
out.push(`//! Hand-written JNI binding, no C headers.
//! The slot order of \`Functions\` matches \`struct JNINativeInterface\` in the NDK's jni.h
//! (${slots.length} slots, NDK r30). Slots zui does not call yet are opaque pointers so every
//! index stays exact; give a slot a real signature when it is first needed.

pub const jboolean = u8;
pub const jbyte = i8;
pub const jchar = u16;
pub const jshort = i16;
pub const jint = i32;
pub const jlong = i64;
pub const jfloat = f32;
pub const jdouble = f64;
pub const jsize = jint;

pub const jobject = ?*opaque {};
pub const jclass = jobject;
pub const jstring = jobject;
pub const jthrowable = jobject;
pub const jmethodID = ?*opaque {};
pub const jfieldID = ?*opaque {};

pub const JNI_TRUE: jboolean = 1;
pub const JNI_FALSE: jboolean = 0;
pub const JNI_OK: jint = 0;
pub const JNI_VERSION_1_6: jint = 0x00010006;

pub const jvalue = extern union {
    z: jboolean,
    b: jbyte,
    c: jchar,
    s: jshort,
    i: jint,
    j: jlong,
    f: jfloat,
    d: jdouble,
    l: jobject,
};

pub const NativeMethod = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    fnPtr: *const anyopaque,
};

/// \`JNIEnv\`: a pointer to the function table.
pub const Env = extern struct {
    functions: *const Functions,
};

/// \`JavaVM\`.
pub const VM = extern struct {
    functions: *const InvokeFunctions,
};

pub const InvokeFunctions = extern struct {
    reserved0: ?*const anyopaque,
    reserved1: ?*const anyopaque,
    reserved2: ?*const anyopaque,
    DestroyJavaVM: *const fn (*VM) callconv(.c) jint,
    AttachCurrentThread: *const fn (*VM, **Env, ?*anyopaque) callconv(.c) jint,
    DetachCurrentThread: *const fn (*VM) callconv(.c) jint,
    GetEnv: *const fn (*VM, **Env, jint) callconv(.c) jint,
    AttachCurrentThreadAsDaemon: *const fn (*VM, **Env, ?*anyopaque) callconv(.c) jint,
};

pub const Functions = extern struct {`);
for (const s of slots) out.push(T[s] ? `    ${s}: *const ${T[s]},` : `    ${s}: ?*const anyopaque,`);
out.push(`};

comptime {
    if (@sizeOf(Functions) != ${slots.length} * @sizeOf(usize)) @compileError("JNI table size mismatch");
}`);
const missing = Object.keys(T).filter(k => !slots.includes(k));
if (missing.length) { console.error('unknown slots: ' + missing); process.exit(1); }
process.stdout.write(out.join('\n') + '\n');
