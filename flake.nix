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

        nixosModule.default = { config, lib, pkgs, ... }:
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
              description = "Base domain for preview sites.";
            };

            apiTokenFile = mkOption {
              type = types.path;
              description = "Path to file containing the API token.";
            };

            useHttps = mkOption {
              type = types.bool;
              default = cfg.useNginx;
              description = "Whether to use HTTPS for URLs. Defaults to true when nginx is enabled.";
            };

            useNginx = mkOption {
              type = types.bool;
              default = true;
              description = "Whether to configure nginx as a reverse proxy.";
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.services.sspd = {
              description = "Static Site Preview Daemon";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              serviceConfig = {
                ExecStart = "${cfg.package}/bin/sspd";
                DynamicUser = true;
                StateDirectory = "sspd";
                LoadCredential = [ "api-token:${cfg.apiTokenFile}" ];
                ExecStartPre = [
                  "+${pkgs.writeShellScript "load-api-token" ''
                    export PV_API_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/api-token")
                  ''}"
                ];
                Environment = [
                  "PV_DATA_DIR=${cfg.dataDir}"
                  "PV_BASE_DOMAIN=${cfg.baseDomain}"
                  "PV_USE_HTTPS=${toString cfg.useHttps}"
                ];
              };
            };

            systemd.tmpfiles.rules = [
              "d ${cfg.dataDir} 0750 sspd sspd -"
            ];

            services.nginx = lib.mkIf cfg.useNginx {
              enable = true;
              forceSSL = cfg.useHttps;
              enableACME = cfg.useHttps;
              
              virtualHosts.${cfg.baseDomain} = {
                locations."/" = {
                  proxyPass = "http://127.0.0.1:3000";
                  proxyPassRewrite = false;
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
                locations."/" = {
                  proxyPass = "http://127.0.0.1:3000";
                  proxyPassRewrite = false;
                  extraConfig = ''
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Forwarded-Proto $scheme;
                  '';
                };
              };
            };
          };
        };
      }
    );
} 