# SPDX-License-Identifier: GPL-2.0-or-later
# Test-only image; no changes to the separately built shipping helper image.
ARG HELPER_IMAGE=gumbo-tag-service:local
FROM ${HELPER_IMAGE}
USER 0:0
RUN apt-get update && apt-get install -y --no-install-recommends acl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir /validation && chown 1000:1000 /validation
COPY . /tests
ENV TMPDIR=/validation
USER 1000:1000
ENTRYPOINT ["python", "-B", "-m", "unittest", "discover", "-s", "/tests", "-v"]
