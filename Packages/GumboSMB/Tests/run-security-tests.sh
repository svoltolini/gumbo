#!/bin/sh
# Native macOS socket regression. No network access, NAS or user credentials.
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=${1:-$(mktemp -d "${TMPDIR:-/tmp}/gumbo-smb-security.XXXXXX")}
swift build --package-path "$package_dir" --scratch-path "$build_dir"
bin_dir=$(swift build --package-path "$package_dir" --scratch-path "$build_dir" --show-bin-path)

# Check the actual dynamic product, not only a configure macro. The old Apple
# configuration linked random/srandom and returned -1 despite successful I/O.
xcrun nm -u "$bin_dir/libGumboSMB.dylib" > "$build_dir/entropy-imports.txt"
grep -Eq '(^|[[:space:]])_arc4random_buf$' "$build_dir/entropy-imports.txt"
if grep -Eq '(^|[[:space:]])_(srandom|random)$' "$build_dir/entropy-imports.txt"; then
  echo 'FAIL: predictable RNG remains linked in the Apple product' >&2
  exit 1
fi
for variant in actual intercepted; do
  # The actual variant links the shipped dynamic library. The intercepted
  # variant compiles the same production init/seal source with test-only symbol
  # substitutions, proving calls use the selected source without dyld overrides.
  set --
  if [ "$variant" = intercepted ]; then
    set -- -DGUMBO_TEST_INTERPOSE_ENTROPY=1 -DHAVE_CONFIG_H=1 \
      '-D_U_=__attribute__((unused))' -Darc4random_buf=fixture_arc4random_buf \
      -Drandom=forbidden_random -Dsrandom=forbidden_srandom \
      "$package_dir/Sources/CGumboSMB/lib/init.c" \
      "$package_dir/Sources/CGumboSMB/lib/smb3-seal.c"
  fi
  clang -Wall -Wextra -Werror -Wno-unused-parameter "$@" \
    -I "$package_dir/Sources/CGumboSMB/include" \
    -I "$package_dir/Sources/CGumboSMB/include/apple" \
    -I "$package_dir/Sources/CGumboSMB/include/smb2" \
    -I "$package_dir/Sources/CGumboSMB/lib" \
    "$package_dir/Tests/entropy-security.c" \
    -L "$bin_dir" -Wl,-rpath,"$bin_dir" -lGumboSMB \
    -o "$build_dir/entropy-$variant"
  "$build_dir/entropy-$variant"
done

# Regression for stale/generated configs: even without the feature macro,
# __APPLE__ must select the CSPRNG and compile out both legacy RNG references.
mkdir -p "$build_dir/config-without-entropy-feature"
sed '/^#define HAVE_ARC4RANDOM_BUF /d' \
  "$package_dir/Sources/CGumboSMB/include/apple/config.h" \
  > "$build_dir/config-without-entropy-feature/config.h"
clang -DHAVE_CONFIG_H=1 '-D_U_=__attribute__((unused))' \
  -I "$build_dir/config-without-entropy-feature" \
  -I "$package_dir/Sources/CGumboSMB/include" \
  -I "$package_dir/Sources/CGumboSMB/include/smb2" \
  -I "$package_dir/Sources/CGumboSMB/lib" \
  -c "$package_dir/Sources/CGumboSMB/lib/init.c" -o "$build_dir/init-without-feature.o"
xcrun nm -u "$build_dir/init-without-feature.o" > "$build_dir/entropy-without-feature-imports.txt"
grep -Eq '(^|[[:space:]])_arc4random_buf$' "$build_dir/entropy-without-feature-imports.txt"
if grep -Eq '(^|[[:space:]])_(srandom|random)$' "$build_dir/entropy-without-feature-imports.txt"; then
  echo 'FAIL: stale Apple config re-enabled the predictable RNG' >&2
  exit 1
fi
echo 'PASS missing Apple entropy feature macro cannot enable a weak fallback'

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
