#!/bin/bash

bash clean.sh

nargo compile

mkdir -p ./target/claim
mkdir -p ./target/withdrawOrTransfer

mv ./target/claim.json ./target/claim/
mv ./target/withdrawOrTransfer.json ./target/withdrawOrTransfer/

bb write_vk -b ./target/claim/claim.json -o ./target/claim --oracle_hash keccak
bb write_vk -b ./target/withdrawOrTransfer/withdrawOrTransfer.json -o ./target/withdrawOrTransfer --oracle_hash keccak

bb write_solidity_verifier -k ./target/claim/vk -o ./target/claim/Verifier.sol
bb write_solidity_verifier -k ./target/withdrawOrTransfer/vk -o ./target/withdrawOrTransfer/Verifier.sol

