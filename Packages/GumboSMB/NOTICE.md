# GumboSMB notices and source

Gumbo uses **libsmb2**, copyright Ronnie Sahlberg and the contributors credited in each source file. The SMB library is licensed under **GNU LGPL 2.1 or later**. Its DCE/RPC code and headers are under the **BSD 2-Clause License**; the complete notices remain in those source files. No examples are included in the package.

- Upstream: https://github.com/sahlberg/libsmb2
- Exact source revision: `557e837d3e00636b543f17ba1b9bdf872fa1644d`
- Full library source used here: `Sources/CGumboSMB/`
- Full license: `LICENCE-LGPL-2.1.txt`; component overview: `COPYING`
- Gumbo's changes: `gumbo-policy.patch`, dated 2026-09-21. The added policy/receive-validation/directory-bounds C source and changes to LGPL files are LGPL-2.1-or-later. The package/module packaging is also supplied for rebuilding.
- Public release source: https://github.com/svoltolini/gumbo/tree/main/Packages/GumboSMB

The package is an explicitly **dynamic** library. It must remain a separate library/framework in distributed applications. Preserve this notice, the license and per-file copyright notices, provide the corresponding modified source/build inputs, and retain the LGPL permissions to modify the library and reverse engineer the combined work for debugging modifications. The dynamic-link mechanism must support the applicable LGPL section 6 conditions; Apple signing, distribution terms and installation restrictions need release-specific verification. A successful build does not establish App Store approval or resolve every distribution obligation. Do not replace this product with static linkage without arranging and verifying an appropriate relinking route.

## Rebuilding the library

The modified source and all of its C build inputs are in this directory; no binary-only SMB dependency is fetched. From the repository root, `swift build --package-path Packages/GumboSMB -c release` rebuilds the Mac dynamic library with the installed compatible Swift toolchain. `Packages/GumboSMB/Tests/run-security-tests.sh` exercises its receive and directory regressions. The main Xcode schemes `Gumbo`, `GumboMac` and `GumboTV` build the same source into a separate framework for their respective SDKs; `project.yml` and `Packages/GumboCore/Package.swift` describe the integration. For example, `xcodebuild -project Gumbo.xcodeproj -scheme Gumbo -configuration Release -destination 'generic/platform=iOS' build` builds the iOS integration, using the developer's own valid signing setup. watchOS does not build or link this library.

Apple application signatures cover the embedded framework. Replacing the library in a signed app therefore requires a valid re-signing and installation route for that platform; a modified framework must not simply be copied into a still-signed distribution package. Verify and preserve the user's applicable LGPL modification/relinking permissions when choosing the release's signing and distribution terms.

The required BSD binary notice follows (also retained in each DCE/RPC source):

Copyright (C) 2018 by Ronnie Sahlberg <ronniesahlberg@gmail.com>

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
