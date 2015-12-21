with import <nixpkgs> {};

stdenv.mkDerivation {
	name = "api.kevincox.ca-2015-12-02";
	
	meta = {
		description = "kevincox API";
		homepage = https://api.kevincox.ca;
	};
	
	src = builtins.filterSource (name: type:
		builtins.trace name (lib.hasPrefix (toString ./Gemfile) name) ||
		(lib.hasPrefix (toString ./bin) name)
	) ./.;
	
	__noChroot = true;
	SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
	
	buildInputs = [ ruby bundler git ];
	
	buildPhase = ''
		ls .
		export 'GEM_HOME=gems/'
		bundle install
	'';
	
	installPhase = ''
		mkdir -p "$out"
		cp -rv gems "$out"
		install -Dm755 bin/etcd-cloudflare-dns.rb "$out/bin/etcd-cloudflare-dns"
	'';
}
