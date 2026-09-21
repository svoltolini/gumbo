/* Copyright 2026 Samuel Voltolini. LGPL-2.1-or-later.
 * Exercise the actual SMB socket receive state machine without a NAS or credentials. */
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include "config.h"
#include "compat.h"
#include "smb2.h"
#include "libsmb2.h"
#include "libsmb2-private.h"
#include "aes128ccm.h"

struct result { int calls; int status; uint16_t command; char data[8]; };
static void callback(struct smb2_context *ctx, int status, void *payload, void *opaque) {
    struct result *r = opaque;
    r->calls++;
    r->status = status;
    if (!status && payload && r->command == SMB2_READ) {
        struct smb2_read_reply *reply = payload;
        if (reply->data_length == 4 && reply->data) memcpy(r->data, reply->data, 4);
    }
}
static void break_callback(struct smb2_context *ctx, int status,
                           struct smb2_oplock_or_lease_break_reply *reply,
                           uint8_t *level, uint32_t *state) {
    struct result *r = ctx->opaque;
    r->calls++;
    r->status = status;
    *level = 0;
    *state = 0;
}
static int scenario(const char *name, uint16_t expected_command, uint16_t wire_command,
                    int encryption_required, int sign, int encrypt, int tamper,
                    uint32_t status, int allow) {
    int fd[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fd)) abort();
    fcntl(fd[0], F_SETFL, O_NONBLOCK);
    struct smb2_context *ctx = smb2_init_context();
    ctx->fd = fd[0];
    ctx->sign = 1;
    ctx->dialect = SMB2_VERSION_0300;
    ctx->gumbo_require_authenticated = 1;
    ctx->gumbo_require_encryption = encryption_required;
    struct result result = {.command = expected_command};
    struct smb2_pdu *pdu = smb2_allocate_pdu(ctx, expected_command, callback, &result);
    pdu->header.message_id = 42;
    ctx->waitqueue = pdu;
    if (expected_command == SMB2_OPLOCK_BREAK) {
        ctx->waitqueue = NULL;
        smb2_free_pdu(ctx, pdu);
        pdu = NULL;
        ctx->opaque = &result;
        ctx->passthrough = 1;
        ctx->oplock_or_lease_break_cb = break_callback;
    }
    uint8_t bytes[256] = {0};
    size_t length = status == SMB2_STATUS_PENDING ? 68
        : expected_command == SMB2_NEGOTIATE ? 132
        : expected_command == SMB2_SESSION_SETUP ? 76
        : expected_command == SMB2_OPLOCK_BREAK ? 92 : 88;
    bytes[3] = (uint8_t)(length - 4);
    struct smb2_iovec header = {bytes + 4, 64, NULL};
    bytes[4] = 0xfe; bytes[5] = 'S'; bytes[6] = 'M'; bytes[7] = 'B';
    smb2_set_uint16(&header, 4, 64);
    smb2_set_uint16(&header, 12, wire_command);
    smb2_set_uint32(&header, 8, status);
    smb2_set_uint32(&header, 16, SMB2_FLAGS_SERVER_TO_REDIR | (sign ? SMB2_FLAGS_SIGNED : 0));
    smb2_set_uint64(&header, 24, expected_command == SMB2_OPLOCK_BREAK ? UINT64_MAX : 42);
    struct smb2_iovec body = {bytes + 68, length - 68, NULL};
    if (status != SMB2_STATUS_PENDING) {
        if (expected_command == SMB2_NEGOTIATE) {
            smb2_set_uint16(&body, 0, 65);
            smb2_set_uint16(&body, 4, SMB2_VERSION_0300);
        } else if (expected_command == SMB2_OPLOCK_BREAK) {
            smb2_set_uint16(&body, 0, 24);
        } else if (expected_command == SMB2_SESSION_SETUP) {
            smb2_set_uint16(&body, 0, 9);
        } else {
            smb2_set_uint16(&body, 0, 17);
            smb2_set_uint8(&body, 2, 80);
            smb2_set_uint32(&body, 4, 4);
            memcpy(bytes + 84, "TEST", 4);
        }
    }
    if (sign) {
        struct smb2_iovec message = {bytes + 4, length - 4, NULL};
        if (smb2_calc_signature(ctx, bytes + 4 + 48, &message, 1)) abort();
        if (tamper) bytes[4 + 48] ^= 0xff;
    }
    uint8_t encrypted[320] = {0};
    uint8_t *send_bytes = bytes;
    if (encrypt) {
        struct smb2_iovec transform = {encrypted + 4, 52, NULL};
        encrypted[4] = 0xfd; encrypted[5] = 'S'; encrypted[6] = 'M'; encrypted[7] = 'B';
        memset(encrypted + 4 + 20, 7, 11); /* fixed nonce is safe only for isolated fixture keys */
        smb2_set_uint32(&transform, 36, (uint32_t)(length - 4));
        smb2_set_uint16(&transform, 42, 1);
        memcpy(encrypted + 56, bytes + 4, length - 4);
        aes128ccm_encrypt(ctx->serverout_key, encrypted + 24, 11,
                          encrypted + 24, 32, encrypted + 56, length - 4,
                          encrypted + 8, 16);
        length += 52;
        encrypted[3] = (uint8_t)(length - 4);
        if (tamper) encrypted[8] ^= 0xff;
        send_bytes = encrypted;
    }
    if (write(fd[1], send_bytes, length) != (ssize_t)length) abort();
    int rc = smb2_service(ctx, POLLIN);
    int success = allow
        ? rc == 0 && (status == SMB2_STATUS_PENDING ? result.calls == 0 : result.calls == 1)
        : rc < 0 && result.calls == 0;
    if (allow && expected_command == SMB2_READ && !status) success &= !strcmp(result.data, "TEST");
    /* A rejected command mismatch must not parse/allocate its body first. */
    if (!allow && expected_command != wire_command) success &= pdu->payload == NULL;
    printf("%s: %s (rc=%d callbacks=%d data=%s error=%s)\n",
           success ? "PASS" : "FAIL", name, rc, result.calls, result.data, smb2_get_error(ctx));
    smb2_destroy_context(ctx);
    close(fd[1]);
    return !success;
}
int main(void) {
    int failed = 0;
    failed += scenario("unsigned READ labeled NEGOTIATE", SMB2_READ, SMB2_NEGOTIATE, 0, 0, 0, 0, 0, 0);
    failed += scenario("unsigned READ labeled SESSION_SETUP", SMB2_READ, SMB2_SESSION_SETUP, 0, 0, 0, 0, 0, 0);
    failed += scenario("plaintext READ labeled NEGOTIATE with encryption required", SMB2_READ, SMB2_NEGOTIATE, 1, 0, 0, 0, 0, 0);
    failed += scenario("plaintext READ labeled SESSION_SETUP with encryption required", SMB2_READ, SMB2_SESSION_SETUP, 1, 0, 0, 0, 0, 0);
    failed += scenario("authenticated but wrong response command", SMB2_READ, SMB2_SESSION_SETUP, 0, 1, 0, 0, 0, 0);
    failed += scenario("unsigned matching READ", SMB2_READ, SMB2_READ, 0, 0, 0, 0, 0, 0);
    failed += scenario("bad matching READ signature", SMB2_READ, SMB2_READ, 0, 1, 0, 1, 0, 0);
    failed += scenario("valid matching signed READ", SMB2_READ, SMB2_READ, 0, 1, 0, 0, 0, 1);
    failed += scenario("signed plaintext READ when encryption required", SMB2_READ, SMB2_READ, 1, 1, 0, 0, 0, 0);
    failed += scenario("valid encrypted READ", SMB2_READ, SMB2_READ, 1, 0, 1, 0, 0, 1);
    failed += scenario("invalid encryption tag", SMB2_READ, SMB2_READ, 1, 0, 1, 1, 0, 0);
    failed += scenario("encrypted command mismatch", SMB2_READ, SMB2_SESSION_SETUP, 1, 0, 1, 0, 0, 0);
    failed += scenario("plaintext PENDING when encryption required", SMB2_READ, SMB2_READ, 1, 0, 0, 0, SMB2_STATUS_PENDING, 0);
    failed += scenario("mismatched PENDING", SMB2_READ, SMB2_SESSION_SETUP, 0, 0, 0, 0, SMB2_STATUS_PENDING, 0);
    failed += scenario("valid unsigned PENDING for signed session", SMB2_READ, SMB2_READ, 0, 0, 0, 0, SMB2_STATUS_PENDING, 1);
    failed += scenario("valid encrypted PENDING", SMB2_READ, SMB2_READ, 1, 0, 1, 0, SMB2_STATUS_PENDING, 1);
    failed += scenario("matching login continuation before session key", SMB2_SESSION_SETUP, SMB2_SESSION_SETUP, 1, 0, 0, 0, SMB2_STATUS_MORE_PROCESSING_REQUIRED, 1);
    failed += scenario("matching negotiate before session key", SMB2_NEGOTIATE, SMB2_NEGOTIATE, 1, 0, 0, 0, 0, 1);
    failed += scenario("valid signed unsolicited oplock break", SMB2_OPLOCK_BREAK, SMB2_OPLOCK_BREAK, 0, 1, 0, 0, 0, 1);
    failed += scenario("valid encrypted unsolicited oplock break", SMB2_OPLOCK_BREAK, SMB2_OPLOCK_BREAK, 1, 0, 1, 0, 0, 1);
    failed += scenario("unsigned unsolicited oplock break", SMB2_OPLOCK_BREAK, SMB2_OPLOCK_BREAK, 0, 0, 0, 0, 0, 0);
    return failed ? 1 : 0;
}
