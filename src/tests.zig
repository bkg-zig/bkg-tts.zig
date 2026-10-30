//! Sammelpunkt der Tests.
//!
//! Die Testdateien liegen bei den Modulen, die sie pruefen. Damit die Tests
//! auch einzeln laufen koennen, ohne dass der Import aus dem Modulpfad
//! herausfuehrt, sammelt diese Datei sie ein.
const std = @import("std");

test {
    _ = @import("tts/descriptor.zig");
    _ = @import("tts/tokens.zig");
    _ = @import("tts/chunk.zig");
    _ = @import("tts/preprocess.zig");
    _ = @import("tts/unicode.zig");
    _ = @import("tts/unicode_word.zig");
    _ = @import("tts/espeak.zig");
    _ = @import("tts/voices.zig");
    _ = @import("engine/registry.zig");
    _ = @import("engine/phonemes.zig");
}
