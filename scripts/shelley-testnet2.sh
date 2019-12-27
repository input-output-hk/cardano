#!/usr/bin/env bash

set -e

# build first:
#> cabal v2-build --reorder-goals

# create tmux session:
#> tmux new-session -s 'Demo' -t demo

# CMD="stack exec --nix cardano-node --"
CMD="cabal v2-run --"
# EXTRA="--live-view"
EXTRA="
  --trace-block-fetch-decisions
  --trace-block-fetch-client
  --trace-block-fetch-server
  --trace-chain-db
  --trace-tx-inbound
  --trace-tx-outbound
  --trace-local-tx-submission-server
  --trace-mempool
  --trace-forge
  --trace-chain-sync-protocol
  --trace-block-fetch-protocol
  --trace-tx-submission-protocol
  --trace-local-chain-sync-protocol
  --trace-local-tx-submission-protocol
"

. $(dirname $0)/lib-node.sh

# for acceptor logs:
mkdir -p logs/

PWD=$(pwd)

tmux split-window -v
tmux select-pane -t 0
tmux split-window -h
tmux split-window -v
tmux select-pane -t 0
tmux split-window -v

tmux select-pane -t 4
tmux send-keys "cd '${PWD}'; ${CMD} trace-acceptor $(acceptorargs)" C-m
sleep 2
tmux select-pane -t 1
tmux send-keys "cd '${PWD}'; ${CMD} exe:cardano-node $(nodeargs 0 "${ALGO} $(echo -n ${EXTRA})") " C-m
tmux select-pane -t 2
tmux send-keys "cd '${PWD}'; ${CMD} exe:cardano-node $(nodeargs 1 "${ALGO} $(echo -n ${EXTRA})") " C-m
tmux select-pane -t 3
tmux send-keys "cd '${PWD}'; ${CMD} exe:cardano-node $(nodeargs 2 "${ALGO} $(echo -n ${EXTRA})") " C-m
