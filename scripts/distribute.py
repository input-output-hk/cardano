#!/usr/bin/env nix-shell
#!nix-shell -i python -p python3Packages.docopt

"""distribute

Usage:
    distribute [--testnet-magic INT] [--signing-key-file FILE] [--address ADDRESS] [--payments-json FILE]

Options:
    -h --help                    Show this screen
    -t --testnet-magic <INT>     Testnet Magic
    -s --signing-key-file <FILE> Signing Key
    -a --address <STRING>        Receiving address
    -p --payments-json <FILE>    JSON file containing payments to make (List of attrs, where each attr is a single address:amount)

"""

import json
import os
import subprocess
import time
from docopt import docopt
from pathlib import Path

arguments = docopt(__doc__, version='Distribute 0.0')
network_args = []

if arguments["--address"]:
  utxo_address = arguments["--address"]
else:
  print("Must specify source address for payments")
  exit(1)

if arguments["--signing-key-file"] and os.path.exists(arguments["--signing-key-file"]):
  utxo_signing_key = Path(arguments["--signing-key-file"])

else:
  print("Must specify signing key file")
  exit(1)

if arguments["--payments-json"]:
  payments_json = arguments["--payments-json"]
else:
  print("Must specify payments file")
  exit(1)

if arguments["--testnet-magic"]:
  network_args = ["--testnet-magic", arguments["--testnet-magic"]]
else:
  network_args = ["--mainnet"]

last_txin = ""


def getTTL(seconds=3600):
    p = subprocess.run(["cardano-cli", "query", "tip", *network_args], capture_output=True, text=True)
    if p.returncode != 0:
        print(p.stderr)
        raise Exception("Unknown error getting ttl")
    return int(json.loads(p.stdout.rstrip())["slot"]) + seconds

def createTransaction(start, end, txin, payments_txouts, utxo_signing_key):
    payments_txout_args = []
    total_payments_spent = 0
    for d in payments_txouts:
        (k,v), = d.items()
        payments_txout_args.extend(["--tx-out", f"{k}+{v}"])
        total_payments_spent += v

    num_keys = end - start + 1
    txin_str = txin[0]
    ttl=getTTL(86400)
    pparams = getPParams()
    tx_prefix = f"tx-payments-{start}-{end}"
    tx_out_amount = int(txin[1]) - 0 - total_payments_spent
    p = subprocess.run(["cardano-cli", "transaction", "build-raw", "--out-file", f"{tx_prefix}.txbody", "--tx-in", txin_str, "--tx-out", f"{utxo_address}+{tx_out_amount}", *payments_txout_args, "--ttl", str(ttl), "--fee", "0"])
    fee = estimateFeeTx(f"{tx_prefix}.txbody", 1, len(payments_txouts), pparams)
    tx_out_amount = int(txin[1]) - fee - total_payments_spent
    if tx_out_amount <= 1000000:
        raise Exception("Not enough funds")
    p = subprocess.run(["cardano-cli", "transaction", "build-raw", "--out-file", f"{tx_prefix}.txbody", "--tx-in", txin_str, "--tx-out", f"{utxo_address}+{tx_out_amount}", *payments_txout_args, "--ttl", str(ttl), "--fee", str(fee)])
    signed_tx = signTx(tx_prefix, utxo_signing_key)

    p = subprocess.run(["cardano-cli", "transaction", "txid", "--tx-file", signed_tx], capture_output=True, text=True)
    new_txin = p.stdout.rstrip()
    return (f"{new_txin}#0", tx_out_amount, fee)

def getLargestUtxoForAddress(address):
    p = subprocess.run(["cardano-cli", "query", "utxo", "--out-file", "tmp_utxo.json", *network_args, "--address", address])
    f = open("tmp_utxo.json")
    utxo = json.load(f)
    if not utxo:
      print("address has no available utxos")
      exit(1)
    lovelace = 0
    txin = None
    for k,v in utxo.items():
      if(len(v['value']) == 1 and v['value']['lovelace'] > lovelace):
        lovelace =v['value']['lovelace']
        txin = (k,lovelace)
    if txin == None:
      print("No suitable utxo could be found")
      exit(1)
    return txin

def getPParams():
    p = subprocess.Popen(["cardano-cli", "query", "protocol-parameters", *network_args, "--out-file", "pparams.json"])
    p.wait()
    return "pparams.json"

def estimateFeeTx(txbody, txin_count, txout_count, pparams):
    cmd = ["cardano-cli", "transaction", "calculate-min-fee", *network_args,  "--tx-in-count", str(txin_count), "--tx-out-count", str(txout_count), "--witness-count", "1", "--protocol-params-file", pparams, "--tx-body-file", txbody]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        print(cmd)
        print(p.stderr)
        raise Exception("error calculating fee")
    return int(p.stdout.rstrip().split(" ")[0])

def signTx(tx_body_prefix, utxo_signing_key):
    p = subprocess.run(["cardano-cli", "transaction", "sign", "--tx-body-file", f"{tx_body_prefix}.txbody", "--out-file", f"{tx_body_prefix}.txsigned", "--signing-key-file", utxo_signing_key])
    return f"{tx_body_prefix}.txsigned"

def getAccountsFromFile(filename):
    f = open(filename)
    payments = json.load(f)
    f.close()
    return payments

accounts = getAccountsFromFile(payments_json)
payments_txouts = []

txin = getLargestUtxoForAddress(utxo_address)
ttl = getTTL(86400)
initial = txin[1]
fees = 0
extra_lovelace = 0

accounts_fixed = []
if type(accounts) == dict:
    for k,v in accounts.items():
        accounts_fixed.append({ k: v})
elif type(accounts) == list:
    accounts_fixed = accounts

for i,d in enumerate(accounts_fixed):
    (k,v), = d.items()
    if v >= 1000000:
        value = v
    else:
        extra_lovelace += 1000000 - v
        value = 1000000

    payments_txouts.append({ k: value })
    if (i % 100) == 99 or len(accounts) == i + 1:
        start = (i // 100) * 100
        end = i
        print(f"Transferring payments for keys {start} - {end}")
        txin = createTransaction(start, end, txin, payments_txouts, utxo_signing_key)
        fees += txin[2]
        payments_txouts = []

spent = initial - txin[1]
print(f"total spent: {spent} fees: {fees} minutxo_extra: {extra_lovelace}")
