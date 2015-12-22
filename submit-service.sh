#! /bin/bash

set -e

pkg="$(readlink -f result)"

cat >etcd-cloudflare-dns.service <<END
[Unit]
Description=Keep CloudFlare DNS up to date with values in etcd.
After=nix-expr@${pkg##*/}.service
Requires=nix-expr@${pkg##*/}.service

[Service]
Environment=DOMAIN=kevincox.ca
Environment=GEM_HOME=$pkg/gems
EnvironmentFile=/etc/kevincox-environment
EnvironmentFile=/run/keys/cloudflare

User=etcd-cloudflare-dns
ExecStart=$pkg/bin/etcd-cloudflare-dns
Restart=always
END

fleetctl "$@" destroy etcd-cloudflare-dns.service || true
fleetctl "$@" start etcd-cloudflare-dns.service
