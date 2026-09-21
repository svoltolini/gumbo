#!/usr/bin/env python3
"""Build an isolated native UI fixture from a completed GumboMac Debug build.

Accepts a derived-data directory, never a NAS address or user music path. Generated
audio goes only inside the new fixture bundle; runtime writes stay in its sandbox.
"""
import argparse
import plistlib
import shutil
import subprocess
from pathlib import Path

import imageio_ffmpeg


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("derived_data", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--album-deletion", action="store_true", help="Open the production album and deletion review instead of the genre editor")
    args = parser.parse_args()
    derived = args.derived_data.resolve()
    output = args.output.resolve()
    if output.exists():
        raise SystemExit("Choose a new output folder; this tool never deletes an existing fixture.")
    output.mkdir(parents=True)
    repo = Path(__file__).resolve().parents[2]
    products = derived / "Build/Products/Debug"
    app = output / "GumboGenreWriteFixture.app"
    contents = app / "Contents"
    binary = contents / "MacOS/GumboGenreWriteFixture"
    binary.parent.mkdir(parents=True)
    resources = contents / "Resources"
    originals = resources / "FixtureMusic"
    originals.mkdir(parents=True)
    for extension, codec in (("mp3", "libmp3lame"), ("flac", "flac"), ("m4a", "aac")):
        command = [imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                   "anoisesrc=color=pink:sample_rate=44100:amplitude=0.01:duration=5:seed=1729", "-ac", "2", "-c:a", codec,
                   "-metadata", "title=Generated test audio", "-metadata", "artist=Gumbo fixture",
                   "-metadata", "album=Generated fixture album", "-metadata", "album_artist=Gumbo fixture",
                   "-metadata", "genre=Ambient", "-metadata", "comment=Preserve this unrelated tag"]
        if extension != "flac":
            command += ["-b:a", "192k"]
        subprocess.run(command + [str(originals / ("generated." + extension))], check=True)
    frameworks = contents / "Frameworks"
    frameworks.mkdir()
    shutil.copytree(products / "PackageFrameworks/GumboSMB.framework", frameworks / "GumboSMB.framework", symlinks=True)
    shutil.copytree(products / "GumboCore_GumboCore.bundle", resources / "GumboCore_GumboCore.bundle")
    source_objects = derived / "Build/Intermediates.noindex/Gumbo.build/Debug/GumboMac.build/Objects-normal/arm64/Gumbo.LinkFileList"
    objects = [line for line in source_objects.read_text().splitlines() if not line.endswith("/GumboMacApp.o")]
    filelist = output / "objects.txt"
    filelist.write_text("\n".join(objects) + "\n")
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-enable-upcoming-feature", "InferIsolatedConformances",
                    "-target", "arm64-apple-macos26.0", "-I", str(products), "-F", str(products / "PackageFrameworks"),
                    "-Xcc", "-I" + str(repo / "Packages/GumboSMB/Sources/CGumboSMB/include"),
                    "-Xcc", "-fmodule-map-file=" + str(repo / "Packages/GumboSMB/Sources/CGumboSMB/include/module.modulemap"),
                    str(Path(__file__).with_name("GenreSaveFixture.swift")), "-Xlinker", "-filelist", "-Xlinker", str(filelist),
                    "-framework", "GumboSMB", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-o", str(binary)], check=True)
    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "com.samuelvoltolini.gumbo.genre-write-fixture", "CFBundleName": "Gumbo Genre Write Fixture",
                       "CFBundleExecutable": binary.name, "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                       "LSMinimumSystemVersion": "26.0", "NSHighResolutionCapable": True,
                       "GumboFixtureAlbumMode": args.album_deletion}, handle)
    entitlements = output / "fixture.entitlements"
    with entitlements.open("wb") as handle:
        plistlib.dump({"com.apple.security.app-sandbox": True}, handle)
    subprocess.run(["codesign", "--force", "--sign", "-", str(frameworks / "GumboSMB.framework")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
