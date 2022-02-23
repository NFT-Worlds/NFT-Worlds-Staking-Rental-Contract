// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./TransferHelper.sol";
import "./INFTWEscrow.sol";
import "./INFTWRental.sol";
import "./INFTW_ERC721.sol";


contract NFTWRental is Context, ERC165, INFTWRental, AccessControl, ReentrancyGuard {
    using SafeCast for uint;

    address immutable WRLD_ERC20_ADDR;
    INFTWEscrow immutable NFTWEscrow;
    WorldRentInfo[10001] public worldRentInfo; // NFTW tokenId is in N [1,10000]
    bytes32 private constant OWNER_ROLE = keccak256("OWNER_ROLE");

    // ======== Admin functions ========
    constructor(address wrld, INFTWEscrow escrow) {
        require(wrld != address(0), "E0"); // E0: addr err
        require(escrow.supportsInterface(type(INFTWEscrow).interfaceId),"E0");
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(OWNER_ROLE, _msgSender());
        WRLD_ERC20_ADDR = wrld;
        NFTWEscrow = escrow;
    }

    // Rescue ERC20 tokens sent directly to this contract
    function rescueERC20(address token, uint amount) external onlyRole(OWNER_ROLE) {
        TransferHelper.safeTransfer(token, _msgSender(), amount);
    }


    // ======== Public functions ========

    // Can be used by tenant to initiate rent
    // Can be used on a world where rental payment has expired
    // paymentAlert is the number of seconds before an alert can be rentalPerDay
    // payment unit in ether
    function rentWorld(uint tokenId, uint32 _paymentAlert, uint32 initialPayment) external virtual override nonReentrant {
        INFTWEscrow.WorldInfo memory worldInfo_ = NFTWEscrow.getWorldInfo(tokenId);
        WorldRentInfo memory worldRentInfo_ = worldRentInfo[tokenId];
        require(uint(worldInfo_.rentableUntil) >= block.timestamp + worldInfo_.minRentDays * 86400, "EC"); // EC: Not available
        if (worldRentInfo_.tenant != address(0)) { // if previously rented
            uint paidUntil = rentalPaidUntil(tokenId);
            require(paidUntil < block.timestamp, "EB"); // EB: Ongoing rent
            worldRentInfo_.rentalPaid = 0; // reset payment amount
        }
        // should pay at least deposit + 1 day of rent
        require(uint(initialPayment) >= uint(worldInfo_.deposit + worldInfo_.rentalPerDay), "ED"); // ED: Payment insufficient
        // prevent the user from paying too much
        // block.timestamp casts it into uint256 which is desired
        // if the rentable time left is less than minRentDays then the tenant just has to pay up until the time limit
        uint paymentAmount = Math.min((worldInfo_.rentableUntil - block.timestamp) * worldInfo_.rentalPerDay / 86400, 
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
    // The rental period can be extended as long as rent is prepaid, up to rentableUntil timestamp.
    // payment unit in ether
    function payRent(uint tokenId, uint32 payment) external virtual override nonReentrant {
        INFTWEscrow.WorldInfo memory worldInfo_ = NFTWEscrow.getWorldInfo(tokenId);
        WorldRentInfo memory worldRentInfo_ = worldRentInfo[tokenId];
        require(worldRentInfo_.tenant == _msgSender(), "EE"); // EE: Not rented
        // prevent the user from paying too much
        uint paymentAmount = Math.min(uint(worldInfo_.rentableUntil - worldRentInfo_.rentStartTime) * worldInfo_.rentalPerDay / 86400
                                                - worldRentInfo_.rentalPaid, 
                                    uint(payment));
        worldRentInfo_.rentalPaid += paymentAmount.toUint32();
        TransferHelper.safeTransferFrom(WRLD_ERC20_ADDR, _msgSender(), worldInfo_.owner, paymentAmount * 1e18);
        worldRentInfo[tokenId] = worldRentInfo_;
        emit RentalPaid(tokenId, _msgSender(), paymentAmount * 1e18);
    }

    // Used by renter to vacate tenant in case of default, or when rental period expires.
    // If payment + deposit covers minRentDays then deposit can be used as rent. Otherwise rent has to be provided in addition to the deposit.
    // If rental period is shorter than minRentDays then deposit will be forfeited.
    function terminateRental(uint tokenId) external override virtual {
        require(NFTWEscrow.getWorldInfo(tokenId).owner == _msgSender(), "E9"); // E9: Not your world
        uint paidUntil = rentalPaidUntil(tokenId);
        require(paidUntil < block.timestamp, "EB"); // EB: Ongoing rent
        worldRentInfo[tokenId] = WorldRentInfo(address(0),0,0,0);
    }


    // ======== View only functions ========
    function isRentActive(uint tokenId) public view override returns(bool) {
        return worldRentInfo[tokenId].tenant != address(0);
    }

    function getTenant(uint tokenId) public view override returns(address) {
        return worldRentInfo[tokenId].tenant;
    }

    function rentalPaidUntil(uint tokenId) public view virtual override returns(uint paidUntil) {
        INFTWEscrow.WorldInfo memory worldInfo_ = NFTWEscrow.getWorldInfo(tokenId);
        WorldRentInfo memory worldRentInfo_ = worldRentInfo[tokenId];
        if (worldInfo_.rentalPerDay == 0) {
            paidUntil = worldInfo_.rentableUntil;
        }
        else {
            uint rentalPaidSeconds = uint(worldRentInfo_.rentalPaid) * 86400 / worldInfo_.rentalPerDay;
            bool fundExceedsMin = rentalPaidSeconds >= Math.max(worldInfo_.minRentDays * 86400, block.timestamp - worldRentInfo_.rentStartTime);
            paidUntil = uint(worldRentInfo_.rentStartTime) + rentalPaidSeconds
                        - (fundExceedsMin ? 0 : uint(worldInfo_.deposit) * 86400 / worldInfo_.rentalPerDay);
        }
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165, AccessControl) returns (bool) {
        return interfaceId == type(INFTWRental).interfaceId || super.supportsInterface(interfaceId);
    }

}
