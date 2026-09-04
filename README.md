# garnix-guest-lib

The NixOS module a server deployed by garnix hosting has to import. It is a
repository of its own so that hosting a server does not drag the garnix
backend, frontend and provisioner into your flake's lock file.

## Use

```nix
{
  inputs = {
    garnix.url = "github:OSSystems/garnix-guest-lib";
    garnix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, garnix, ... }: {
    nixosConfigurations.hello = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        garnix.nixosModules.garnix-guest
        ({ ... }: {
          services.nginx.enable = true;
          system.stateVersion = "25.11";
        })
      ];
    };
  };
}
```

Then say *when* to deploy it in `garnix.yaml`, not in Nix:

```yaml
builds:
  include:
    - nixosConfigurations.*

servers:
  - configuration: hello
    deployment:
      type: on-branch
      branch: main
```

The module sets what a guest needs to run on garnix's infrastructure —
microVM volumes and the shared `/nix/store`, networking, sshd and the deploy
key, the stats reporter. Everything else under `garnix.server.*` (extra
domains and ports, ssh exposure, backups, application logs) is optional; see
`guest-profile.nix` for the options and their defaults.

Nothing in here is specific to one garnix instance: no hostnames, no keys.
The deploy key is injected by the provisioner at guest-creation time.
