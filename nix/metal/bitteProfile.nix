{
  inputs,
  cell,
}: let
  inherit (inputs) nixpkgs;
in {
  default = {
    self,
    lib,
    pkgs,
    config,
    terralib,
    bittelib,
    ...
  }: let
    inherit (self.inputs) bitte;
    inherit (config) cluster;

    sr = {
      inherit
        (bittelib.securityGroupRules config)
        internet
        internal
        ssh
        http
        https
        routing
        ziti-controller-mgmt
        ziti-controller-rest
        ziti-router-edge
        ziti-router-fabric
        ;
    };

    mkCardanoVolume = namespace: (
      bittelib.mkNomadHostVolumesConfig
      ["${namespace}-persist-cardano-node-local"]
      (n: "/var/lib/nomad-volumes/${n}")
    );

    mkDbsyncVolume = namespace: (
      bittelib.mkNomadHostVolumesConfig
      ["${namespace}-persist-db-sync-local"]
      (n: "/mnt/gv0/${n}")
    );

  in {
    secrets.encryptedRoot = ./encrypted;

    cluster = {
      s3CachePubKey = lib.fileContents ./encrypted/nix-public-key-file;
      flakePath = "${inputs.self}";
      vbkBackend = "local";
      infraType = "awsExt";

      autoscalingGroups = let
        defaultModules = [(bitte + "/profiles/client.nix")];

        eachRegion = attrs: [
          (attrs // {region = "eu-central-1";})
          (attrs // {region = "eu-west-1";})
          (attrs // {region = "us-east-2";})
        ];

        euCentral = attrs: [
          (attrs // {region = "eu-central-1";})
        ];
      in
        lib.listToAttrs
        (
          lib.forEach
          (
            # Infra Nodes
            (euCentral {
              instanceType = "t3.2xlarge";
              desiredCapacity = 3;
              volumeSize = 500;
              modules =
                defaultModules
                ++ [
                  (
                    bittelib.mkNomadHostVolumesConfig
                    [ "infra-database" ]
                    (n: "/var/lib/nomad-volumes/${n}")
                  )
                  # for scheduling constraints
                  {services.nomad.client.meta.patroni = "yeah";}
                ];
              node_class = "infra";
            })
            ++
            # QA nodes
            (eachRegion {
              instanceType = "t3.2xlarge";
              desiredCapacity = 0;
              volumeSize = 500;
              modules =
                defaultModules
                ++ [
                  (mkCardanoVolume "mainnet")
                  (mkDbsyncVolume "mainnet")

                  (mkCardanoVolume "preprod")
                  (mkDbsyncVolume "preprod")

                  (mkCardanoVolume "preview")
                  (mkDbsyncVolume "preview")

                  (mkCardanoVolume "private")
                  (mkDbsyncVolume "private")

                  (mkCardanoVolume "sanchonet")
                  (mkDbsyncVolume "sanchonet")

                  (mkCardanoVolume "shelley-qa")
                  (mkDbsyncVolume "shelley-qa")

                  # For scheduling constraints
                  {services.nomad.client.meta.cardano = "yeah";}
                ];
              node_class = "qa";
            })
          )
          (args: let
            attrs =
              {
                desiredCapacity = 6;
                instanceType = "t3a.large";
                associatePublicIP = true;
                maxInstanceLifetime = 0;
                iam.role = cluster.iam.roles.client;
                iam.instanceProfile.role = cluster.iam.roles.client;

                securityGroupRules = {inherit (sr) internet internal ssh;};
              }
              // args;
            asgName = "client-${attrs.region}-${
              builtins.replaceStrings [''.''] [''-''] attrs.instanceType
            }-${args.node_class}";
          in
            lib.nameValuePair asgName attrs)
        );

      instances = {
        core-1 = {
          instanceType = "r5.xlarge";
          privateIP = "172.16.0.10";
          subnet = cluster.vpc.subnets.core-1;
          volumeSize = 100;

          modules = [
            (bitte + /profiles/core.nix)
            (bitte + /profiles/bootstrapper.nix)
          ];

          securityGroupRules = {inherit (sr) internet internal ssh;};
        };

        core-2 = {
          instanceType = "r5.xlarge";
          privateIP = "172.16.1.10";
          subnet = cluster.vpc.subnets.core-2;
          volumeSize = 100;

          modules = [
            (bitte + /profiles/core.nix)
          ];

          securityGroupRules = {inherit (sr) internet internal ssh;};
        };

        core-3 = {
          instanceType = "r5.xlarge";
          privateIP = "172.16.2.10";
          subnet = cluster.vpc.subnets.core-3;
          volumeSize = 100;

          modules = [
            (bitte + /profiles/core.nix)
          ];

          securityGroupRules = {inherit (sr) internet internal ssh;};
        };

        monitoring = {
          instanceType = "t3a.xlarge";

          privateIP = "172.16.0.20";
          subnet = cluster.vpc.subnets.core-1;
          volumeSize = 700;
          ebsOptimized = true;
          securityGroupRules = {inherit (sr) internet internal ssh http https;} // {wireguard = {cidrs = ["0.0.0.0/0"]; port = 51820; protocols = ["udp"];};};
          modules = [
            (bitte + /profiles/monitoring.nix)
            ./monitoring.nix
          ];
        };

        routing = {
          instanceType = "t3a.small";
          privateIP = "172.16.1.20";
          subnet = cluster.vpc.subnets.core-2;
          volumeSize = 100;
          securityGroupRules = {inherit (sr) internet internal ssh http https routing;};
          route53.domains = [
            "*.${cluster.domain}"
            "consul.${cluster.domain}"
            "docker.${cluster.domain}"
            "monitoring.${cluster.domain}"
            "nomad.${cluster.domain}"
            "vault.${cluster.domain}"
          ];

          modules = [
            (bitte + /profiles/routing.nix)
            {
              services.oauth2_proxy.email.domains = ["iohk.io"];

              # Change to true if/when we want tempo enabled for this cluster.
              # See also corresponding tempo option on the monitoring server.
              services.traefik.enableTracing = false;

              services.traefik.staticConfigOptions = {
                entryPoints =
                  lib.pipe {
                    preprod = 30000;
                    preview = 30002;
                    shelley-qa = 30003;
                    sanchonet = 30004;
                    private = 30007;
                  } [
                    (
                      lib.mapAttrsToList (
                        namespace: port: {
                          name = "${namespace}-node-tcp";
                          value.address = ":${toString port}";
                        }
                      )
                    )
                    lib.listToAttrs
                  ];
              };
            }
          ];
        };

        # GlusterFS storage nodes
        storage-0 = {
          instanceType = "t3a.small";
          privateIP = "172.16.0.30";
          subnet = config.cluster.vpc.subnets.core-1;
          volumeSize = 40;
          modules = [(bitte + /profiles/storage.nix)];
          securityGroupRules = {inherit (sr) internal internet ssh;};
          ebsVolume = {
            iops = 3000; # 3000..16000
            size = 500; # GiB
            type = "gp3";
            throughput = 125; # 125..1000 MiB/s
          };
        };

        storage-1 = {
          instanceType = "t3a.small";
          privateIP = "172.16.1.30";
          subnet = config.cluster.vpc.subnets.core-2;
          volumeSize = 40;
          modules = [(bitte + /profiles/storage.nix)];
          securityGroupRules = {inherit (sr) internal internet ssh;};
          ebsVolume = {
            iops = 3000; # 3000..16000
            size = 500; # GiB
            type = "gp3";
            throughput = 125; # 125..1000 MiB/s
          };
        };

        storage-2 = {
          instanceType = "t3a.small";
          privateIP = "172.16.2.30";
          subnet = config.cluster.vpc.subnets.core-3;
          volumeSize = 40;
          modules = [(bitte + /profiles/storage.nix)];
          securityGroupRules = {inherit (sr) internal internet ssh;};
          ebsVolume = {
            iops = 3000; # 3000..16000
            size = 500; # GiB
            type = "gp3";
            throughput = 125; # 125..1000 MiB/s
          };
        };
      };

      awsExtNodes = let
        # For each new machine provisioning to equinix:
        #   1) TF plan/apply in the `equinix` workspace to get the initial machine provisioning done after declaration
        #      `nix run .#clusters.cardano.tf.equinix.[plan|apply]
        #   2) Record the privateIP attr that the machine is assigned in the nix metal code
        #   3) Add the provisioned machine to ssh config for deploy-rs to utilize
        #   4) Update the encrypted ssh config file with the new machine so others can easily pull the ssh config
        #   5) Deploy again with proper private ip, provisioning configuration and bitte stack modules applied
        #      `deploy -s .#$CLUSTER_NAME-$MACHINE_NAME --auto-rollback false --magic-rollback false
        inherit
          (import ./equinix.nix self config)
          baseEquinixMachineConfig
          baseEquinixModuleConfig
          baseExplorerGatewayModuleConfig
          baseExplorerModuleConfig
          deployType
          mkExplorer
          mkExplorerGateway
          node_class
          plan
          primaryInterface
          project
          role
          tags
          ;
      in {
        # Traefik explorer gateway
        explorer = mkExplorerGateway "explorer" "10.12.171.133" "192.168.254.254" "mainnet" {};

        # Explorer backends
        explorer-1 = mkExplorer "explorer-1" "10.12.171.129" "192.168.254.1" "mainnet" {};
        explorer-2 = mkExplorer "explorer-2" "10.12.171.131" "192.168.254.2" "mainnet" {};
      };
    };
  };
}
