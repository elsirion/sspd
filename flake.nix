{
  description = "Static Site Preview Daemon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        
        rustToolchain = pkgs.rust-bin.stable.latest.default;

        nativeBuildInputs = with pkgs; [
          rustToolchain
          pkg-config
        ];

        buildInputs = with pkgs; [
          openssl
        ];

      in
      {
        packages.default = pkgs.rustPlatform.buildRustPackage {
          pname = "sspd";
          version = "0.1.0";
          
          src = ./.;

          cargoLock = {
            lockFile = ./Cargo.lock;
            allowBuiltinFetchGit = true;
          };

          inherit nativeBuildInputs buildInputs;
        };

        devShells.default = pkgs.mkShell {
          inherit nativeBuildInputs buildInputs;
        };
      } // {
        nixosModules.sspd = { config, lib, pkgs, ... }:
        let
          cfg = config.services.sspd;
        in
        {
          options.services.sspd = with lib; {
            enable = mkEnableOption "Static Site Preview Daemon";
            
            package = mkOption {
              type = types.package;
              default = self.packages.${system}.default;
              description = "The SSPD package to use.";
            };

            dataDir = mkOption {
              type = types.str;
              default = "/var/lib/sspd";
              description = "Directory to store preview sites.";
            };

            baseDomain = mkOption {
              type = types.str;
              example = "preview.example.com";
              description = ''
                Base domain for preview sites.
                
                The preview sites will be hosted at some-random-words.<baseDomain>.
                This means we need to direct all subdomains to this server and also add a wildcard certificate for the base domain. For that reason the following DNS records are created:
                - A record for the base domain (e.g. preview.example.com) pointing to the server
                - Wildcard A record for the base domain (e.g. *.preview.example.com) pointing to the server
                - NS record for the ACME challenge domain (e.g. _acme-challenge.preview.example.com) pointing to the server. This module sets up a local DNS server that responds to the ACME challenges ot acquire the wildcard certificate.
              '';
            };

            apiTokenFile = mkOption {
              type = types.path;
              description = "Path to file containing the API token.";
            };

            setFirewallRules = mkOption {
              type = types.bool;
              default = true;
              description = "Whether to set up firewall rules.";
            };
          };

          config = let
            acmeChallengeDomain = "_acme-challenge.${cfg.baseDomain}";
          in
          lib.mkIf cfg.enable {
            systemd.services.sspd = {
              description = "Static Site Preview Daemon";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              serviceConfig = {
                ExecStart = "${pkgs.writeShellScript "sspd-wrapper" ''
                  export PV_API_TOKEN="$(cat ${cfg.apiTokenFile})"
                  export PV_DATA_DIR="${cfg.dataDir}"
                  export PV_BASE_DOMAIN="${cfg.baseDomain}" 
                  export PV_USE_HTTPS="true"
                  ${cfg.package}/bin/sspd
                ''}";
                DynamicUser = true;
                StateDirectory = "sspd";
              };
            };

            systemd.tmpfiles.rules = [
              "d ${cfg.dataDir} 0750 sspd sspd -"
              "d /var/db/bind 0750 named named -"
            ];

            services.nginx = {
              enable = true;
              clientMaxBodySize = "100M";
              
              virtualHosts.${cfg.baseDomain} = {
                forceSSL = true;
                useACMEHost = cfg.baseDomain;  # Reference the cert we define below

                locations."/" = {
                  proxyPass = "http://127.0.0.1:3000";
                  extraConfig = ''
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Forwarded-Proto $scheme;
                  '';
                };
              };

              # Handle all subdomains
              virtualHosts."~^(?<subdomain>.+)\.${lib.escapeRegex cfg.baseDomain}$" = {
                forceSSL = true;
                useACMEHost = cfg.baseDomain;  # Use the same cert
                locations."/" = {
                  proxyPass = "http://127.0.0.1:3000";
                  extraConfig = ''
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Forwarded-Proto $scheme;
                  '';
                };
              };
            };

            # Get a wildcard certificate for the base domain. Since that requires DNS authentication, 
            # we set up a local DNS server for that (see bind config below). That way our DNS provider 
            # doesn't have to support updates to DNS records via an API.
            security.acme.certs."${cfg.baseDomain}" = {
              domain = "*.${cfg.baseDomain}";
              extraDomainNames = [ "${cfg.baseDomain}" ];
              dnsProvider = "rfc2136";
              environmentFile = "/var/lib/secrets/certs.secret";
              # We don't need to wait for propagation since this is a local DNS server
              dnsPropagationCheck = false;
            };
            users.users.nginx.extraGroups = [ "acme" ];

            services.bind = {
              enable = true;
              extraConfig = ''
                include "/var/lib/secrets/dnskeys.conf";
              '';
              zones = [
                rec {
                  name = acmeChallengeDomain;
                  file = "/var/db/bind/${name}";
                  master = true;
                  extraConfig = "allow-update { key rfc2136key.${acmeChallengeDomain}.; };";
                }
              ];
            };

            # Set up DNS server keys
            systemd.services.dns-rfc2136-conf = {
              requiredBy = ["acme-${acmeChallengeDomain}.service" "bind.service"];
              before = ["acme-${acmeChallengeDomain}.service" "bind.service"];
              unitConfig = {
                ConditionPathExists = "!/var/lib/secrets/dnskeys.conf";
              };
              serviceConfig = {
                Type = "oneshot";
                UMask = 0077;
              };
              path = [ pkgs.bind ];
              script = ''
                mkdir -p /var/lib/secrets
                chmod 755 /var/lib/secrets
                tsig-keygen rfc2136key.${acmeChallengeDomain} > /var/lib/secrets/dnskeys.conf
                chown named:root /var/lib/secrets/dnskeys.conf
                chmod 400 /var/lib/secrets/dnskeys.conf

                # extract secret value from the dnskeys.conf
                while read x y; do if [ "$x" = "secret" ]; then secret="''${y:1:''${#y}-3}"; fi; done < /var/lib/secrets/dnskeys.conf

                cat > /var/lib/secrets/certs.secret << EOF
                RFC2136_NAMESERVER='127.0.0.1:53'
                RFC2136_TSIG_ALGORITHM='hmac-sha256.'
                RFC2136_TSIG_KEY='rfc2136key.${acmeChallengeDomain}'
                RFC2136_TSIG_SECRET='$secret'
                EOF
                chmod 400 /var/lib/secrets/certs.secret
              '';
            };

            # Set up DNS zone file
            systemd.services.dns-setup-zone-file = {
              requiredBy = ["acme-${acmeChallengeDomain}.service" "bind.service"];
              before = ["acme-${acmeChallengeDomain}.service" "bind.service"];
              unitConfig = {
                ConditionPathExists = "!/var/db/bind/${acmeChallengeDomain}";
              };
              serviceConfig = {
                Type = "oneshot";
                UMask = 0077;
                User = "named";
              };
              script = ''
                cat > /var/db/bind/${acmeChallengeDomain} << EOF
                $TTL 60
                @       IN      SOA     ${cfg.baseDomain}. admin.${cfg.baseDomain}. (
                                  2025013102 ; Serial
                                  60       ; Refresh
                                  60       ; Retry
                                  60       ; Expire
                                  60 )    ; Negative Cache TTL

                        IN      NS      ${cfg.baseDomain}.
                EOF
              '';
            };

            networking.firewall = lib.mkIf cfg.setFirewallRules {
              allowedTCPPorts = [ 80 443 53 ];
              allowedUDPPorts = [ 53 ];
            };
          };
        };
      }
    );
} 