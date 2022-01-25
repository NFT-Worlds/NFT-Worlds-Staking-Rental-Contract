# NFTW Escrow and NFTW Rental Contracts

NFTW Escrow is a staking contract where users can stake worlds and earn staking rewards.
NFTW Rental contract allows users to rent worlds to create experiences.

## Gas optimized

This contract is highly gas optimized, with the following test results:

```
  Staking gas for 1: 31088
  Unstaking gas for 1: 50391

  Staking gas for 2: 46602
  Unstaking gas for 2: 63647

  Staking gas for 50: 789122
  Unstaking gas for 50: 700160
```
Staking a world costs ~$8 at 100 gwei and staking 50 worlds costs only $200.
Staking a world for the first time would cost about 2x to 3x as much as shown in these simulations.

## Stake to a hardware/cold wallet

When you stake you may optionally choose to stake to a different wallet without paying additional gas fees. Use this opportunity to stake to a hardware wallet for increased security.

>WARNING: the destination wallet will be the owner of your world, so make sure it's a wallet that you fully control. (Wallets from some centralized exchanges for example, are not in your complete control and you should avoid those. Multi-sig wallets may also pose problems.)

Similarly, when you unstake you may optionally unstake to a hot wallet without additional gas. This way you never need to set approval to marketplace contracts such as OpenSea from your cold wallet (which is unsafe).

## Staking reward calculation

Staking reward is calculated in the following way.

Each world will have a staking weight that is based on its rarity. The staking weight is 
<img src="https://render.githubusercontent.com/render/math?math=W_n=40003-3*Rank_n">. For a rank 1 world its weight is 40000, and for a rank 10000 world its weight is 10003. The average weight is 25000.

The staking reward <img src="https://render.githubusercontent.com/render/math?math=R_{user}"> is calculated as

<img src="https://render.githubusercontent.com/render/math?math=R_{user}=\sum_{t}\frac{\sum_{i\in%20S_{user}}W_i}{\sum_{i\in%20S_{all}}W_i}r_{rewards}">

where at any point in time <img src="https://render.githubusercontent.com/render/math?math=\sum_{i\in%20S_{user}}W_i"> is the sum of all weights of worlds staked by user, <img src="https://render.githubusercontent.com/render/math?math=\sum_{i\in%20S_{all}}W_i"> is the sum of all weights of all staked worlds, <img src="https://render.githubusercontent.com/render/math?math=r_{rewards}"> is the rate of reward emission for all users.

## Governance token

When you stake your world you get in return a non-transferrable ERC20 governance token veNFTW to be used for on-chain governance voting. For each world you stake you get 1 veNFTW regardless of its rarity. When you unstake, the veNFTW is burned. You may delegate your voting power to someone else in the community.

## Setting rental conditions

When you set the rental conditions, you can specify `deposit`, `rentalPerDay`, `minRentDays` and `rentableUntil`.

The `deposit` and `rentalPerDay` are in $WRLD, and you may specify an integer between 0 and 65535 for those values. It's only possible to set integer $WRLD values.

The tenant has to pay at least **`deposit` + 1 day of rent** when taking the rent. It's not necessary to specify the length of the rental period. For as long as the tenant is paying rent the world will keep being rented. 

>Note: if you set `rentalPerDay` to 0, anyone taking the rent will automatically rent it until the `rentableUntil` time, with no recourse of early termination from either parties.

If the tenant does not rent for at least `minRentDays` the entire `deposit` can be forfeited by the owner. The tenant does not have to provide the entire rent for the `minRentDays` upfront, as long as enough rent is paid at any given time throughout that period. If the `rentableUntil` comes before the `minRentDays` limit then the tenant just has to pay for the period until the `rentableUntil` without paying the `deposit`.

At any time, if the current blockchain time exceeds the time that the rent is paid for, then
1. anyone else can rent that world at the same conditions as a fresh rental contract (i.e. `deposit` and `minRentDays` need to be respected)
1. the owner can terminate the rental contract and take it off the market
1. the tenant in default can pay up the rent and continue renting

# Developer Notes

## Toolchain

This directory is built for the [Foundry](https://github.com/gakonst/foundry) framework.

### Installation

First run the command below to get `foundryup`, the Foundry toolchain installer:

```
curl -L https://foundry.paradigm.xyz | bash
```

Then in a new terminal session or after reloading your PATH, run it to get the latest `forge` and `cast` binaries:

```
foundryup
```

### Compiling

```
forge build --optimize --optimize-runs 20000
```

### Testing

```
forge test --optimize --optimize-runs 20000 -vv
```

## Deployment Notes
This contract uses **openzeppelin v4.5.0-rc.0**. To achieve optimized gas usage use 20000 runs on solidity 0.8.11.

Call the `setRewards()` method only AFTER at least 1 world is staked.

There's no other special considerations needed in the deployment process.

## Design Considerations

This contract is optimized to use only 1 storage slot for storing world rarity and rental conditions, and 1 storage slot for renting data. Some trade-offs had to be made.

- Deposit and rental per day can only be set to an integer between 0 - 65535 $WRLD, meaning no fraction of a $WRLD can be used for renting.
- All timestamps are unsigned 32-bit unix epoch, meaning this contract is usable until year 2106.
- Token amounts are uint96 which is 79b. $WRLD total supply is within this limit.



