#! /usr/bin/env ruby

require 'uri'
require 'openssl'
require 'pp'

require 'etcd'

# Major hack because we can't automatically load git gems.
$LOAD_PATH << "#{ENV['GEM_HOME']}/bundler/gems/cloudflare-91e7182f983b/lib"
require 'cloudflare'


DOMAIN = ENV.delete 'DOMAIN'

$cf = CloudFlare.connection ENV['CF_API_KEY'], ENV['CF_EMAIL']
r = $cf.rec_load_all DOMAIN
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

def create_record(data)
	puts "Creating kevincox.ca #{data}"
	
	ttl = data['ttl']
	ttl = if ttl.nil?
		1 # Automatic
	else
		[ttl, 120].max
	end
	
	r = $cf.rec_new(
		DOMAIN,
		data['type'],
		data['name'],
		data['value'],
		ttl,
		data['priority'],
		data['service'],
		data['srvname'],
		data['protocol'],
		data['weight'],
		data['port'],
		data['target'],
		data['cdn']? '1' : '0')
	
	# Return the new record ID.
	r['response']['rec']['obj']['rec_id']
end

r = etcd.get '/services/', recursive: true
last_index = r.etcd_index
r.node.children.sort_by{|n| n.key}.each do |n|
	next if n.children.empty? # Skip empty.
	
	domain = File.basename n.key
	hosts  = n.children
	pp domain, hosts.map{|c| c.value}
	
	toremove = records[domain]
	toremove = if toremove
		toremove.keep_if{|r| r['type'] == 'A'}
		toremove.group_by{|r| r['content']}
	else
		{}
	end
	
	toremove = toremove.map do |k, v|
		r = v.pop
		v.each do |r|
			puts 'Duplicate record:'
			pp v
			$cf.rec_delete DOMAIN, v['rec_id']
		end
		
		[k, r]
	end.to_h
	
	hosts.each do |host|
		data = JSON.parse host.value
		ip = data['value']
		old = toremove.delete ip
		dh = [domain, ip]
		if old
			previous[dh] = old['rec_id']
			puts "Record A #{domain} -> #{host} already exists, leaving."
		else
			data['name'] = domain
			previous[dh] = create_record data
		end
	end

	toremove.each do |k, v|
		puts 'Removing existing record:'
		pp v
		
		$cf.rec_delete DOMAIN, v['rec_id']
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
		data = JSON.parse r.value
		data['name'] = d
		previous[dh]  = create_record data
	when 'delete'
		id = previous.delete dh
		next unless id
		
		puts "Removing A #{d} -> #{h}"
		$cf.rec_delete DOMAIN, id
	else
		puts "Unknown action #{r.action.inspect}"
		pp r
	end
end
