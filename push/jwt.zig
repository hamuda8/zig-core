//! Compact JSON Web Tokens signed with ES256 (VAPID, APNs) or RS256 (Google service accounts).

const std = @import("std");
const rsa = @import("rsa.zig");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const b64url = std.base64.url_safe_no_pad;

fn encode(gpa: std.mem.Allocator, header_json: []const u8, claims_json: []const u8) ![]u8 {
    const h_len = b64url.Encoder.calcSize(header_json.len);
    const c_len = b64url.Encoder.calcSize(claims_json.len);
    const out = try gpa.alloc(u8, h_len + 1 + c_len);
    _ = b64url.Encoder.encode(out[0..h_len], header_json);
    out[h_len] = '.';
    _ = b64url.Encoder.encode(out[h_len + 1 ..], claims_json);
    return out;
}

fn withSignature(gpa: std.mem.Allocator, signing_input: []const u8, sig: []const u8) ![]u8 {
    const s_len = b64url.Encoder.calcSize(sig.len);
    const out = try gpa.alloc(u8, signing_input.len + 1 + s_len);
    @memcpy(out[0..signing_input.len], signing_input);
    out[signing_input.len] = '.';
    _ = b64url.Encoder.encode(out[signing_input.len + 1 ..], sig);
    return out;
}

/// ES256 (P-256, SHA-256): the signature is r || s, 64 bytes.
pub fn es256(gpa: std.mem.Allocator, claims_json: []const u8, key: [32]u8) ![]u8 {
    return signEs256(gpa, "{\"typ\":\"JWT\",\"alg\":\"ES256\"}", claims_json, key);
}

/// ES256 with a key id in the header (APNs: the .p8 key's id).
pub fn es256WithKid(gpa: std.mem.Allocator, claims_json: []const u8, key: [32]u8, kid: []const u8) ![]u8 {
    const header = try std.fmt.allocPrint(gpa, "{{\"alg\":\"ES256\",\"kid\":{f}}}", .{std.json.fmt(kid, .{})});
    defer gpa.free(header);
    return signEs256(gpa, header, claims_json, key);
}

fn signEs256(gpa: std.mem.Allocator, header_json: []const u8, claims_json: []const u8, key: [32]u8) ![]u8 {
    const input = try encode(gpa, header_json, claims_json);
    defer gpa.free(input);
    const kp = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(key));
    const sig = try kp.sign(input, null);
    return withSignature(gpa, input, &sig.toBytes());
}

pub fn rs256(gpa: std.mem.Allocator, claims_json: []const u8, key: rsa.PrivateKey) ![]u8 {
    const input = try encode(gpa, "{\"alg\":\"RS256\",\"typ\":\"JWT\"}", claims_json);
    defer gpa.free(input);
    const sig = try key.signSha256(gpa, input);
    defer gpa.free(sig);
    return withSignature(gpa, input, sig);
}

/// Checks an ES256 token's signature (tests; servers that receive tokens).
pub fn verifyEs256(token: []const u8, public_key: EcdsaP256.PublicKey) !void {
    const dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return error.BadToken;
    var raw: [64]u8 = undefined;
    if ((b64url.Decoder.calcSizeForSlice(token[dot + 1 ..]) catch return error.BadToken) != 64) return error.BadToken;
    try b64url.Decoder.decode(&raw, token[dot + 1 ..]);
    try EcdsaP256.Signature.fromBytes(raw).verify(token[0..dot], public_key);
}

/// The 32-byte private key inside an APNs .p8 file (PEM PKCS#8 of an EC P-256 key).
pub fn p8PrivateKey(gpa: std.mem.Allocator, pem: []const u8) ![32]u8 {
    const der = try rsa.pemBody(gpa, pem);
    defer gpa.free(der);
    // PKCS#8: the ECPrivateKey's privateKey is the one 32-byte OCTET STRING (04 20 ...) inside.
    var i: usize = 0;
    while (i + 34 <= der.len) : (i += 1) {
        // version INTEGER 1 (02 01 01), then the key (04 20 ...).
        if (der[i] == 0x04 and der[i + 1] == 0x20 and i >= 3 and der[i - 3] == 0x02 and der[i - 2] == 0x01 and der[i - 1] == 0x01) {
            var key: [32]u8 = undefined;
            @memcpy(&key, der[i + 2 ..][0..32]);
            return key;
        }
    }
    return error.BadKey;
}

test es256 {
    const kp = try EcdsaP256.KeyPair.generateDeterministic(@splat(3));
    const token = try es256WithKid(std.testing.allocator, "{\"iss\":\"TEAM\",\"iat\":1}", kp.secret_key.toBytes(), "KEYID");
    defer std.testing.allocator.free(token);
    try verifyEs256(token, kp.public_key);
    // The header names the key.
    var header: [64]u8 = undefined;
    const dot = std.mem.indexOfScalar(u8, token, '.').?;
    const n = try b64url.Decoder.calcSizeForSlice(token[0..dot]);
    try b64url.Decoder.decode(header[0..n], token[0..dot]);
    try std.testing.expectEqualStrings("{\"alg\":\"ES256\",\"kid\":\"KEYID\"}", header[0..n]);
}

test p8PrivateKey {
    // A throwaway key made with `openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256`,
    // laid out like Apple's .p8 files (PKCS#8 with the public key inside).
    const pem =
        \\-----BEGIN PRIVATE KEY-----
        \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgr6M8rNgfivNdbkPB
        \\BN74rINR8070VBpqqJtMg1BRYc2hRANCAAT9mzlgrjiZdsHmByUr86Y+8uL2ZIwC
        \\deQKoaQuQuKpX15j2EZrnRKlth40NBhoBze/V+lHZDE4S7hczt5ihUjc
        \\-----END PRIVATE KEY-----
    ;
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "afa33cacd81f8af35d6e43c104def8ac8351f34ef4541a6aa89b4c83505161cd");
    try std.testing.expectEqualSlices(u8, &want, &try p8PrivateKey(std.testing.allocator, pem));
}
