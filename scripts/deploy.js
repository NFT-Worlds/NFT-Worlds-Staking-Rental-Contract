require('dotenv').config();

const { ethers } = require('hardhat');

const IS_PRODUCTION = true;

const WRLD_TOKEN_ADDRESS = (IS_PRODUCTION)
  ? '0xD5d86FC8d5C0Ea1aC1Ac5Dfab6E529c9967a45E9'
  : '0xa8f39f359c4045f3098eebcecfc966deb5b459c1';
const NFTW_NFT_ADDRESS = (IS_PRODUCTION)
  ? '0xBD4455dA5929D5639EE098ABFaa3241e9ae111Af'
  : '0x4b84311fb82e348c3bfc48f3bc0117a3df1e88af';

async function main() {
  const {
    RINKEBY_WEBSOCKET_URL,
    RINKEBY_ACCOUNT,
    ETHEREUM_WEBSOCKET_URL,
    ETHEREUM_ACCOUNT,
  } = process.env;

  const { Wallet } = ethers;
  const { WebSocketProvider } = ethers.providers;

  const ethereumProvider = (IS_PRODUCTION)
    ? new WebSocketProvider(ETHEREUM_WEBSOCKET_URL)
    : new WebSocketProvider(RINKEBY_WEBSOCKET_URL);

  const ethereumWallet = (IS_PRODUCTION)
    ? new Wallet(`0x${ETHEREUM_ACCOUNT}`, ethereumProvider)
    : new Wallet(`0x${RINKEBY_ACCOUNT}`, ethereumProvider);

  const NFTWEscrow_Factory = await ethers.getContractFactory('NFTWEscrow', ethereumWallet);
  const NFTWRental_Factory = await ethers.getContractFactory('NFTWRental', ethereumWallet);

  const nftwEscrowContract = await NFTWEscrow_Factory.deploy(
    WRLD_TOKEN_ADDRESS,
    NFTW_NFT_ADDRESS,
  );

  console.log('NFTW Escrow Deploy TX Hash: ', nftwEscrowContract.deployTransaction.hash);
  await nftwEscrowContract.deployed();
  console.log('NFTW Escrow Address: ', nftwEscrowContract.address);

  const nftwRentalContract = await NFTWRental_Factory.deploy(
    WRLD_TOKEN_ADDRESS,
    nftwEscrowContract.address,
  );

  console.log('NFTW Rental Deploy TX Hash', nftwRentalContract.deployTransaction.hash);
  await nftwRentalContract.deployed();
  console.log('NFTW Rental Address: ', nftwRentalContract.address);
}


main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit();
  });
