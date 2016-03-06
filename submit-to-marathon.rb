#! /usr/bin/env ruby

require 'json'
require 'net/http'
require 'openssl'
require 'yaml'

pkg = ARGV.fetch 0
pkg = File.readlink pkg if File.exists? pkg

config = [{
	id: "/etcd-cloudflare-dns",
	instances: 1,
	
	cpus: 0.01,
	mem: 50,
	disk: 0,
	
	cmd: [
		"set -a",
			"source /etc/kevincox-environment",
			"source /run/keys/cloudflare",
		"nix-store -r #{pkg} --add-root pkg --indirect",
		"exec sudo -E -uetcd-cloudflare-dns #{pkg}/bin/etcd-cloudflare-dns",
	].join(" && "),
	env: {
		CF_DOMAIN: "kevincox.ca",
	},
	user: "root",
	
	upgradeStrategy: {
		minimumHealthCapacity: 0,
		maximumOverCapacity: 0,
	},
}]

http = Net::HTTP.new "marathon.kevincox.ca", 443
http.use_ssl = true
http.verify_mode = OpenSSL::SSL::VERIFY_NONE
http.cert = OpenSSL::X509::Certificate.new File.read "/home/kevincox/p/nix/secret/ssl/s.kevincox.ca.crt"
http.key = OpenSSL::PKey::RSA.new File.read "/home/kevincox/p/nix/secret/ssl/s.kevincox.ca.key"

req = Net::HTTP::Put.new "https://marathon.kevincox.ca/v2/apps"
req.content_type = 'application/json; charset=utf-8'
req.body = JSON.dump config
res = http.request req

p res
puts YAML.dump JSON.parse res.body

exit res.code == 200
