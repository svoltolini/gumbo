/* Modified for Gumbo on 2026-09-21: opt-in authenticated SMB policy and dynamic SwiftPM packaging.
 * See Packages/GumboSMB/NOTICE.md and gumbo-policy.patch for source and license details. */
/* Gumbo policy additions, Copyright 2026 Samuel Voltolini. LGPL-2.1-or-later.
 * These checks supplement the pinned upstream signature/AEAD validation. */
#ifndef GUMBO_SMB_POLICY_H
#define GUMBO_SMB_POLICY_H
#include <stdint.h>
struct smb2_context;
void gumbo_smb2_require_secure_session(struct smb2_context *context, int require_encryption);
void gumbo_smb2_set_cancellation(struct smb2_context *context, int (*callback)(void *), void *data);
int gumbo_smb2_directory_budget(uint64_t entries, uint64_t pages, uint64_t bytes, uint64_t elapsed_seconds);
int gumbo_smb2_validate_session(uint16_t session_flags);
int gumbo_smb2_validate_packet(int require_encryption, int require_signing,
                              uint16_t command, int encrypted, uint32_t flags, uint32_t status);
#endif
