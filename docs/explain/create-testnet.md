# GenSTAKE_POOL_DIR=workbench/pools \
ENV_NAME=preview \
START_INDEX=1 \
NUM_POOLS=3 \
nix run .\#x86_64-linux.automation.jobs.gen-custom-kv-config-poolserate genesis files and keys
```
IOHK_NIX=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.iohk-nix.outPath')
TEMPLATE_DIR="$IOHK_NIX/cardano-lib/testnet-template" \
SECURITY_PARAM=432 \
NUM_GENESIS_KEYS=7 \
SLOT_LENGTH=1000 \
TESTNET_MAGIC=2 \
START_TIME="2022-08-11T14:00:00Z" \
nix run .\#x86_64-linux.automation.jobs.gen-custom-node-config
```

# Import configuration/keys into kv store with bitte deployments
```
GENESIS_DIR=workbench/custom \
ENV_NAME=preview NUM_GENESIS_KEYS=7 \
nix run .\#x86_64-linux.automation.jobs.gen-custom-kv-config
```

# Start local node to build blocks
```
for i in {0..6}; do
  cat workbench/custom/delegate-keys/shelley.00"$i".opcert.json \
    workbench/custom/delegate-keys/shelley.00"$i".vrf.skey \
    workbench/custom/delegate-keys/shelley.00"$i".kes.skey \
    >> bulk.creds
done
```

```
cardano-node run \
  --config workbench/custom/node-config.json \
  --database-path ~/.local/share/bitte/cardano/db-preview/node \
  --topology "$IOHK_NIX/cardano-lib/testnet-template/topology-empty-p2p.json" \
  +RTS -N2 -A16m -qg -qb -M3584.000000M -RTS \
  --socket-path $(pwd)/node.socket \
  --shelley-kes-key workbench/custom/delegate-keys/shelley.000.kes.skey \
  --shelley-vrf-key workbench/custom/delegate-keys/shelley.000.vrf.skey \
  --shelley-operational-certificate workbench/custom/delegate-keys/shelley.000.opcert.json
```

For further commands using local node:
```
export CARDANO_NODE_SOCKET_PATH=$(pwd)/node.socket
```

# Create nomad jobs for new environment
Create new namespace for environment and create jobs for around three stake pools.
```
cp nix/cloud/namespaces/<existing namespace>.nix nix/cloud/namespaces/<new namespace>.nix
```
Add entry to `flake.nix` for namespace

# Deploy BFT nodes

# Generate rich utxo keys
```
cardano-cli address key-gen \
  --signing-key-file workbench/custom/utxo-keys/rich-utxo.skey \
  --verification-key-file workbench/custom/utxo-keys/rich-utxo.vkey
```

# Transition funds from genesis block
Build payment address:
```
cardano-cli address build \
  --testnet-magic 2 \
  --payment-verification-key-file workbench/custom/utxo-keys/rich-utxo.vkey
```

```
PAYMENT_ADDRESS=addr_test1vpaeyyjrlmxcjk23mflkn7nqaxj6m07zc6zdh45yfjnjqcgav9jcj \
BYRON_SIGNING_KEY=workbench/custom/utxo-keys/shelley.000.skey \
TESTNET_MAGIC=2 \
nix run .\#x86_64-linux.automation.jobs.move-genesis-utxo
```

# Register stake pools
```
PAYMENT_KEY=workbench/custom/utxo-keys/rich-utxo \
NUM_POOLS=3 \
START_INDEX=1 \
STAKE_POOL_OUTPUT_DIR=workbench/pools \
POOL_RELAY=preview-node.world.dev.cardano.org \
POOL_RELAY_PORT=30002 \
TESTNET_MAGIC=2 \
nix run .\#x86_64-linux.automation.jobs.create-stake-pools
```

# Import stake pool keys into kv store with bitte deployments
```
STAKE_POOL_DIR=workbench/pools \
ENV_NAME=preview \
START_INDEX=1 \
NUM_POOLS=3 \
nix run .\#x86_64-linux.automation.jobs.gen-custom-kv-config-pools
```

# Deploy stake pools

# Issue update proposal to hard fork to next era
```
PAYMENT_KEY=workbench/custom/utxo-keys/rich-utxo \
TESTNET_MAGIC=2 \
NUM_GENESIS_KEYS=7 \
KEY_DIR=workbench/custom MAJOR_VERSION=6 \
nix run .\#x86_64-linux.automation.jobs.update-proposal-hard-fork
```

# Issue update proposal to modify cost model

# Setup a faucet
