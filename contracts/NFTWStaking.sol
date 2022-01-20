// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface INFTWEscrow {
    function setRewards(uint32 start, uint32 end, uint96 rate) external;
}

interface INFTW_ERC721 is IERC721 {
    function updateMetadataIPFSHash(uint _tokenId, string calldata _tokenMetadataIPFSHash) external;
}

contract NFTWEscrow is Initializable, Context, ERC165, ERC20, ERC20Permit, ERC20Votes, AccessControl, ReentrancyGuard {
    using SafeCast for uint;
    using ECDSA for bytes32;
    
    event WeightUpdated(address indexed user, bool increase, uint weight, uint timestamp);
    event WorldRented(uint256 tokenId, address tenant, uint256 payment);
    event RentalPaid(uint256 tokenId, address tenant, uint256 payment);

    event BuilderMetadataUpdate(uint256 tokenId, address builder);

    event RewardsSet(uint32 start, uint32 end, uint256 rate);
    event RewardsUpdated(uint32 start, uint32 end, uint256 rate);
    event RewardsPerWeightUpdated(uint256 accumulated);
    event UserRewardsUpdated(address user, uint256 userRewards, uint256 paidRewardPerWeight);
    event RewardClaimed(address receiver, uint256 claimed);
    event WorldStaked(uint256 tokinId, address user);
    event WorldUnstaked(uint256 tokinId, address user);

    struct WorldInfo {
        uint16 weight;          // weight based on rarity
        address owner;          // staked to, otherwise owner == 0
        uint16 deposit;         // unit is ether, paid in WRLD. The deposit is deducted from the last payment(s) since the deposit is non-custodial
        uint16 rentalPerDay;    // unit is ether, paid in WRLD. Total is deposit + rentalPerDay * days
        uint16 minRentDays;     // must rent for at least min rent days, otherwise deposit is forfeited up to this amount
        uint32 rentableUntil;   // timestamp in unix epoch
    }

    struct WorldRentInfo {
        address tenant;
        uint32 rentStartTime;   // timestamp in unix epoch
        uint32 rentalPaid;      // total rental paid since the beginning including the deposit
        uint32 paymentAlert;    // alert time before next rent payment in seconds
    }

    struct RewardsPeriod {
        uint32 start;           // reward start time, in unix epoch
        uint32 end;             // reward end time, in unix epoch
    }

    struct RewardsPerWeight {
        uint32 totalWeight;
        uint96 accumulated;
        uint32 lastUpdated;
        uint96 rate;
    }

    struct UserRewards {
        uint32 stakedWeight;
        uint96 accumulated;
        uint96 checkpoint;
    }

    address immutable WRLD_ERC20_ADDR;
    INFTW_ERC721 immutable NFTW_ERC721;
    WorldInfo[10000] public worldInfo;
    WorldRentInfo[10000] public worldRentInfo;
    RewardsPeriod public rewardsPeriod;
    RewardsPerWeight public rewardsPerWeight;     
    mapping (address => UserRewards) public rewards;
    bytes32 private constant NFT_ROLE = keccak256("NFT_ROLE");
    bytes32 private constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 private constant VERIFIED_BUILDER_ROLE = keccak256("VERIFIED_BUILDER_ROLE"); // verified builder can update any world metadata
    
    address private signer;

    // ======== Admin functions ========

    constructor(address wrld, address nftw) ERC20("Vote-escrowed NFTWorld", "veWRLD") ERC20Permit("Vote-escrowed NFTWorld") {
        require(wrld != address(0), "addr 0");
        require(nftw != address(0), "addr 0");
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(OWNER_ROLE, _msgSender());
        _setupRole(NFT_ROLE, nftw);
        WRLD_ERC20_ADDR = wrld;
        NFTW_ERC721 = INFTW_ERC721(nftw);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, AccessControl) returns (bool) {
        return interfaceId == type(INFTWEscrow).interfaceId || super.supportsInterface(interfaceId);
    }


    // Set a rewards schedule
    // rate is in wei per second for all users
    function setRewards(uint32 start, uint32 end, uint96 rate) external virtual onlyRole(OWNER_ROLE) {
        require(start <= end, "Incorrect input");
        require(rate > 0.03 ether && rate < 30 ether, "Rate incorrect");
        require(WRLD_ERC20_ADDR != address(0), "Rewards token not set");
        require(block.timestamp.toUint32() < rewardsPeriod.start || block.timestamp.toUint32() > rewardsPeriod.end, "Rewards already set");

        rewardsPeriod.start = start;
        rewardsPeriod.end = end;

        rewardsPerWeight.lastUpdated = start;
        rewardsPerWeight.rate = rate;

        emit RewardsSet(start, end, rate);
    }

    function updateRewards(uint96 rate) external virtual onlyRole(OWNER_ROLE) {
        require(rate > 0.03 ether && rate < 30 ether, "Rate incorrect");
        require(block.timestamp.toUint32() > rewardsPeriod.start && block.timestamp.toUint32() < rewardsPeriod.end, "Rewards not active");
        rewardsPerWeight.rate = rate;

        emit RewardsUpdated(rewardsPeriod.start, rewardsPeriod.end, rate);
    }

    // signing key does not require high security and can be put on an API server and rotated periodically, as signatures are issued dynamically
    function setSigner(address _signer) external onlyRole(OWNER_ROLE) {
        signer = _signer;
    }

    function updateBuilderRole(address builder, bool allow) external onlyRole(OWNER_ROLE) {
        if (allow) {
            _grantRole(VERIFIED_BUILDER_ROLE, builder);
        }
        else {
            _revokeRole(VERIFIED_BUILDER_ROLE, builder);
        }
    }


    // ======== Public functions ========

    // Stake worlds for a first time. You may optionally stake to a different wallet.
    // Initial weights passed as input parameters, which are secured by a dev signature.
    // When you stake you can set rental conditions.
    function initialStake(uint[] calldata tokenIds, uint[] calldata weights, address stakeTo, 
        uint16 _deposit, uint16 _rentalPerDay, uint16 _minRentDays, uint32 _rentableUntil, uint32 _maxTimestamp, bytes calldata _signature) 
        external virtual 
    {
        require(tokenIds.length == weights.length, "Input length mismatch");
        require(_verifySignerSignature(keccak256(
            abi.encode(tokenIds, weights, _msgSender(), _maxTimestamp, address(this))), _signature), "Invalid signature");

        uint totalWeights = 0;
        for (uint i = 0; i < tokenIds.length; i++) {
            WorldInfo memory worldInfo_ = worldInfo[i];
            { // scope to avoid stack too deep errors
                uint tokenId = tokenIds[i];
                require(worldInfo_.weight == 0, "Weight can only be initialized once");
                require(NFTW_ERC721.ownerOf(tokenId) == _msgSender(), "Not your own world");
                NFTW_ERC721.transferFrom(_msgSender(), address(this), tokenId);
            
                emit WorldStaked(tokenId, stakeTo);
            }
            totalWeights += weights[i];
            worldInfo_.weight = weights[i].toUint16();
            worldInfo_.owner = stakeTo;
            worldInfo_.deposit = _deposit;
            worldInfo_.rentalPerDay = _rentalPerDay;
            worldInfo_.minRentDays = _minRentDays;
            worldInfo_.rentableUntil = _rentableUntil;
            worldInfo[i] = worldInfo_;
        }
        // update rewards
        _updateRewardsPerWeight(totalWeights.toUint32(), true);
        _updateUserRewards(stakeTo, totalWeights.toUint32(), true);
        // mint veWRLD
        _mint(stakeTo, tokenIds.length * 1e18);
    }

    // subsequent staking does not require dev signature
    function stake(uint[] calldata tokenIds, address stakeTo, 
        uint16 _deposit, uint16 _rentalPerDay, uint16 _minRentDays, uint32 _rentableUntil) 
        public virtual 
    {
        uint totalWeights = 0;
        for (uint i = 0; i < tokenIds.length; i++) {
            WorldInfo memory worldInfo_ = worldInfo[i];
            { // scope to avoid stack too deep errors
                uint tokenId = tokenIds[i];
                require(worldInfo_.weight != 0, "Weight not initialized");
                require(NFTW_ERC721.ownerOf(tokenId) == _msgSender(), "Not your own world");
                NFTW_ERC721.transferFrom(_msgSender(), address(this), tokenId);

                emit WorldStaked(tokenId, stakeTo);
            }
            totalWeights += worldInfo_.weight;
            worldInfo_.owner = stakeTo;
            worldInfo_.deposit = _deposit;
            worldInfo_.rentalPerDay = _rentalPerDay;
            worldInfo_.minRentDays = _minRentDays;
            worldInfo_.rentableUntil = _rentableUntil;
            worldInfo[i] = worldInfo_;
        }
        // update rewards
        _updateRewardsPerWeight(totalWeights.toUint32(), true);
        _updateUserRewards(stakeTo, totalWeights.toUint32(), true);
        // mint veWRLD
        _mint(stakeTo, tokenIds.length * 1e18);
    }

    function updateRent(uint[] calldata tokenIds, 
        uint16 _deposit, uint16 _rentalPerDay, uint16 _minRentDays, uint32 _rentableUntil) 
        public virtual 
    {
        for (uint i = 0; i < tokenIds.length; i++) {
            WorldInfo memory worldInfo_ = worldInfo[i];
            { // scope to avoid stack too deep errors
                uint tokenId = tokenIds[i];
                require(worldInfo_.weight != 0, "Weight not initialized");
                require(NFTW_ERC721.ownerOf(tokenId) == address(this) && worldInfo_.owner == _msgSender(), "Not your own world");
                require(worldRentInfo[i].tenant == address(0), "Ongoing rent");
                NFTW_ERC721.transferFrom(_msgSender(), address(this), tokenId);
            }
            worldInfo_.deposit = _deposit;
            worldInfo_.rentalPerDay = _rentalPerDay;
            worldInfo_.minRentDays = _minRentDays;
            worldInfo_.rentableUntil = _rentableUntil;
            worldInfo[i] = worldInfo_;
        }
    }


    function unstake(uint[] calldata tokenIds) external virtual {
        uint totalWeights = 0;
        for (uint i = 0; i < tokenIds.length; i++) {
            WorldInfo memory worldInfo_ = worldInfo[i];
            { // scope to avoid stack too deep errors
                uint tokenId = tokenIds[i];
                require(worldInfo_.owner == _msgSender(), "Not your own world");
                require(worldRentInfo[i].tenant == address(0), "Ongoing rent");
                NFTW_ERC721.transferFrom(address(this), _msgSender(), tokenId);
            
                emit WorldUnstaked(tokenId, _msgSender());
            }
            totalWeights += worldInfo_.weight;
            worldInfo_.owner = address(0);
            worldInfo_.deposit = 0;
            worldInfo_.rentalPerDay = 0;
            worldInfo_.minRentDays = 0;
            worldInfo_.rentableUntil = 0;
            worldInfo[i] = worldInfo_;
            
        }
        // update rewards
        _updateRewardsPerWeight(totalWeights.toUint32(), false);
        _updateUserRewards(_msgSender(), totalWeights.toUint32(), false);
        // burn veWRLD
        _burn(_msgSender(), tokenIds.length * 1e18);
    }


    // Can be used by tenant to initiate rent and extend rental period
    // paymentAlert is the number of seconds before an alert can be rentalPerDay
    // payment unit in ether
    function rentWorld(uint tokenId, uint32 _paymentAlert, uint32 initialPayment) external virtual nonReentrant {
        WorldInfo memory worldInfo_ = worldInfo[tokenId];
        WorldRentInfo memory worldRentInfo_ = worldRentInfo[tokenId];
        require(uint(worldInfo_.rentableUntil) > block.timestamp + worldInfo_.minRentDays * 86400, "Not available");
        require(worldRentInfo_.tenant == address(0), "Ongoing rent");
        // should pay at least deposit + 1 day of rent
        require(uint(initialPayment) > uint(worldInfo_.deposit + worldInfo_.rentalPerDay), "Payment amount insufficient");
        // prevent the user from paying too much
        // block.timestamp casts it into uint256 which is desired
        uint paymentAmount = Math.min((worldInfo_.rentableUntil - block.timestamp) * worldInfo_.rentalPerDay / 86400 
                                            + worldInfo_.deposit, 
                                    uint(initialPayment));
        worldRentInfo_.tenant = _msgSender();
        worldRentInfo_.rentStartTime = block.timestamp.toUint32();
        worldRentInfo_.rentalPaid += paymentAmount.toUint32();
        worldRentInfo_.paymentAlert = _paymentAlert;
        TransferHelper.safeTransferFrom(WRLD_ERC20_ADDR, _msgSender(), worldInfo_.owner, paymentAmount * 1e18);
        worldRentInfo[tokenId] = worldRentInfo_;
        emit WorldRented(tokenId, _msgSender(), paymentAmount * 1e18);
    }

    // Used by tenant to pay rent in advance. As soon as the tenant defaults the renter can vacate the tenant
    // payment unit in ether
    function payRent(uint tokenId, uint32 payment) external virtual nonReentrant {
        WorldInfo memory worldInfo_ = worldInfo[tokenId];
        WorldRentInfo memory worldRentInfo_ = worldRentInfo[tokenId];
        require(worldRentInfo_.tenant == _msgSender(), "Not rented");
        // prevent the user from paying too much
        uint paymentAmount = Math.min(uint(worldInfo_.rentableUntil - worldRentInfo_.rentStartTime) * worldInfo_.rentalPerDay / 86400
                                                + worldInfo_.deposit - worldRentInfo_.rentalPaid, 
                                    uint(payment));
        worldRentInfo_.rentalPaid += paymentAmount.toUint32();
        TransferHelper.safeTransferFrom(WRLD_ERC20_ADDR, _msgSender(), worldInfo_.owner, paymentAmount * 1e18);
        worldRentInfo[tokenId] = worldRentInfo_;
        emit RentalPaid(tokenId, _msgSender(), paymentAmount * 1e18);
    }

    // Verified builder can update any world on client's behalf. Abuse will be punished.
    function builderMetadataUpdate(uint tokenId, string calldata _tokenMetadataIPFSHash) external virtual onlyRole(VERIFIED_BUILDER_ROLE) {
        NFTW_ERC721.updateMetadataIPFSHash(tokenId, _tokenMetadataIPFSHash);
        emit BuilderMetadataUpdate(tokenId, _msgSender());
    }

    // Update metadata of staked or rented world
    function updateMetadata(uint tokenId, string calldata _tokenMetadataIPFSHash) external virtual {
        require((worldRentInfo[tokenId].tenant == address(0) && worldInfo[tokenId].owner == _msgSender()) ||
                worldRentInfo[tokenId].tenant == _msgSender(), "Not owned or rented");
        NFTW_ERC721.updateMetadataIPFSHash(tokenId, _tokenMetadataIPFSHash);
    }

    // Used by renter to vacate tenant in case of default
    // If payment + deposit covers minRentDays then deposit can be used as rent. Otherwise rent has to be provided in addition to the deposit.
    // If rental period is shorter than minRentDays then deposit will be forfeited.
    function terminateRental(uint tokenId) external virtual {
        WorldInfo memory worldInfo_ = worldInfo[tokenId];
        WorldRentInfo memory worldRentInfo_ = worldRentInfo[tokenId];
        uint rentalPaidSeconds = uint(worldRentInfo_.rentalPaid) * 86400 / worldInfo_.rentalPerDay;
        bool fundSufficient = rentalPaidSeconds > Math.max(worldInfo_.minRentDays * 86400, block.timestamp - worldRentInfo_.rentStartTime)
                || rentalPaidSeconds - uint(worldInfo_.deposit) * 86400 / worldInfo_.rentalPerDay > block.timestamp - worldRentInfo_.rentStartTime;
        require(!fundSufficient, "Ongoing rent");
        worldRentInfo_.tenant = address(0);
        worldRentInfo_.rentStartTime = 0;
        worldRentInfo_.rentalPaid = 0;
        worldRentInfo_.paymentAlert = 0;
        worldRentInfo[tokenId] = worldRentInfo_;
    }

    // view function payment alert
    function paymentAlert(uint tokenId) public view virtual returns(int256 timeRemaining) {
        WorldInfo memory worldInfo_ = worldInfo[tokenId];
        WorldRentInfo memory worldRentInfo_ = worldRentInfo[tokenId];
        uint rentalPaidSeconds = uint(worldRentInfo_.rentalPaid) * 86400 / worldInfo_.rentalPerDay;
        bool fundExceedsMin = rentalPaidSeconds > Math.max(worldInfo_.minRentDays * 86400, block.timestamp - worldRentInfo_.rentStartTime);
        timeRemaining = int(uint(worldRentInfo_.rentStartTime)) + int(rentalPaidSeconds) - int(block.timestamp) 
                        - int(fundExceedsMin ? 0 : uint(worldInfo_.deposit) * 86400 / worldInfo_.rentalPerDay);
    }

    // Claim all rewards from caller into a given address
    function claim(address to) external virtual {
        _updateRewardsPerWeight(0, false);
        uint rewardAmount = _updateUserRewards(_msgSender(), 0, false);
        rewards[_msgSender()].accumulated = 0;
        TransferHelper.safeTransfer(WRLD_ERC20_ADDR, to, rewardAmount);
        emit RewardClaimed(to, rewardAmount);
    }

    // ======== View only functions ========

    function stakedWeight(address user) external virtual view returns(uint) {
        return rewards[user].stakedWeight;
    }

    function getRewardRate() external virtual view returns(uint) {
        return rewardsPerWeight.rate;
    }

    function checkUserRewards(address user) external virtual view returns(uint) {
        RewardsPerWeight memory rewardsPerWeight_ = rewardsPerWeight;
        RewardsPeriod memory rewardsPeriod_ = rewardsPeriod;
        UserRewards memory userRewards_ = rewards[user];

        // Find out the unaccounted time
        uint32 end = min(block.timestamp.toUint32(), rewardsPeriod_.end);
        uint256 unaccountedTime = end - rewardsPerWeight_.lastUpdated; // Cast to uint256 to avoid overflows later on
        if (unaccountedTime != 0) {

            // Calculate and update the new value of the accumulator. unaccountedTime casts it into uint256, which is desired.
            // If the first mint happens mid-program, we don't update the accumulator, no one gets the rewards for that period.
            if (rewardsPerWeight_.totalWeight != 0) {
                rewardsPerWeight_.accumulated = (rewardsPerWeight_.accumulated + unaccountedTime * rewardsPerWeight_.rate / rewardsPerWeight_.totalWeight).toUint96();
            }
            rewardsPerWeight_.lastUpdated = end;
        }
        // Calculate and update the new value user reserves. userRewards_.stakedWeight casts it into uint256, which is desired.
        userRewards_.accumulated = userRewards_.accumulated + userRewards_.stakedWeight * (rewardsPerWeight_.accumulated - userRewards_.checkpoint);
        userRewards_.checkpoint = rewardsPerWeight_.accumulated;
        return userRewards_.accumulated;
    }

    function version() external virtual view returns(string memory) {
        return "1.0.0";
    }

    // ======== internal functions ========

    function _verifySignerSignature(bytes32 hash, bytes calldata signature) internal view returns(bool) {
        return hash.toEthSignedMessageHash().recover(signature) == signer;
    }

    function min(uint32 x, uint32 y) internal pure returns (uint32 z) {
        z = (x < y) ? x : y;
    }



    // Updates the rewards per weight accumulator.
    // Needs to be called on each staking/unstaking event.
    function _updateRewardsPerWeight(uint32 weight, bool increase) internal virtual {
        RewardsPerWeight memory rewardsPerWeight_ = rewardsPerWeight;
        RewardsPeriod memory rewardsPeriod_ = rewardsPeriod;

        // We skip the update if the program hasn't started
        if (block.timestamp.toUint32() >= rewardsPeriod_.start) {

            // Find out the unaccounted time
            uint32 end = min(block.timestamp.toUint32(), rewardsPeriod_.end);
            uint256 unaccountedTime = end - rewardsPerWeight_.lastUpdated; // Cast to uint256 to avoid overflows later on
            if (unaccountedTime != 0) {

                // Calculate and update the new value of the accumulator.
                // If the first mint happens mid-program, we don't update the accumulator, no one gets the rewards for that period.
                if (rewardsPerWeight_.totalWeight != 0) {
                    rewardsPerWeight_.accumulated = (rewardsPerWeight_.accumulated + unaccountedTime * rewardsPerWeight_.rate / rewardsPerWeight_.totalWeight).toUint96();
                }
                rewardsPerWeight_.lastUpdated = end;
            }
        }
        if (increase) {
            rewardsPerWeight_.totalWeight += weight;
        }
        else {
            rewardsPerWeight_.totalWeight -= weight;
        }
        rewardsPerWeight = rewardsPerWeight_;
        emit RewardsPerWeightUpdated(rewardsPerWeight_.accumulated);
    }

    // Accumulate rewards for an user.
    // Needs to be called on each staking/unstaking event.
    function _updateUserRewards(address user, uint32 weight, bool increase) internal virtual returns (uint96) {
        UserRewards memory userRewards_ = rewards[user];
        RewardsPerWeight memory rewardsPerWeight_ = rewardsPerWeight;
        
        // Calculate and update the new value user reserves.
        userRewards_.accumulated = userRewards_.accumulated + userRewards_.stakedWeight * (rewardsPerWeight_.accumulated - userRewards_.checkpoint);
        userRewards_.checkpoint = rewardsPerWeight_.accumulated;

        if (increase) {
            userRewards_.stakedWeight += weight;
        }
        else {
            userRewards_.stakedWeight -= weight;
        }
        rewards[user] = userRewards_;
        emit WeightUpdated(user, increase, weight, block.timestamp);
        emit UserRewardsUpdated(user, userRewards_.accumulated, userRewards_.checkpoint);

        return userRewards_.accumulated;
    }


    // ======== function overrides ========

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override
    {
        require(from == address(0) || to == address(0), "ERC20: Non-transferrable");
        super._beforeTokenTransfer(from, to, amount);
    }

    // The following functions are overrides required by Solidity.

    function _afterTokenTransfer(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._afterTokenTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._mint(to, amount);
    }

    function _burn(address account, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._burn(account, amount);
    }

}


/**
    helper methods for interacting with ERC20 tokens that do not consistently return true/false
    with the addition of a transfer function to send eth or an erc20 token
*/
library TransferHelper {
    function safeApprove(address token, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper: APPROVE_FAILED");
    }

    function safeTransfer(address token, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper: TRANSFER_FAILED");
    }

    function safeTransferFrom(address token, address from, address to, uint value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper: TRANSFER_FROM_FAILED");
    }
    
    // sends ETH or an erc20 token
    function safeTransferBaseToken(address token, address payable to, uint value, bool isERC20) internal {
        if (!isERC20) {
            to.transfer(value);
        } else {
            (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
            require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferHelper: TRANSFER_FAILED");
        }
    }
}