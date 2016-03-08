#! /usr/bin/env ruby

require 'bundler/setup'

require 'uri'
require 'openssl'
require 'pp'

require 'cloudflare'
require 'etcd'

Rec = Struct.new :id,
                 :type,
                 :name,
                 :value,
                 :ttl,
                 :cdn do
	def self.from_etcd json
		d = JSON.parse json
		ttl = d['ttl'] ? [d['ttl'], 120].max : 1
		Rec.new d['id'], d['type'], d['name'], d['value'], ttl, d['cdn']
	end
	
	def group_key
		"#{type}-#{name}"
	end
	
	def conflict_key
		value
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
end

DOMAIN = ENV['CF_DOMAIN']

$cf = CloudFlare.connection ENV['CF_API_KEY'], ENV['CF_EMAIL']
r = $cf.rec_load_all DOMAIN
recs = r['response']['recs']
puts "Warning, didn't get all records!" if recs['has_more']
$existing_records = recs['objs'].map do |r|
	Rec.new r['rec_id'],
	        r['type'],
	        r['name'],
	        r['content'],
	        r['ttl'].to_i,
	        r['service_mode'] == '1'
end.group_by{|r| r.group_key}
$existing_records.each do |k, v|
	$existing_records[k] = h = {}
	v.each do |r|
		ck = r.conflict_key
		raise "#{r} exists already!" if h.include? ck
		h[ck] = r
	end
end

$managed_records = Hash.new {|h, k| h[k] = {}}

etcd_uris = ENV['ETCDCTL_PEERS'].split(',').map{|u| URI.parse(u)}
crt = OpenSSL::X509::Certificate.new File.read ENV['ETCDCTL_CERT_FILE']
key = OpenSSL::PKey::RSA.new File.read ENV['ETCDCTL_KEY_FILE']
etcd = Etcd.client host:     etcd_uris[0].host,
                   port:     etcd_uris[0].port || 80,
                   use_ssl:  etcd_uris[0].scheme.end_with?('s'),
                   ca_file:  ENV['ETCDCTL_CA_FILE'],
                   ssl_cert: crt,
                   ssl_key:  key

def set_record new
	existing = $existing_records.delete new.group_key
	if existing
		old = existing.delete new.conflict_key
	else
		old = $managed_records[new.group_key][new.conflict_key]
	end
	
	ttl = new.ttl
	ttl = if ttl.nil?
		1 # Automatic
	else
		[ttl, 120].max
	end
	
	if old.nil?
		puts "Creating #{new}"
		r = $cf.rec_new DOMAIN,
		                new.type,
		                new.name,
		                new.value,
		                ttl,
		                nil,
		                nil,
		                nil,
		                nil,
		                nil,
		                nil,
		                nil,
		                new.cdn ? '1' : '0'
		new.id = r['response']['rec']['obj']['rec_id']
	elsif old == new
		puts "Record #{new} already exists, leaving."
		new.id = old.id
	else
		puts "Updating #{new}"
		$cf.rec_edit DOMAIN,
		             new.type,
		             old.id,
		             new.name,
		             new.value,
		             ttl,
		             new.cdn
		
		new.id = old.id
	end
	
	if existing
		puts "Clearing group of #{new}"
		existing.each{|k, v| delete_record v}
	end
	$managed_records[new.group_key][new.conflict_key] = new
end

def delete_record rec
	puts "Deleting #{rec}"
	
	group = rec.group_key
	existing = $managed_records[group]
	
	if existing.size == 1
		puts "Not removing last record in group #{rec}"
		$existing_records[group] = $managed_records.delete group
	else
		$cf.rec_delete DOMAIN, rec.id
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
		delete_record $managed_records[cs[-2]][cs[-1]]
	else
		puts "Unknown action #{r.action.inspect}"
		pp r
	end
end
