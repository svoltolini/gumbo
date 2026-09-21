// swift-tools-version: 6.2
import PackageDescription

// Kept separate and dynamic so LGPL-covered code is never absorbed into the app executable.
let package = Package(
    name: "GumboSMB",
    platforms: [.iOS("26.1"), .macOS("26.0"), .tvOS("26.0")],
    products: [.library(name: "GumboSMB", type: .dynamic, targets: ["CGumboSMB"])],
    targets: [.target(
        name: "CGumboSMB", path: "Sources/CGumboSMB",
        exclude: ["lib/CMakeLists.txt", "lib/Makefile.am", "lib/Makefile.AMIGA", "lib/Makefile.AMIGA_AROS",
                  "lib/Makefile.AMIGA_OS3", "lib/Makefile.PS3_PPU", "lib/libsmb2.syms",
                  "lib/libsmb2-dcerpc-full.syms", "lib/ps2", "lib/dreamcast"],
        sources: ["lib"], publicHeadersPath: "include",
        cSettings: [.headerSearchPath("include"), .headerSearchPath("include/apple"),
                    .headerSearchPath("include/smb2"), .headerSearchPath("lib"),
                    .define("_U_", to: "__attribute__((unused))"), .define("HAVE_CONFIG_H", to: "1")]
    )]
)
