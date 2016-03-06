with import <nixpkgs> {}; let
	marathon = [{
		id = "/etcd-cloudflare-dns";
		instances = 1;
		
		cpus = "JSON_UNSTRING 0.01 JSON_UNSTRING";
		mem = 50;
		disk = 0;
		
		cmd = ''
			set -a
			source /etc/kevincox-environment
			source /run/keys/cloudflare
			nix-store -r PKG --add-root pkg --indirect
			exec sudo -E -uetcd-cloudflare-dns PKG/bin/etcd-cloudflare-dns
		'';
		env = {
			CF_DOMAIN = "kevincox.ca";
		};
		user = "root";
		
		upgradeStrategy = {
			minimumHealthCapacity = 0;
			maximumOverCapacity = 0;
		};
	}];
in stdenv.mkDerivation {
	name = "etcd-cloudflare-dns";
	
	outputs = ["out" "marathon"];
	
	meta = {
		description = "Keep cloudflare dns records in sync with data in etcd.";
		homepage = https://kevincox.ca;
	};
	
	src = builtins.filterSource (name: type:
		(lib.hasPrefix (toString ./Gemfile) name) ||
		(lib.hasPrefix (toString ./bin) name)
	) ./.;
	
	SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
	
	buildInputs = [ ruby bundler git makeWrapper ];
	
	buildPhase = ''
		bundle install --standalone
		rm -r bundle/ruby/*/cache/
	'';
	
	installPhase = ''
		mkdir -p "$out"
		cp -rv bundle "$out"
		install -Dm755 bin/etcd-cloudflare-dns.rb "$out/bin/etcd-cloudflare-dns"
		
		wrapProgram $out/bin/etcd-cloudflare-dns \
			--set RUBYLIB "$out/bundle"
		
		# Marathon config.
		install ${builtins.toFile "marathon" (builtins.toJSON marathon)} "$marathon"
		substituteInPlace "$marathon" \
			--replace '"JSON_UNSTRING' "" \
			--replace 'JSON_UNSTRING"' "" \
			--replace PKG "$out"
	'';
}
