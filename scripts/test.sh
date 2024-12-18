#!/bin/bash

set -o allexport
source .env
set +o allexport

# run tests at block 896150
sed -e "s~MAINNET_RPC_URL~$MAINNET_RPC_URL~g" \
    -e "s~BLOCK_NUMBER~896150~g" \
    Scarb.toml.template > Scarb.toml

snforge test "Test_896150"

# run tests at block 974640
sed -e "s~MAINNET_RPC_URL~$MAINNET_RPC_URL~g" \
    -e "s~BLOCK_NUMBER~974640~g" \
    Scarb.toml.template > Scarb.toml

snforge test "Test_974640"
