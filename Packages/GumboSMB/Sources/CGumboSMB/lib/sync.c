/* Modified for Gumbo on 2026-09-21: protected read handle for verified download resume.
 * See Packages/GumboSMB/NOTICE.md and gumbo-policy.patch for source/license details. */
/* -*-  mode:c; tab-width:8; c-basic-offset:8; indent-tabs-mode:nil;  -*- */
/*
   Copyright (C) 2016 by Ronnie Sahlberg <ronniesahlberg@gmail.com>

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU Lesser General Public License as published by
   the Free Software Foundation; either version 2.1 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public License
   along with this program; if not, see <http://www.gnu.org/licenses/>.
*/
#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#ifdef HAVE_STDINT_H
#include <stdint.h>
#endif

#ifdef HAVE_STDLIB_H
#include <stdlib.h>
#endif

#include <errno.h>

#ifdef HAVE_SYS_POLL_H
#include <sys/poll.h>
#endif

#ifdef HAVE_POLL_H
#include <poll.h>
#endif

#ifdef HAVE_STRING_H
#include <string.h>
#endif

#include "compat.h"

#ifdef HAVE_TIME_H
#include <time.h>
#endif

#ifdef HAVE_SYS_TIME_H
#include <sys/time.h>
#endif

#include <stdio.h>

#include "smb2.h"
#include "libsmb2.h"
#include "libsmb2-raw.h"
#include "libsmb2-private.h"

static int wait_for_reply(struct smb2_context *smb2,
                          struct sync_cb_data *cb_data)
{
        time_t t = time(NULL);

        while (!cb_data->is_finished) {
		struct pollfd pfd;
		memset(&pfd, 0, sizeof(struct pollfd));
		pfd.fd = smb2_get_fd(smb2);
		pfd.events = smb2_which_events(smb2);

		if (poll(&pfd, 1, 1000) < 0) {
			smb2_set_error(smb2, "Poll failed");
			return -1;
		}
                if (smb2->timeout) {
                        smb2_timeout_pdus(smb2);
                }
		if (!SMB2_VALID_SOCKET(smb2->fd) && ((time(NULL) - t) > (smb2->timeout)))
		{
			smb2_set_error(smb2, "Timeout expired and no connection exists\n");
			return -1;
		}
                if (pfd.revents == 0) {
                        continue;
                }
		if (smb2_service(smb2, pfd.revents) < 0) {
			smb2_set_error(smb2, "smb2_service failed with : "
                                        "%s\n", smb2_get_error(smb2));
                        return -1;
		}
	}

        return 0;
}

static void sync_connect_cb(struct smb2_context *smb2, int status,
                       void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;

        if (cb_data->status == SMB2_STATUS_CANCELLED) {
                if (cb_data != &smb2->connect_cb_data) {
                        free(cb_data);
                }
                return;
        }

        cb_data->is_finished = 1;
        cb_data->status = status;
}

/*
 * Connect to the server and mount the share.
 */
int smb2_connect_share(struct smb2_context *smb2,
                       const char *server,
                       const char *share,
                       const char *user)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = &smb2->connect_cb_data;
	rc = smb2_connect_share_async(smb2, server, share, user, sync_connect_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:

	return rc;
}

/*
 * Disconnect from share
 */
int smb2_disconnect_share(struct smb2_context *smb2)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = &smb2->connect_cb_data;

	rc = smb2_disconnect_share_async(smb2, sync_connect_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:

	return rc;
}

/*
 * opendir()
 */
static void sync_opendir_cb(struct smb2_context *smb2, int status,
                       void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;

        if (status == SMB2_STATUS_SHUTDOWN) {
                return;
        }
        if (status) {
                cb_data->status = status;
        }
        cb_data->is_finished = 1;
        cb_data->ptr = command_data;
}

struct smb2dir *smb2_opendir(struct smb2_context *smb2, const char *path)
{
        struct smb2_pdu *pdu;
        struct sync_cb_data *cb_data;
        struct smb2dir *dir;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return NULL;
        }

	pdu = smb2_opendir_async_pdu(smb2, path, sync_opendir_cb, cb_data, NULL);
        if (pdu == NULL) {
		smb2_set_error(smb2, "smb2_opendir_async failed");
                free(cb_data);
		return NULL;
	}

	if (wait_for_reply(smb2, cb_data) < 0) {
                free(cb_data);
                smb2_free_pdu(smb2, pdu);
                return NULL;
        }

	dir = cb_data->ptr;
        if (dir) {
                /* Give ownership of cb_data to dir. It will be freed when dir is freed */
                dir->free_cb_data = free;
        } else {
                free(cb_data);
        }
        smb2_free_pdu(smb2, pdu);
        return dir;
}

/*
 * open()
 */
static void sync_open_cb(struct smb2_context *smb2, int status,
                    void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;

        cb_data->is_finished = 1;
        cb_data->ptr = command_data;
}

struct smb2fh *gumbo_smb2_open_read_snapshot(struct smb2_context *smb2, const char *path)
{
        struct smb2fh *result;
        /* The caller serializes this context. Keep the flag set throughout any callbacks. */
        smb2->gumbo_read_snapshot = 1;
        result = smb2_open(smb2, path, 0);
        smb2->gumbo_read_snapshot = 0;
        return result;
}

struct smb2fh *gumbo_smb2_open_delete_snapshot(struct smb2_context *smb2, const char *path)
{
        struct smb2fh *result;
        smb2->gumbo_read_snapshot = 2;
        result = smb2_open(smb2, path, 0);
        smb2->gumbo_read_snapshot = 0;
        return result;
}

static void gumbo_delete_cb(struct smb2_context *smb2, int status,
                            void *command_data, void *private_data)
{
        struct sync_cb_data *data = private_data;
        if (data->status == SMB2_STATUS_CANCELLED) {
                free(data);
                return;
        }
        data->status = status == SMB2_STATUS_SHUTDOWN ? -ECONNRESET : -nterror_to_errno(status);
        data->is_finished = 1;
}

int gumbo_smb2_mark_delete(struct smb2_context *smb2, struct smb2fh *file)
{
        struct smb2_set_info_request req;
        struct smb2_file_disposition_info disposition = { 1 };
        struct sync_cb_data *data;
        struct smb2_pdu *pdu;
        int result;
        if (!smb2 || !file) return -EINVAL;
        data = calloc(1, sizeof(*data));
        if (!data) return -ENOMEM;
        memset(&req, 0, sizeof(req));
        req.info_type = SMB2_0_INFO_FILE;
        req.file_info_class = SMB2_FILE_DISPOSITION_INFORMATION;
        memcpy(req.file_id, smb2_get_file_id(file), SMB2_FD_SIZE);
        req.input_data = &disposition;
        pdu = smb2_cmd_set_info_async(smb2, &req, gumbo_delete_cb, data);
        if (!pdu) { free(data); return -ENOMEM; }
        smb2_queue_pdu(smb2, pdu);
        result = wait_for_reply(smb2, data);
        if (result < 0) {
                if (data->is_finished) { free(data); return result; }
                /* A later reply/context teardown owns the callback state. Never retry a delete. */
                data->status = SMB2_STATUS_CANCELLED;
                return result;
        }
        result = data->status;
        free(data);
        return result;
}

struct smb2fh *smb2_open(struct smb2_context *smb2, const char *path, int flags)
{
        struct smb2_pdu *pdu;
        struct sync_cb_data *cb_data;
        void *ptr;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return NULL;
        }

	pdu = smb2_open_async_pdu(smb2, path, flags, sync_open_cb, cb_data, NULL);
        if (pdu == NULL) {
		smb2_set_error(smb2, "smb2_open_async failed");
                free(cb_data);
		return NULL;
	}

	if (wait_for_reply(smb2, cb_data) < 0) {
                smb2_free_pdu(smb2, pdu);
                free(cb_data);
                return NULL;
        }

	ptr = cb_data->ptr;
        smb2_free_pdu(smb2, pdu);
        free(cb_data);
        return ptr;
}

/*
 * close()
 */
static void sync_close_cb(struct smb2_context *smb2, int status,
                    void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;

        if (status == SMB2_STATUS_SHUTDOWN) {
                return;
        }
        if (cb_data->status == SMB2_STATUS_CANCELLED) {
                free(cb_data);
                return;
        }

        cb_data->is_finished = 1;
        cb_data->status = status;
}

int smb2_close(struct smb2_context *smb2, struct smb2fh *fh)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_close_async(smb2, fh, sync_close_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                goto out;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

/*
 * fsync()
 */
static void sync_fsync_cb(struct smb2_context *smb2, int status,
                     void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;

        if (cb_data->status == SMB2_STATUS_CANCELLED) {
                free(cb_data);
                return;
        }

        cb_data->is_finished = 1;
        cb_data->status = status;
}

int smb2_fsync(struct smb2_context *smb2, struct smb2fh *fh)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_fsync_async(smb2, fh, sync_fsync_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

/*
 * pread()
 */
static void sync_generic_status_cb(struct smb2_context *smb2, int status,
                    void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;

        if (cb_data->status == SMB2_STATUS_CANCELLED) {
                free(cb_data);
                return;
        }

        cb_data->is_finished = 1;
        cb_data->status = status;
}

int smb2_pread(struct smb2_context *smb2, struct smb2fh *fh,
               uint8_t *buf, uint32_t count, uint64_t offset)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_pread_async(smb2, fh, buf, count, offset,
                              sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_pwrite(struct smb2_context *smb2, struct smb2fh *fh,
                const uint8_t *buf, uint32_t count, uint64_t offset)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_pwrite_async(smb2, fh, buf, count, offset,
                               sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

        rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_read(struct smb2_context *smb2, struct smb2fh *fh,
              uint8_t *buf, uint32_t count)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_read_async(smb2, fh, buf, count,
                             sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

        rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_write(struct smb2_context *smb2, struct smb2fh *fh,
               const uint8_t *buf, uint32_t count)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_write_async(smb2, fh, buf, count,
                              sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_unlink(struct smb2_context *smb2, const char *path)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_unlink_async(smb2, path,
                               sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_rmdir(struct smb2_context *smb2, const char *path)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_rmdir_async(smb2, path,
                              sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_mkdir(struct smb2_context *smb2, const char *path)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_mkdir_async(smb2, path,
                              sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_fstat(struct smb2_context *smb2, struct smb2fh *fh,
               struct smb2_stat_64 *st)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_fstat_async(smb2, fh, st,
                              sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_stat(struct smb2_context *smb2, const char *path,
              struct smb2_stat_64 *st)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_stat_async(smb2, path, st,
                             sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_rename(struct smb2_context *smb2, const char *oldpath,
                const char *newpath)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_rename_async(smb2, oldpath, newpath,
                               sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_symlink(struct smb2_context *smb2, const char *target,
                 const char *linkpath, uint32_t flags)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

        rc = smb2_symlink_async(smb2, target, linkpath, flags,
                                sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
        }

        rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
        }

        rc = cb_data->status;
 out:
        free(cb_data);

        return rc;
}

int smb2_link(struct smb2_context *smb2, const char *oldpath,
                const char *newpath)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_link_async(smb2, oldpath, newpath,
                               sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_statvfs(struct smb2_context *smb2, const char *path,
                 struct smb2_statvfs *st)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_statvfs_async(smb2, path, st,
                                sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_truncate(struct smb2_context *smb2, const char *path,
                  uint64_t length)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_truncate_async(smb2, path, length,
                                 sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

int smb2_ftruncate(struct smb2_context *smb2, struct smb2fh *fh,
                   uint64_t length)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

	rc = smb2_ftruncate_async(smb2, fh, length,
                                  sync_generic_status_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

struct sync_readlink_cb_data {
	char *buf;
        int len;
};

static void readlink_cb(struct smb2_context *smb2, int status,
                    void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;
        struct sync_readlink_cb_data *rl_data = cb_data->ptr;

        if (cb_data->status == SMB2_STATUS_CANCELLED) {
                free(cb_data);
                return;
        }

        cb_data->is_finished = 1;
        cb_data->status = status;

        /* There is no target to report unless the call succeeded. */
        if (status || command_data == NULL || rl_data->len <= 0) {
                return;
        }
        strncpy(rl_data->buf, command_data, rl_data->len);
        rl_data->buf[rl_data->len - 1] = 0;
}

int smb2_readlink(struct smb2_context *smb2, const char *path,
                  char *buf, uint32_t len)
{
        struct sync_cb_data *cb_data;
        struct sync_readlink_cb_data rl_data _U_;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

        rl_data.buf = buf;
        rl_data.len = len;

        cb_data->ptr = &rl_data;

	rc = smb2_readlink_async(smb2, path, readlink_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

static void sync_copy_ioctl_cb(struct smb2_context *smb2, int status,
                               void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;

        if (cb_data->status == SMB2_STATUS_CANCELLED) {
                free(cb_data);
                return;
        }

        cb_data->is_finished = 1;
        cb_data->status = status;
        cb_data->ptr = command_data;
}

int smb2_request_resume_key(struct smb2_context *smb2, struct smb2fh *fh,
                            struct smb2_srv_copychunk_resume_key *resume_key)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

        rc = smb2_request_resume_key_async(smb2, fh, sync_copy_ioctl_cb,
                                           cb_data);
        if (rc < 0) {
                goto out;
        }

        rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                goto out;
        }

        rc = cb_data->status;
        if (rc == 0 && cb_data->ptr != NULL) {
                if (resume_key != NULL) {
                        memcpy(resume_key, cb_data->ptr, sizeof(*resume_key));
                }
                smb2_free_data(smb2, cb_data->ptr);
                cb_data->ptr = NULL;
        }
 out:
        free(cb_data);

        return rc;
}

int smb2_copychunk(struct smb2_context *smb2,
                   uint32_t ctl_code,
                   const struct smb2_srv_copychunk_resume_key *resume_key,
                   struct smb2fh *dstfh,
                   const struct smb2_srv_copychunk *chunks,
                   uint32_t chunk_count,
                   struct smb2_srv_copychunk_reply *reply)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

        rc = smb2_copychunk_async(smb2, ctl_code, resume_key, dstfh, chunks,
                                  chunk_count, sync_copy_ioctl_cb, cb_data);
        if (rc < 0) {
                goto out;
        }

        rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                goto out;
        }

        rc = cb_data->status;
        if (cb_data->ptr != NULL) {
                if (reply != NULL) {
                        memcpy(reply, cb_data->ptr, sizeof(*reply));
                }
                smb2_free_data(smb2, cb_data->ptr);
                cb_data->ptr = NULL;
        }
 out:
        free(cb_data);

        return rc;
}

int smb2_server_side_copy(struct smb2_context *smb2,
                          uint32_t ctl_code,
                          struct smb2fh *srcfh, struct smb2fh *dstfh,
                          const struct smb2_srv_copychunk *chunks,
                          uint32_t chunk_count,
                          struct smb2_srv_copychunk_reply *reply)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

        rc = smb2_server_side_copy_async(smb2, ctl_code, srcfh, dstfh,
                                         chunks, chunk_count,
                                         sync_copy_ioctl_cb, cb_data);
        if (rc < 0) {
                goto out;
        }

        rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                goto out;
        }

        rc = cb_data->status;
        if (cb_data->ptr != NULL) {
                if (reply != NULL) {
                        memcpy(reply, cb_data->ptr, sizeof(*reply));
                }
                smb2_free_data(smb2, cb_data->ptr);
                cb_data->ptr = NULL;
        }
 out:
        free(cb_data);

        return rc;
}

static void sync_echo_cb(struct smb2_context *smb2, int status,
                    void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;

        if (cb_data->status == SMB2_STATUS_CANCELLED) {
                free(cb_data);
                return;
        }

        cb_data->is_finished = 1;
        cb_data->status = status;
}

/*
 * Send SMB2_ECHO command to the server
 */
int smb2_echo(struct smb2_context *smb2)
{
        struct sync_cb_data *cb_data;
        int rc = 0;

        if (!SMB2_VALID_SOCKET(smb2->fd)) {
                smb2_set_error(smb2, "Not Connected to Server");
                return -ENOMEM;
        }

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return -ENOMEM;
        }

        rc = smb2_echo_async(smb2, sync_echo_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                return rc;
	}

        rc = cb_data->status;
 out:
        free(cb_data);

	return rc;
}

static void sync_notify_change_cb(struct smb2_context *smb2, int status,
                       void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;

        if (cb_data->status == SMB2_STATUS_CANCELLED) {
                return;
        }

        cb_data->is_finished = 1;
        cb_data->ptr = command_data;
}


/**
 * One-off sync command for getting notify change response
 */
struct smb2_file_notify_change_information *smb2_notify_change(struct smb2_context *smb2, const char *path, uint16_t flags, uint32_t filter)
{
        struct sync_cb_data *cb_data;
        void *ptr;

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return NULL;
        }

	if (smb2_notify_change_async(smb2, path, flags, filter, 0,
                               sync_notify_change_cb, cb_data) != 0) {
		smb2_set_error(smb2, "smb2_notify_change failed");
                free(cb_data);
		return NULL;
	}

	if (wait_for_reply(smb2, cb_data) < 0) {
                cb_data->status = SMB2_STATUS_CANCELLED;
                free(cb_data);
                return NULL;
        }

	ptr = cb_data->ptr;
        free(cb_data);
        return ptr;
}

static void sync_share_enum_cb(struct smb2_context *smb2, int status,
                    void *command_data, void *private_data)
{
        struct sync_cb_data *cb_data = private_data;

        if (cb_data->status == SMB2_STATUS_CANCELLED) {
                free(cb_data);
                return;
        }

        cb_data->is_finished = 1;
        cb_data->status = status;
        cb_data->ptr = command_data;
}

/*
 * Send SRVSVC ShareEnum call to the server
 */
struct srvsvc_NetrShareEnum_rep *
smb2_share_enum_sync(struct smb2_context *smb2, enum SHARE_INFO_enum level)
{
        struct srvsvc_NetrShareEnum_rep *rep = NULL;
        struct sync_cb_data *cb_data;
        int rc = 0;

        if (!SMB2_VALID_SOCKET(smb2->fd)) {
                smb2_set_error(smb2, "Not Connected to Server");
                return NULL;
        }

        cb_data = calloc(1, sizeof(struct sync_cb_data));
        if (cb_data == NULL) {
                smb2_set_error(smb2, "Failed to allocate sync_cb_data");
                return NULL;
        }

        rc = smb2_share_enum_async(smb2, level, sync_share_enum_cb, cb_data);
        if (rc < 0) {
                goto out;
	}

	rc = wait_for_reply(smb2, cb_data);
        if (rc < 0) {
                return NULL;
	}

        rep = cb_data->ptr;

 out:
        free(cb_data);

	return rep;
}
