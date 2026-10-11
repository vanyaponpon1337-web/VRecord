"""Reject signed/encrypted/non-arm64 binaries and incomplete IPA app payloads."""
import pathlib
import plistlib
import struct
import sys

app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "com.vrecord.app"
assert info["MinimumOSVersion"] == "18.5"
assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"]
assert set(info["UISupportedInterfaceOrientations"]) == {
    "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"
}
for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSPhotoLibraryAddUsageDescription"]:
    assert info[key]
assert (app / "default.metallib").stat().st_size > 0
assert (app / "Assets.car").stat().st_size > 0
assert not (app / "_CodeSignature").exists()
assert not (app / "embedded.mobileprovision").exists()
binary = (app / info["CFBundleExecutable"]).read_bytes()
magic, cpu, _, _, count, _, _, _ = struct.unpack_from("<8I", binary)
assert magic == 0xFEEDFACF, "Expected thin 64-bit device Mach-O"
assert cpu == 0x0100000C, "Expected ARM64 CPU"
offset = 32
for _ in range(count):
    command, size = struct.unpack_from("<II", binary, offset)
    assert command != 0x1D, "LC_CODE_SIGNATURE is present"
    if command in (0x21, 0x2C):
        cryptid = struct.unpack_from("<I", binary, offset + 16)[0]
        assert cryptid == 0, "Encrypted executable"
    offset += size
print("Verified: physical iOS ARM64, iOS 18.5, original unencrypted executable, no code signature, Metal library, app assets, privacy keys.")
