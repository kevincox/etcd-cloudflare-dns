#! /bin/bash

set -e

pkg="$(readlink -f result)"

cat >etcd-cloudflare-dns.service <<END
[Unit]
Description=Keep CloudFlare DNS up to date with values in etcd.

[Service]
Environment="CF_API_KEY=$CF_API_KEY"
Environment="CF_EMAIL=$CF_EMAIL"
Environment=DOMAIN=kevincox.ca
Environment=GEM_HOME=$pkg/gems
EnvironmentFile=/etc/kevincox-environment
ExecStart=$pkg/bin/etcd-cloudflare-dns
Restart=always
END

fleetctl "$@" destroy etcd-cloudflare-dns.service || true
fleetctl "$@" load etcd-cloudflare-dns.service
