//! Browser-side validation primitives consumed by the React client.
//! No operating-system, libc, network, or native TTS imports are allowed here.
//!
//! The module carries only the limits that are fixed by the server contract.
//! Voices, languages, models and their sample rates come from the HTTP API,
//! because they depend on the loaded model.

const std = @import("std");
const limits = @import("limits.zig");

/// Version of the browser contract. The client refuses older or newer values.
pub const contract_version: u32 = 1;

/// Highest number of characters the HTTP endpoints accept.
pub const max_text_chars: u32 = @intCast(limits.max_text_chars);

/// Lowest tempo the HTTP endpoints accept.
pub const min_speed: f32 = limits.min_speed;

/// Highest tempo the HTTP endpoints accept.
pub const max_speed: f32 = limits.max_speed;

/// Lowest tempo a realtime session accepts.
pub const realtime_min_speed: f32 = limits.realtime_min_speed;

/// Highest tempo a realtime session accepts.
pub const realtime_max_speed: f32 = limits.realtime_max_speed;

/// Returns the contract version that the UI compares before calling APIs.
export fn bkg_tts_contract_version() u32 {
    return contract_version;
}

/// Returns the character limit of the HTTP endpoints.
export fn bkg_tts_max_text_chars() u32 {
    return max_text_chars;
}

/// Returns the lowest tempo of the HTTP endpoints.
export fn bkg_tts_min_speed() f32 {
    return min_speed;
}

/// Returns the highest tempo of the HTTP endpoints.
export fn bkg_tts_max_speed() f32 {
    return max_speed;
}

/// Returns the lowest tempo of a realtime session.
export fn bkg_tts_realtime_min_speed() f32 {
    return realtime_min_speed;
}

/// Returns the highest tempo of a realtime session.
export fn bkg_tts_realtime_max_speed() f32 {
    return realtime_max_speed;
}

/// Returns true when the tempo lies in the range of the HTTP endpoints.
export fn bkg_tts_speed_allowed(speed: f32) bool {
    return limits.speedAllowed(speed);
}

/// Returns true when the tempo lies in the range of a realtime session.
export fn bkg_tts_realtime_speed_allowed(speed: f32) bool {
    return limits.realtimeSpeedAllowed(speed);
}

test "the tempo limits match the HTTP contract" {
    try std.testing.expect(bkg_tts_speed_allowed(0.25));
    try std.testing.expect(bkg_tts_speed_allowed(4.0));
    try std.testing.expect(!bkg_tts_speed_allowed(0.24));
    try std.testing.expect(!bkg_tts_speed_allowed(4.01));
}

test "the tempo limits match the realtime contract" {
    try std.testing.expect(bkg_tts_realtime_speed_allowed(0.5));
    try std.testing.expect(bkg_tts_realtime_speed_allowed(2.0));
    try std.testing.expect(!bkg_tts_realtime_speed_allowed(0.49));
    try std.testing.expect(!bkg_tts_realtime_speed_allowed(2.01));
}

test "the character limit stays at the value of the HTTP contract" {
    try std.testing.expectEqual(@as(u32, 5000), bkg_tts_max_text_chars());
    try std.testing.expectEqual(@as(u32, 1), bkg_tts_contract_version());
}
