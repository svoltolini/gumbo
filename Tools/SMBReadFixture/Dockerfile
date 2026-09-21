FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends samba && rm -rf /var/lib/apt/lists/* && useradd -M gumbo-test && printf 'fixture-only\nfixture-only\n' | smbpasswd -a -s gumbo-test
COPY smb.conf /etc/samba/smb.conf
CMD ["smbd", "--foreground", "--no-process-group", "--debug-stdout"]
