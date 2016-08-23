#! /usr/bin/env ruby

require 'bundler/setup'

require 'uri'
require 'openssl'
require 'pp'

require 'rubyflare'
require 'etcd'

Rec = Struct.new :id,
                 :type,
                 :name,
                 :value,
                 :ttl,
                 :cdn do
	def self.from_etcd json
		d = JSON.parse json
		type = d['type']
		ttl = [d['ttl'] || 0, 120].max
		value = if type == 'SRV'
			d['value'].split
		else
			d['value']
		end
		Rec.new d['id'], type, d['name'], value, ttl, d['cdn']
	end
	
	def group_key
		if type == "AAAA"
			"A-#{name}" # Group all "address" records together.
		else
			"#{type}-#{name}"
		end
	end
	
	def conflict_key
		if type == "SRV"
			# Match target and port.
			"#{value[3]}:#{value[2]}"
		else
			value
		end
	end
	
	def == that
		type == that.type and
		name == that.name and
		value == that.value and
		ttl == that.ttl and
		cdn == that.cdn
	end
	
	# def to_s
	# 	"#{name} #{type} #{value}"
	# end
	
	def to_cloudflare
		r = {
			type: type,
			name: name,
			content: value,
			ttl: ttl,
			proxied: cdn,
		}
		
		if type == 'SRV'
			# CloudFlare makes us spell it out for them.
			priority, weight, port, target = value
			service, proto, *rest = name.split '.'
			r[:content] = nil
			r[:data] = {
				priority: priority,
				weight: weight,
				port: port,
				target: target,
				service: service,
				proto: proto,
				name: rest.join('.'),
			}
		end
		
		r
	end
end

DOMAIN = ENV.fetch 'CF_DOMAIN'
PREFIX = "/zones/#{DOMAIN}/"

$cf = Rubyflare.connect_with ENV.fetch('CF_EMAIL'), ENV.fetch('CF_API_KEY')

recs = []
page = 1
more = true

while more
	res = $cf.get "#{PREFIX}dns_records?page=#{page}&per_page=50"
	info = res.body.fetch :result_info

	recs.concat res.results
	
	more = page < info.fetch(:total_pages)
	page += 1
end

pp recs

recs.map! do |r|
	type = r[:type]
	value = if type == 'SRV'
		r[:data].values_at(:priority, :weight, :port, :target)
	else
		r[:content]
	end
	
	Rec.new r[:id],
	        type,
	        r[:name],
	        value,
	        r[:ttl],
	        r[:proxied]
end
$existing_records = recs.group_by{|r| r.group_key}
recs = nil # GC please.

$existing_records.each do |k, v|
	$existing_records[k] = h = {}
	v.each do |r|
		ck = r.conflict_key
		raise "#{r} exists already!" if h.include? ck
		h[ck] = r
	end
end
pp $existing_records

$managed_records = Hash.new {|h, k| h[k] = {}}

etcd_uris = ENV.fetch('ETCDCTL_PEERS').split(',').map{|u| URI.parse(u)}
crt = OpenSSL::X509::Certificate.new File.read ENV.fetch 'ETCDCTL_CERT_FILE'
key = OpenSSL::PKey::RSA.new File.read ENV.fetch 'ETCDCTL_KEY_FILE'
etcd = Etcd.client host:     etcd_uris[0].host,
                   port:     etcd_uris[0].port || 80,
                   use_ssl:  etcd_uris[0].scheme.end_with?('s'),
                   ca_file:  ENV.fetch('ETCDCTL_CA_FILE'),
                   ssl_cert: crt,
                   ssl_key:  key

def set_record new
	existing = $existing_records.delete new.group_key
	if existing
		old = existing.delete new.conflict_key
	else
		old = $managed_records[new.group_key][new.conflict_key]
	end
	
	if old.nil?
		puts "Creating #{new}"
		res = $cf.post "#{PREFIX}dns_records", new.to_cloudflare
		new.id = res.results.fetch :id
	elsif old == new
		# puts "Record #{new} already exists, leaving."
		new.id = old.id
	else
		puts "Updating #{new}"
		pp old, new
		res = $cf.put "#{PREFIX}dns_records/#{old.id}", new.to_cloudflare
		pp res
		new.id = res.results.fetch :id
	end
	
	if existing
		puts "Clearing group of #{new}"
		existing.each{|k, v| delete_record v}
	end
	$managed_records[new.group_key][new.conflict_key] = new
rescue
	pp $!
	pp $!.response if $!.respond_to? :response
	raise $!
end

def delete_record rec
	puts "Deleting #{rec}"
	
	group = rec.group_key
	existing = $managed_records[group]
	
	if existing.size == 1
		puts "Not removing last record in group #{rec}"
		$existing_records[group] = $managed_records.delete group
	else
		res = $cf.delete "#{PREFIX}dns_records/#{rec.id}"
		$managed_records[group].delete rec.conflict_key
	end
end

r = etcd.get '/services/', recursive: true
last_index = r.etcd_index
r.node.children.sort_by{|n| n.key}.each do |n|
	next if n.children.empty?
	
	name = File.basename n.key
	recs = n.children.map{|c| Rec.from_etcd c.value}
	group = recs.first.group_key
	
	# This is a hack to not remove any records until we have conformed the
	# existing ones and created new ones.
	toremove = $existing_records.delete(group) || {}
	$managed_records[group] = toremove
	toremove = toremove.dup
	
	recs.each do |r|
		toremove.delete r.conflict_key
		set_record r
	end

	toremove.each do |k, v|
		delete_record v
	end
end


recs = etcd_uris = crt = key = nil

loop do
	r = etcd.watch '/services/',
	               recursive: true,
	               index: last_index + 1
	last_index = r.node.modified_index
	
	case r.action
	when 'set'
		set_record Rec.from_etcd r.value
	when 'delete', 'expire'
		cs = r.key.split '/'
		delete_record $managed_records.fetch(cs[-2]).fetch(cs[-1])
	else
		puts "Unknown action #{r.action.inspect}"
		pp r
	end
end
