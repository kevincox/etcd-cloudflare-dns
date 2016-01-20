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
		Rec.new d['id'], d['type'], d['name'], d['value'], d['ttl'], d['cdn']
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
$records = recs['objs'].map do |r|
	Rec.new r['rec_id'],
	        r['type'],
	        r['name'],
	        r['content'],
	        r['ttl'].to_i,
	        r['service_mode'] == '1'
end.group_by{|r| r.group_key}
$records.each do |k, v|
	h = $records[k] = {}
	v.each do |r|
		ck = r.conflict_key
		raise "#{r} exists already!" if h.include? ck
		h[r.conflict_key] = r
	end
end

# Records that aren't being deleted because they are the only remaining record.
$held_records = {}

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
	old = $records[new.group_key]
	old = old[new.conflict_key] if old
	
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
	
	$records[new.group_key][new.conflict_key] = new
end

def delete_record rec
	puts "Deleting #{rec}"
	$cf.rec_delete DOMAIN, rec.id
	$records[rec.group_key].delete rec.conflict_key
end

pp $records

r = etcd.get '/services/', recursive: true
last_index = r.etcd_index
r.node.children.sort_by{|n| n.key}.each do |n|
	next if n.children.empty?
	
	name = File.basename n.key
	recs = n.children.map{|c| Rec.from_etcd c.value}
	
	toremove = $records[recs.first.group_key]
	toremove = if toremove
		toremove.dup
	else
		{}
	end
	
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
	
	pp r
	case r.action
	when 'set'
		set_record Rec.from_etcd r.value
	when 'delete'
		cs = r.key.split '/'
		delete_record $records[cs[-2]][cs[-1]]
	else
		puts "Unknown action #{r.action.inspect}"
		pp r
	end
end
