#! /bin/bash

set -e

# Get the store path from the result of the build.
pkg="$(readlink -f result)"

# Generate the service description.
cat >etcd-cloudflare-dns.service <<END
[Unit]
Description=Keep CloudFlare DNS up to date with values in etcd.
After=nix-expr@${pkg##*/}.service
Requires=nix-expr@${pkg##*/}.service

[Service]
Environment=DOMAIN=kevincox.ca
Environment=RUBYLIB=$pkg/bundle
EnvironmentFile=/etc/kevincox-environment
EnvironmentFile=/run/keys/cloudflare

User=etcd-cloudflare-dns
ExecStart=$pkg/bin/etcd-cloudflare-dns
Restart=always
END

# Remove the old service and start the new one.
fleetctl "$@" destroy etcd-cloudflare-dns.service || true
fleetctl "$@" start etcd-cloudflare-dns.service
