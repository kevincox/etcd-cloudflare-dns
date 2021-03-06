with import <nixpkgs> {}; let
	klib = import (
		builtins.fetchTarball https://github.com/kevincox/nix-lib/archive/master.tar.gz
	);
in rec {
	out = stdenv.mkDerivation {
		name = "etcd-cloudflare-dns";
		
		meta = {
			description = "Keep cloudflare dns records in sync with data in etcd.";
			homepage = https://kevincox.ca;
		};
		
		src = builtins.filterSource (name: type:
			(lib.hasPrefix (toString ./Gemfile) name) ||
			(lib.hasPrefix (toString ./bin) name)
		) ./.;
		
		SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
		
		buildInputs = [ curl ruby bundler git makeWrapper ];
		
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
		'';
	};
	marathon = klib.marathon.config [{
		id = "/etcd-cloudflare-dns";
		mem = 50;
		
		constraints = [
			["etcd" "LIKE" "v3"]
		];
		
		env-files = [
			"/run/keys/cloudflare"
			"/etc/kevincox-etcd"
		];
		env = {
			CF_DOMAIN = "18ecb4e8ca9d031c2ce5a7ce24636656";
		};
		exec = [ "${out}/bin/etcd-cloudflare-dns" ];
		user = "etcd-cloudflare-dns";
		
		upgradeStrategy = {
			minimumHealthCapacity = 0;
			maximumOverCapacity = 0;
		};
	}];
}
