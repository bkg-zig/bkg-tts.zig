//! Browser-side validation primitives consumed by the React client.
//! No operating-system, libc, network, or native TTS imports are allowed here.

const std = @import("std");

/// Returns a speaker slot for the stable Magpie voice order; 255 means invalid.
export fn bkg_magpie_voice_index(voice: u32) u32 {
    return if (voice < 5) voice else 255;
}

/// Returns true only for a sample rate supported by the server contract.
export fn bkg_magpie_sample_rate_allowed(rate: u32) bool {
    return switch (rate) {
        8000, 16000, 22050, 24000, 48000 => true,
        else => false,
    };
}

/// Max character count accepted by the current service contract.
export fn bkg_magpie_max_text_chars() u32 {
    return 5000;
}

/// Returns a stable contract version that the UI can compare before calling APIs.
export fn bkg_magpie_contract_version() u32 {
    return 1;
}

test "supported sample rates match the HTTP contract" {
    try std.testing.expect(bkg_magpie_sample_rate_allowed(22050));
    try std.testing.expect(bkg_magpie_sample_rate_allowed(48000));
    try std.testing.expect(!bkg_magpie_sample_rate_allowed(44100));
}

test "speaker index rejects unknown voices" {
    try std.testing.expectEqual(@as(u32, 0), bkg_magpie_voice_index(0));
    try std.testing.expectEqual(@as(u32, 4), bkg_magpie_voice_index(4));
    try std.testing.expectEqual(@as(u32, 255), bkg_magpie_voice_index(5));
}
