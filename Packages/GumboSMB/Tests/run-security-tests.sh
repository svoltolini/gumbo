#!/bin/sh
# Native macOS socket regression. No network access, NAS or user credentials.
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=${1:-$(mktemp -d "${TMPDIR:-/tmp}/gumbo-smb-security.XXXXXX")}
swift build --package-path "$package_dir" --scratch-path "$build_dir"
bin_dir=$(swift build --package-path "$package_dir" --scratch-path "$build_dir" --show-bin-path)
clang -Wall -Wextra -Werror -Wno-unused-parameter \
  -I "$package_dir/Sources/CGumboSMB/include" \
  -I "$package_dir/Sources/CGumboSMB/include/apple" \
  -I "$package_dir/Sources/CGumboSMB/include/smb2" \
  -I "$package_dir/Sources/CGumboSMB/lib" \
  "$package_dir/Tests/receive-security.c" \
  -L "$bin_dir" -Wl,-rpath,"$bin_dir" -lGumboSMB \
  -o "$build_dir/receive-security"
"$build_dir/receive-security"
clang -Wall -Wextra -Werror -Wno-unused-parameter \
  -I "$package_dir/Sources/CGumboSMB/include" \
  -I "$package_dir/Sources/CGumboSMB/include/apple" \
  -I "$package_dir/Sources/CGumboSMB/include/smb2" \
  -I "$package_dir/Sources/CGumboSMB/lib" \
  "$package_dir/Tests/directory-security.c" \
  -L "$bin_dir" -Wl,-rpath,"$bin_dir" -lGumboSMB \
  -o "$build_dir/directory-security"
"$build_dir/directory-security"
clang -Wall -Wextra -Werror -Wno-unused-parameter \
  -I "$package_dir/Sources/CGumboSMB/include" \
  -I "$package_dir/Sources/CGumboSMB/include/apple" \
  -I "$package_dir/Sources/CGumboSMB/include/smb2" \
  "$package_dir/Tests/context-lifecycle.c" \
  -L "$bin_dir" -Wl,-rpath,"$bin_dir" -lGumboSMB \
  -o "$build_dir/context-lifecycle"
"$build_dir/context-lifecycle"
