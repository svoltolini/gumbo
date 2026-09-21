/* Copyright 2026 Samuel Voltolini. LGPL-2.1-or-later.
 * Exercise the actual public directory decoder with hostile bounds; no network. */
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include "config.h"
#include "compat.h"
#include "smb2.h"
#include "libsmb2.h"
#include "libsmb2-private.h"
#include "gumbo-smb-policy.h"

static int check(struct smb2_context *ctx, uint8_t *bytes, size_t length, int valid) {
    struct smb2_iovec vec = {.buf = bytes, .len = length};
    struct smb2_fileidfulldirectoryinformation result;
    memset(&result, 0xA5, sizeof(result));
    int status = smb2_decode_fileidfulldirectoryinformation(ctx, &result, &vec);
    int okay = valid ? status == 0 && result.name && strcmp(result.name, "A") == 0 : status != 0 && result.name == NULL;
    if (!okay) fprintf(stderr, "Decoder bounds failure length=%zu valid=%d status=%d\n", length, valid, status);
    if (status == 0) free((void *)result.name);
    return okay;
}
int main(void) {
    struct smb2_context *ctx = smb2_init_context();
    uint8_t bytes[176] = {0};
    struct smb2_iovec vec = {.buf = bytes, .len = sizeof(bytes)};
    smb2_set_uint32(&vec, 60, 2); bytes[80] = 'A';
    int okay = check(ctx, bytes, 82, 1);
    for (size_t length = 0; length < 82; length++) okay &= check(ctx, bytes, length, 0);
    smb2_set_uint32(&vec, 60, 1); okay &= check(ctx, bytes, 82, 0);
    smb2_set_uint32(&vec, 60, UINT32_MAX); okay &= check(ctx, bytes, 82, 0);
    smb2_set_uint32(&vec, 60, 0); okay &= check(ctx, bytes, 82, 0);
    smb2_set_uint32(&vec, 60, 2); bytes[80] = 0; okay &= check(ctx, bytes, 82, 0);
    bytes[80] = 'A';
    smb2_set_uint32(&vec, 0, 80); okay &= check(ctx, bytes, 176, 0); /* overlaps name */
    smb2_set_uint32(&vec, 0, 83); okay &= check(ctx, bytes, 176, 0); /* not aligned */
    smb2_set_uint32(&vec, 0, 176); okay &= check(ctx, bytes, 176, 0); /* absent next entry */
    smb2_set_uint32(&vec, 0, UINT32_MAX); okay &= check(ctx, bytes, 176, 0);
    smb2_set_uint32(&vec, 0, 88); okay &= check(ctx, bytes, 176, 1);
    okay &= gumbo_smb2_directory_budget(100000, 4096, 64ULL * 1024 * 1024, 59) == 0;
    okay &= gumbo_smb2_directory_budget(100001, 1, 82, 0) != 0;
    okay &= gumbo_smb2_directory_budget(1, 4097, 82, 0) != 0;
    okay &= gumbo_smb2_directory_budget(1, 1, 64ULL * 1024 * 1024 + 1, 0) != 0;
    okay &= gumbo_smb2_directory_budget(1, 1, 82, 60) != 0;
    smb2_destroy_context(ctx);
    puts(okay ? "PASS directory decoder and enumeration bounds" : "FAIL directory decoder and enumeration bounds");
    return okay ? 0 : 1;
}
