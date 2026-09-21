/* Copyright 2026 Samuel Voltolini. LGPL-2.1-or-later.
 * No network, keys, or credentials. The intercepted variant verifies routing,
 * not entropy quality; it is never linked into the product. */
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include "config.h"
#include "compat.h"
#include "smb2.h"
#include "libsmb2.h"
#include "libsmb2-private.h"
#include "smb3-seal.h"

#ifdef GUMBO_TEST_INTERPOSE_ENTROPY
static size_t calls;
static size_t lengths[8];
void fixture_arc4random_buf(void *bytes, size_t length)
{
    assert(calls < sizeof(lengths) / sizeof(lengths[0]));
    lengths[calls++] = length;
    memset(bytes, (int)(0x40 + calls), length);
}
long forbidden_random(void) { abort(); }
void forbidden_srandom(unsigned seed) { (void)seed; abort(); }
static void expect_pattern(const void *bytes, size_t length, uint8_t pattern)
{
    const uint8_t *p = bytes;
    for (size_t i = 0; i < length; i++) assert(p[i] == pattern);
}
#endif

int main(void)
{
    uint8_t bytes[32] = {0};
    assert(smb2_random_bytes(bytes, sizeof(bytes)) == 0);
#ifdef GUMBO_TEST_INTERPOSE_ENTROPY
    assert(calls == 1 && lengths[0] == sizeof(bytes));
    expect_pattern(bytes, sizeof(bytes), 0x41);
    calls = 0;
#else
    /* An ordinary runtime control, not a statistical certification. */
    uint8_t second[32] = {0};
    assert(smb2_random_bytes(second, sizeof(second)) == 0);
    assert(memcmp(bytes, second, sizeof(bytes)) != 0);
#endif
    struct smb2_context *ctx = smb2_init_context();
    assert(ctx);
#ifdef GUMBO_TEST_INTERPOSE_ENTROPY
    assert(calls == 3);
    assert(lengths[0] == sizeof(ctx->client_challenge));
    assert(lengths[1] == sizeof(ctx->salt));
    assert(lengths[2] == sizeof(ctx->client_guid));
    expect_pattern(ctx->client_challenge, sizeof(ctx->client_challenge), 0x41);
    expect_pattern(ctx->salt, sizeof(ctx->salt), 0x42);
    expect_pattern(ctx->client_guid, sizeof(ctx->client_guid), 0x43);
    calls = 0;
#endif
    struct smb2_pdu pdu = {0};
    ctx->seal = 1;
    pdu.seal = 1;
    assert(smb3_encrypt_pdu(ctx, &pdu) == 0);
    assert(pdu.crypt && pdu.crypt_len == 52);
#ifdef GUMBO_TEST_INTERPOSE_ENTROPY
    assert(calls == 1 && lengths[0] == 11);
    expect_pattern(pdu.crypt + 20, 11, 0x41);
#endif
    free(pdu.crypt);
    smb2_destroy_context(ctx);
#ifdef GUMBO_TEST_INTERPOSE_ENTROPY
    puts("PASS production-source Apple CSPRNG routing: helper, context challenge/salt/GUID, CCM nonce; legacy RNG traps unused");
#else
    puts("PASS actual platform entropy result and encrypted-PDU construction");
#endif
    return 0;
}
