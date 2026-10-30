const std = @import("std");

pub fn build(b: *std.Build) void {
    const native_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // Das Projekt baut ohne externes BKG-Framework-Paket. HTTP-Helfer,
    // Audioausgabe und die Kitten-ONNX-Engine liegen vollständig in src/.
    const server_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    server_module.link_libc = true;

    const server_exe = b.addExecutable(.{
        .name = "bkg-tts",
        .root_module = server_module,
    });
    b.installArtifact(server_exe);

    const run_cmd = b.addRunArtifact(server_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the native BKG TTS server").dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    test_module.link_libc = true;

    const unit_tests = b.addTest(.{
        .name = "bkg-tts-tests",
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run BKG TTS unit tests").dependOn(&run_tests.step);

    // Werkzeug zum Auslesen des Modellvertrags. Es gehoert nicht zum
    // Serverpfad und wird deshalb nicht installiert.
    const probe_module = b.createModule(.{
        .root_source_file = b.path("src/probe.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    probe_module.link_libc = true;
    const probe_exe = b.addExecutable(.{
        .name = "bkg-tts-probe",
        .root_module = probe_module,
    });
    const run_probe = b.addRunArtifact(probe_exe);
    if (b.args) |args| run_probe.addArgs(args);
    b.step("probe", "Print the runtime contract of an ONNX model").dependOn(&run_probe.step);

    // Browser WASM stays isolated from libc, sockets and libmagpie-tts.so.
    // React loads this freestanding module for deterministic client-side logic.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_exe = b.addExecutable(.{
        .name = "bkg-magpietts-wasm",
        .root_module = wasm_module,
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    b.step("wasm", "Build the freestanding browser WASM module").dependOn(&install_wasm.step);
}
