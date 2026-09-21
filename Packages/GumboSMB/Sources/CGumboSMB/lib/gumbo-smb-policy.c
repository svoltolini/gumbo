/* Modified for Gumbo on 2026-09-21: opt-in authenticated SMB policy and dynamic SwiftPM packaging.
 * See Packages/GumboSMB/NOTICE.md and gumbo-policy.patch for source and license details. */
/* Copyright 2026 Samuel Voltolini. LGPL-2.1-or-later. */
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include "smb2/smb2.h"
#include "gumbo-smb-policy.h"

int gumbo_smb2_validate_session(uint16_t flags)
{
    return (flags & (SMB2_SESSION_FLAG_IS_GUEST | SMB2_SESSION_FLAG_IS_NULL)) ? -EACCES : 0;
}

int gumbo_smb2_validate_packet(int encryption, int signing, uint16_t command,
                              int encrypted, uint32_t flags, uint32_t status)
{
    /* The session key is not available for NEGOTIATE or the initial SETUP.
     * Final SETUP authentication is enforced in session_setup_cb. */
    if (command == SMB2_NEGOTIATE || command == SMB2_SESSION_SETUP) return 0;
    if (encryption && !encrypted) return -EACCES;
    /* Interim STATUS_PENDING is not application data and may be unsigned.
     * Its eventual data/completion response must still authenticate. */
    if (signing && !encrypted && status != SMB2_STATUS_PENDING && !(flags & SMB2_FLAGS_SIGNED)) return -EACCES;
    return 0;
}

int gumbo_smb2_directory_budget(uint64_t entries, uint64_t pages, uint64_t bytes, uint64_t elapsed_seconds)
{
        return entries <= 100000 && pages <= 4096 && bytes <= 64ULL * 1024 * 1024 && elapsed_seconds < 60 ? 0 : -EOVERFLOW;
}
