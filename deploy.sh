#!/bin/bash

[ -z "$ETH_RPC_URL" ] && echo "Need to set ETH_RPC_URL" && exit
[ -z "$PRIVATE_KEY" ] && echo "Need to set PRIVATE_KEY" && exit
[ -z "$SIGNER_ADDR" ] && echo "Need to set SIGNER_ADDR" && exit

# deploy rpc address
POLYGON_RPC_URL=https://polygon-rpc.com

PolygonChildChainManagerProxy=0xA6FA4fB5f76172d178d61B04b0ecd319C5d1C0aa
ERC20PredicateProxy=0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf

# Deployment start directory
start_path='src'

# NFTWEscrow  deployment path
nftwescrow=${start_path}/NFTWEscrow.sol:NFTWEscrow

# NFTWRental deployment path
nftwrental=${start_path}/NFTWRental.sol:NFTWRental

# veNFTWPolygon deployment path
venftwpolygon=${start_path}/veNFTWPolygon.sol:veNFTW_Polygon

# Official 721 and 20 addresses
nftw721_address = 0xBD4455dA5929D5639EE098ABFaa3241e9ae111Af
wrld20_address = 0xD5d86FC8d5C0Ea1aC1Ac5Dfab6E529c9967a45E9


forge clean
forge build --optimize --optimize-runs 20000

# Deploy NFTWEscrow
echo Deploying NFTWEscrow...
NFTWEscrow_address=`forge create --optimize --optimize-runs 20000 --chain mainnet --rpc-url ${ETH_RPC_URL} --constructor-args ${wrld20_address} ${nftw721_address} --private-key ${PRIVATE_KEY} ${nftwescrow} | grep -Eio '0x[a-z0-9]+$' | tail -2 | head -1`
echo NFTWEscrow_address: ${NFTWEscrow_address}

# Deploy NFTWRental
echo Deploying NFTWRental...
NFTWRental_address=`forge create --optimize --optimize-runs 20000 --chain mainnet --rpc-url ${ETH_RPC_URL} --constructor-args ${wrld20_address} ${NFTWEscrow_address} --private-key ${PRIVATE_KEY} ${nftwrental} | grep -Eio '0x[a-z0-9]+$' | tail -2 | head -1`
echo NFTWRental_address: ${NFTWRental_address}

# Deploy veNFTWPolygon
echo Deploying veNFTWPolygon...
venftwpolygon_address=`forge create --optimize --optimize-runs 20000 --chain polygon --rpc-url ${POLYGON_RPC_URL} --constructor-args ${PolygonChildChainManagerProxy} --private-key ${PRIVATE_KEY} ${venftwpolygon} | grep -Eio '0x[a-z0-9]+$' | tail -2 | head -1`
echo venftwpolygon_address: ${venftwpolygon_address}

# set NFTWEscrow setSigner
echo Setting signer...
cast send --chain mainnet --rpc-url ${ETH_RPC_URL} --private-key ${PRIVATE_KEY} ${NFTWEscrow_address} "setSigner(address _signer)" ${SIGNER_ADDR}

# set NFTWEscrow setRentalContract
echo Setting rental contract...
cast send --chain mainnet --rpc-url ${ETH_RPC_URL} --private-key ${PRIVATE_KEY} ${NFTWEscrow_address} "setRentalContract(address _contract)" ${NFTWRental_address}

# set NFTWEscrow setPredicate
echo Setting predicate proxy...
cast send --chain mainnet --rpc-url ${ETH_RPC_URL} --private-key ${PRIVATE_KEY} ${NFTWEscrow_address} "setPredicate(address _contract, bool _allow)" ${ERC20PredicateProxy} 1

