with import <nixpkgs> {};

stdenv.mkDerivation {
	name = "etcd-cloudflare-dns";
	
	meta = {
		description = "Keep cloudflare dns records in sync with data in etcd.";
		homepage = https://kevincox.ca;
	};
	
	src = builtins.filterSource (name: type:
		(lib.hasPrefix (toString ./Gemfile) name) ||
		(lib.hasPrefix (toString ./bin) name)
	) ./.;
	
	__noChroot = true;
	SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
	
	buildInputs = [ ruby bundler git tree ];
	
	buildPhase = ''
		bundle install --standalone
		rm -r bundle/ruby/*/cache/
	'';
	
	installPhase = ''
		mkdir -p "$out"
		cp -rv bundle "$out"
		install -Dm755 bin/etcd-cloudflare-dns.rb "$out/bin/etcd-cloudflare-dns"
	'';
}
