{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.garnix.server;

  isBackupScheduleValid =
    s:
    s == "hourly"
    || s == "daily"
    || s == "weekly"
    || (
      let
        m = builtins.match "([0-9]+)h" s;
      in
      m != null && lib.toInt (builtins.head m) >= 1
    );
  backupPathIsAbsolute = p: lib.hasPrefix "/" p;
  backupPathUnderNixStore = p: lib.hasPrefix "/nix/store" p;
  backupPathHasDotDot = p: lib.elem ".." (lib.splitString "/" p);

  statsScript = pkgs.writeShellScript "garnix-stats-report" ''
    set -u
    s1=$(head -n1 /proc/stat)
    sleep "''${GARNIX_STATS_CPU_SAMPLE_DELAY:-1}"
    s2=$(head -n1 /proc/stat)
    cpu=$(awk -v a="$s1" -v b="$s2" 'BEGIN {
      na = split(a, x, " "); nb = split(b, y, " ");
      t1 = 0; for (i = 2; i <= na; i++) t1 += x[i];
      t2 = 0; for (i = 2; i <= nb; i++) t2 += y[i];
      idle1 = x[5] + x[6]; idle2 = y[5] + y[6];   # idle + iowait
      dt = t2 - t1; di = idle2 - idle1;
      if (dt <= 0) printf "0.0"; else printf "%.1f", (1 - di / dt) * 100;
    }')
    memtotal=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    memavail=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    memused=$((memtotal - memavail))
    payload=$(printf '{"provisioner_id":"%s","cpu_pct":%s,"mem_used_kb":%d,"mem_total_kb":%d}' \
      "$GARNIX_PROVISIONER_ID" "$cpu" "$memused" "$memtotal")
    attempt=1
    while :; do
      if status=$(curl -sS --max-time 10 --output /dev/null \
           --write-out '%{http_code}' -H 'Content-Type: application/json' \
           -X POST -d "$payload" "$GARNIX_STATS_URL"); then
        case "$status" in
          2??) exit 0 ;;
          *) echo "garnix-stats-report: unexpected HTTP status $status" >&2 ;;
        esac
      fi
      if [ "$attempt" -ge 3 ]; then
        echo "garnix-stats-report: POST to garnix failed after $attempt attempts" >&2
        exit 1
      fi
      attempt=$((attempt + 1))
      sleep "''${GARNIX_STATS_RETRY_DELAY:-3}"
    done
  '';
in
{
  options = {
    garnix = {
      guest = {
        sshPublicKey = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            Hosting SSH public key allowed for root and the garnix user.

            Leave this empty. The key belongs to the garnix instance doing the
            hosting, not to the repository being deployed: the provisioner sets
            it on the base guest it creates, and first boot copies it to
            /var/lib/garnix/hosting_authorized_keys — a path on the guest's own
            disk that sshd reads for root and for the garnix user, and that
            survives activating a configuration which never mentions the key.

            Pinning one instance's key into a repository would also get it
            wrong: a key whose private half you do not hold would be authorized
            as root on every guest you deploy, while the backend that has to
            deploy them could not log in at all.
          '';
        };
        terminalCaPublicKey = lib.mkOption {
          type = lib.types.str;
          default = config.garnix.guest.sshPublicKey;
          description = ''
            Public key of the dedicated web-terminal certificate authority,
            trusted as TrustedUserCAKeys so the backend can mint short-lived
            per-session login certs WITHOUT the guest trusting the hosting/deploy
            key as a CA. Defaults to sshPublicKey so guests that don't set it
            (or were deployed before this option existed) keep trusting the
            hosting key as CA. The provisioner injects the real terminal-CA pubkey.
          '';
        };
      };
      server = {
        domains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra hostnames (full FQDNs) this server should also answer on.";
        };

        exposeSSH = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open a public DNAT port on the garnix host forwarding to the guest's SSH (:22).";
        };

        authorizeDeployerGithubKeys = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Authorize the deployer's github.com/<user>.keys to log in as the garnix user on the deployed server.";
        };

        authorizedSSHKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra SSH public keys to authorize for login as the garnix user on the deployed server.";
        };

        ports = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "A short name; used as the subdomain (http) or label (tcp).";
                };
                port = lib.mkOption {
                  type = lib.types.port;
                  description = "The port the service listens on inside the server.";
                };
                type = lib.mkOption {
                  type = lib.types.enum [
                    "http"
                    "tcp"
                  ];
                  default = "http";
                  description = ''"http" (default) exposes <name>.<server-domain>; "tcp" exposes a raw host:port.'';
                };
              };
            }
          );
          default = [ ];
          description = "Extra ports to expose, beyond the standard :80.";
        };

        applicationLog = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Stream the configured application log in the Servers-page Logs modal.";
                };
                path = lib.mkOption {
                  type = lib.types.str;
                  default = "/var/log/nginx/hello-access.log";
                  description = "Absolute guest path to follow when application logging is enabled.";
                };
              };
            }
          );
          default = null;
          description = "Optional application-log stream. `null` (the default) means no log follows this server.";
        };

        backups = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                paths = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = ''
                    Absolute paths inside the server to back up. Must be
                    non-empty when `backups` is set, and none may be "/" or
                    under /nix/store.
                  '';
                };
                schedule = lib.mkOption {
                  type = lib.types.str;
                  default = "daily";
                  description = ''How often to back up: "hourly" | "daily" (default) | "weekly" | "<N>h" (N >= 1).'';
                };
                preBackupCommand = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Command run on the server (as root, via sh -c) before the backup tar is taken. A non-zero exit aborts the backup.";
                };
                postBackupCommand = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Command run on the server after the tar is taken (cleanup). Always attempted, even if the tar failed.";
                };
                preRestoreCommand = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Command run on the server before a restore untars (e.g. stop your service).";
                };
                postRestoreCommand = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Command run on the server after a restore untars (e.g. start your service). Always attempted, even if the untar failed.";
                };
              };
            }
          );
          default = null;
          description = "Scheduled backups of paths on this server. `null` (the default) means no backups.";
        };

        deploySpec = lib.mkOption {
          type = lib.types.raw;
          readOnly = true;
          default =
            let
              persistenceEnabled = cfg.persistence.enable or false;
              authentikDefault =
                (lib.attrByPath [ "garnix" "authentik" "enable" ] false config)
                && (lib.attrByPath [ "garnix" "authentik" "mode" ] "dedicated" config) == "default";
            in
            {
              inherit (cfg)
                authorizeDeployerGithubKeys
                authorizedSSHKeys
                domains
                exposeSSH
                ;
              inherit authentikDefault;
              ports = map (p: { inherit (p) name port type; }) cfg.ports;
              applicationLog =
                if cfg.applicationLog == null then null else { inherit (cfg.applicationLog) enable path; };
              backups =
                if cfg.backups == null then
                  null
                else
                  {
                    inherit (cfg.backups)
                      paths
                      postBackupCommand
                      postRestoreCommand
                      preBackupCommand
                      preRestoreCommand
                      schedule
                      ;
                  };
              persistence = {
                enable = persistenceEnabled;
                name = if persistenceEnabled then cfg.persistence.name else null;
              };
            };
          description = ''
            Read-only, JSON-serializable aggregate of every `garnix.server.*`
            option above (plus `garnix.server.persistence`, when garnix-lib's
            module is also imported). Rendered verbatim to
            `/etc/garnix/server.json` in the guest below, and `nix eval`ed by the
            backend once a configuration's build has succeeded.

            These are the knobs for a server that is already being deployed.
            WHETHER a configuration is deployed at all, and from which branch, is
            declared in `garnix.yaml` under `servers:` — deliberately not here, so
            that reading the yaml tells you what a push does.
          '';
        };
      };
    };
  };
  config = lib.mkMerge [
    {
      assertions =
        lib.optionals (cfg.backups != null) [
          {
            assertion = cfg.backups.paths != [ ];
            message = "garnix.server.backups.paths must not be empty when garnix.server.backups is set.";
          }
          {
            assertion = isBackupScheduleValid cfg.backups.schedule;
            message = ''garnix.server.backups.schedule must be "hourly", "daily", "weekly", or "<N>h" (N >= 1); got: "${cfg.backups.schedule}"'';
          }
          {
            assertion = lib.all backupPathIsAbsolute cfg.backups.paths;
            message = "garnix.server.backups.paths entries must be absolute paths.";
          }
          {
            assertion = !(lib.elem "/" cfg.backups.paths);
            message = ''garnix.server.backups.paths must not contain "/".'';
          }
          {
            assertion = !(lib.any backupPathUnderNixStore cfg.backups.paths);
            message = "garnix.server.backups.paths must not contain /nix/store paths.";
          }
          {
            assertion = !(lib.any backupPathHasDotDot cfg.backups.paths);
            message = ''garnix.server.backups.paths must not contain ".." components.'';
          }
        ]
        ++ [
          {
            assertion = lib.all (d: d != "") cfg.domains;
            message = "garnix.server.domains entries must be non-empty strings.";
          }
        ];
      environment = {
        etc = {
          "garnix/server.json".text = builtins.toJSON cfg.deploySpec;
          "ssh/garnix-hosting-ca.pub" = lib.mkIf (config.garnix.guest.terminalCaPublicKey != "") {
            text = config.garnix.guest.terminalCaPublicKey + "\n";
          };
          "ssh/garnix-hosting.pub" = lib.mkIf (config.garnix.guest.sshPublicKey != "") {
            text = config.garnix.guest.sshPublicKey + "\n";
          };
        };
      };
      microvm = {
        hypervisor = "qemu";
        volumes = [
          {
            image = "root.img";
            mountPoint = "/";
            size = 20 * 1024;
          }
          {
            image = "overlay.img";
            mountPoint = "/nix/.rw-store";
            size = 20 * 1024;
          }
        ];
        shares = [
          {
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            tag = "ro-store";
            proto = "virtiofs";
          }
        ];
        writableStoreOverlay = "/nix/.rw-store";
      };
      fileSystems."/var/garnix/keys" = {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [
          "mode=0755"
          "size=4m"
        ];
      };
      networking = {
        useNetworkd = true;
        firewall = {
          enable = lib.mkDefault true;
          allowedTCPPorts = [
            22
            80
          ];
        };
      };
      systemd = {
        network.networks."10-eth" = {
          matchConfig.Type = "ether";
          networkConfig = {
            DHCP = "ipv4";
            IPv6AcceptRA = false;
          };
        };
        tmpfiles.rules = [
          "d /var/lib/garnix 0755 root root - -"
          "C /var/lib/garnix/terminal-ca.pub 0644 root root - /etc/ssh/garnix-hosting-ca.pub"
          "C /var/lib/garnix/hosting_authorized_keys 0644 root root - /etc/ssh/garnix-hosting.pub"
        ];
        services.garnix-stats-reporter = {
          description = "Report guest CPU/RAM to garnix";
          unitConfig.ConditionPathExists = "/var/lib/garnix/stats.env";
          path = [
            pkgs.coreutils
            pkgs.gawk
            pkgs.curl
          ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = statsScript;
            DynamicUser = true;
            EnvironmentFile = "/var/lib/garnix/stats.env";
            Environment = [
              "CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
            ];
          };
        };
        timers.garnix-stats-reporter = {
          description = "Periodic guest CPU/RAM report to garnix";
          unitConfig.ConditionPathExists = "/var/lib/garnix/stats.env";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitActiveSec = "20s";
            AccuracySec = "1s";
          };
        };
      };
      boot.kernel.sysctl = {
        "net.ipv6.conf.all.accept_ra" = 0;
        "net.ipv6.conf.default.accept_ra" = 0;
      };
      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "prohibit-password";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
        };
        extraConfig = ''
          TrustedUserCAKeys /var/lib/garnix/terminal-ca.pub
          AuthorizedPrincipalsFile /var/lib/garnix/terminal-principals
          Match User root
            AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u /var/lib/garnix/hosting_authorized_keys
          Match User garnix
            AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u /var/garnix/keys/authorized_keys /var/lib/garnix/hosting_authorized_keys
          Match all
        '';
      };
      users = {
        users = {
          root.openssh.authorizedKeys.keys = lib.optional (
            config.garnix.guest.sshPublicKey != ""
          ) config.garnix.guest.sshPublicKey;
          garnix = {
            isNormalUser = true;
            extraGroups = [ "wheel" ];
            openssh.authorizedKeys.keys = lib.optional (
              config.garnix.guest.sshPublicKey != ""
            ) config.garnix.guest.sshPublicKey;
          };
        };
      };
      security.sudo.wheelNeedsPassword = false;
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
      system.stateVersion = "25.11";
    }
    (lib.mkIf config.services.nginx.enable {
      systemd.services.logrotate-checkconf.after = [ "nginx.service" ];
    })
  ];
}
