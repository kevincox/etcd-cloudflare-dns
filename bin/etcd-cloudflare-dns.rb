#! /usr/bin/env ruby

require 'uri'
require 'openssl'
require 'pp'

require 'cloudflare'
require 'etcd'

DOMAIN = ENV.delete 'DOMAIN'

cf = CloudFlare.connection ENV['CF_API_KEY'], ENV['CF_EMAIL']
r = cf.rec_load_all DOMAIN
recs = r['response']['recs']
puts "Warning, didn't get all records!" if recs['has_more']
records = recs['objs'].group_by{|r| r['name']}

etcd_uris = ENV['ETCDCTL_PEERS'].split(',').map{|u| URI.parse(u)}
crt = OpenSSL::X509::Certificate.new File.read ENV['ETCDCTL_CERT_FILE']
key = OpenSSL::PKey::RSA.new File.read ENV['ETCDCTL_KEY_FILE']
etcd = Etcd.client host:     etcd_uris[0].host,
                   port:     etcd_uris[0].port || 80,
                   use_ssl:  etcd_uris[0].scheme.end_with?('s'),
                   ca_file:  ENV['ETCDCTL_CA_FILE'],
                   ssl_cert: crt,
                   ssl_key:  key

previous = {}

r = etcd.get '/services/', recursive: true
last_index = r.etcd_index
r.node.children.sort_by{|n| n.key}.each do |n|
	next if n.children.empty? # Skip empty.
	
	domain = File.basename n.key
	hosts  = n.children.map{|c| c.value}
	pp domain, hosts
	
	toremove = records[domain]
	toremove = if toremove
		toremove.group_by{|r| r['content']}
	else
		{}
	end
	
	toremove = toremove.map do |k, v|
		r = v.pop
		v.each do |r|
			puts 'Duplicate record:'
			pp v
			cf.rec_delete DOMAIN, v['rec_id']
		end
		
		[k, r]
	end.to_h
	
	hosts.each do |host|
		old = toremove.delete host
		dh = [domain, host]
		if old
			previous[dh] = old['rec_id']
			puts "Record A #{domain} -> #{host} already exists, leaving."
		else
			puts "Creating A kevincox.ca #{domain} -> #{host} 120"
			r = cf.rec_new DOMAIN, 'A', domain, host, 120
			previous[dh] = r['response']['rec']['obj']['rec_id']
		end
	end

	toremove.each do |k, v|
		puts 'Removing existing record:'
		pp v
		
		cf.rec_delete DOMAIN, v['rec_id']
	end
end


recs = etcd_uris = crt = key = nil

loop do
	r = etcd.watch '/services/',
	               recursive: true,
	               index: last_index + 1
	last_index = r.node.modified_index
	
	components = r.key.split '/'
	unless components.length == 4
		puts "Unexpected key #{r.key}"
		next
	end
	dh = components[2, 3]
	d, h = dh
	
	case r.action
	when 'set'
		next if previous.member? dh
		
		puts "Creating A #{d} -> #{h} 120"
		r = cf.rec_new DOMAIN, 'A', d, h, 120
		previous[dh] = r['response']['rec']['obj']['rec_id']
	when 'delete'
		id = previous.delete dh
		next unless id
		
		puts "Removing A #{d} -> #{h}"
		cf.rec_delete DOMAIN, id
	else
		puts "Unknown action #{r.action.inspect}"
		pp r
	end
end
