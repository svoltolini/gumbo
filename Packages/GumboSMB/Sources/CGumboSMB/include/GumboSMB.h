/* Modified for Gumbo on 2026-09-21: opt-in authenticated SMB policy and dynamic SwiftPM packaging.
 * See Packages/GumboSMB/NOTICE.md and gumbo-policy.patch for source and license details. */
#include <stdint.h>
#include <time.h>
#include <stddef.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include "gumbo-smb-policy.h"
