// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "ds-test/test.sol";
import "./utils/console.sol";
import "./utils/hevm.sol";

import "./mock/MockNFTW721.sol";
import "./mock/MockWRLD20.sol";
import "../NFTWEscrow.sol";
import "../NFTWRental.sol";

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract NFTWEscrowRentalTest is DSTest {
    using ECDSA for bytes32;
    MockWRLD mockWRLD;
    MockNFTW721 mockNFTW721;
    NFTWEscrow nftwEscrow;
    NFTWRental nftwRental;

    address user0 = 0x394A254f38552e2F24Eb5810A265DCA9b5D7A4F1;
    uint pk0 = uint(0xbdcbe4077846330fcb39a49e31b6d3990aeeaccf5ae7ab50ffb6cff553e351ec);
    address[4] users = [0xEF773563067F02cc3101DB321844bE6da15D6Ed8, 
                        0x9130d1023faAA4a63D256709DC2FE0B1001FEc54, 
                        0x111306dAe6B7f2b51573F581257a8CE4bf18Fea8, 
                        0xF88401f7856a79979Bb37F886eD210957F996642];

    Hevm constant hevm  = Hevm(address(bytes20(uint160(uint256(keccak256('hevm cheat code'))))));

    function setUp() public {
        // deploy
        mockWRLD = new MockWRLD();
        mockNFTW721 = new MockNFTW721();
        nftwEscrow = new NFTWEscrow(address(mockWRLD), address(mockNFTW721));
        nftwRental = new NFTWRental(address(mockWRLD), nftwEscrow);
        nftwEscrow.setSigner(user0);
        nftwEscrow.setRentalContract(nftwRental);

        hevm.warp(1643500000);

        // mint some tokens to test accounts
        mockNFTW721.safeMint(users[0],1);
        mockNFTW721.safeMint(users[0],2);
        mockNFTW721.safeMint(users[0],3);
        mockNFTW721.safeMint(users[1],4);
        mockNFTW721.safeMint(users[1],5);

        mockWRLD.mint(address(nftwEscrow), 500000000 ether);
        mockWRLD.mint(users[2], 5000000 ether);
        mockWRLD.mint(users[3], 5000000 ether);

        // approvals
        hevm.prank(users[0]);
        mockNFTW721.setApprovalForAll(address(nftwEscrow), true);
        hevm.prank(users[1]);
        mockNFTW721.setApprovalForAll(address(nftwEscrow), true);
        hevm.prank(users[2]);
        mockWRLD.approve(address(nftwRental), 10000000 ether);
        hevm.prank(users[3]);
        mockWRLD.approve(address(nftwRental), 10000000 ether);
    }

    function initializeWeights() public {
        uint[] memory tokenIds = new uint[](5);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        tokenIds[2] = 3;
        tokenIds[3] = 4;
        tokenIds[4] = 5;
        uint[] memory weights = new uint[](5);
        weights[0] = 40000;
        weights[1] = 10000;
        weights[2] = 20000;
        weights[3] = 30000;
        weights[4] = 20000;
        nftwEscrow.setWeight(tokenIds,weights);
    }

    function mintInitialized(uint startId, uint n, address to) public {
        uint[] memory tokenIds = new uint[](n);
        uint[] memory weights = new uint[](n);
        for (uint i = 0; i < n; i++) {
            mockNFTW721.safeMint(to,startId+i);
            tokenIds[i] = startId+i;
            weights[i] = 10000+i;
        }
        nftwEscrow.setWeight(tokenIds,weights);
    }

    function testFailDirectTransfer() public {
        hevm.startPrank(users[0]);
        mockNFTW721.safeTransferFrom(users[0], address(nftwEscrow), 1);
    }

    function testInitialStake(uint16 x, uint16 y) public {
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        uint[] memory weights = new uint[](2);
        weights[0] = x;
        weights[1] = y;
        uint32 _maxTimestamp = uint32(1643535900);
        bytes32 hash = keccak256(abi.encode(tokenIds, weights, users[0], _maxTimestamp, address(nftwEscrow)));
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(pk0, hash.toEthSignedMessageHash());
        assertTrue(hash.toEthSignedMessageHash().recover(abi.encodePacked(r,s,v)) == user0); // signature valid

        hevm.startPrank(users[0]);
        nftwEscrow.initialStake(tokenIds, weights, users[0], 0, 0, 0, 0, _maxTimestamp, abi.encodePacked(r,s,v)); // can stake
        {
            (uint32 totalWeight, uint96 b, uint32 c, uint96 d) = nftwEscrow.rewardsPerWeight();
            assertEq(uint(totalWeight), uint(x) + uint(y));
        }
        {
            (uint32 stakedWeight, uint96 e, uint96 f) = nftwEscrow.rewards(users[0]);
            assertEq(uint(stakedWeight), uint(x) + uint(y));
        }
        assertEq(nftwEscrow.balanceOf(users[0]), 2 ether);
    }

    function testInitialStake2() public { // input length attack
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = 1;
        uint[] memory weights = new uint[](3);
        weights[0] = 2;
        weights[1] = 40000;
        weights[2] = 10000;
        uint32 _maxTimestamp = uint32(1643535900);
        bytes32 hash = keccak256(abi.encode(tokenIds, weights, users[0], _maxTimestamp, address(nftwEscrow)));
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(pk0, hash.toEthSignedMessageHash());
        assertTrue(hash.toEthSignedMessageHash().recover(abi.encodePacked(r,s,v)) == user0);

        hevm.prank(users[0]);
        hevm.expectRevert(bytes("E6"));
        nftwEscrow.initialStake(tokenIds, weights, users[0], 0, 0, 0, 0, _maxTimestamp, abi.encodePacked(r,s,v));
    }

    function testInitialStake3() public {
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        uint[] memory weights = new uint[](2);
        weights[0] = 40000;
        weights[1] = 10000;
        uint32 _maxTimestamp = uint32(1643535900);
        bytes32 hash = keccak256(abi.encode(tokenIds, weights, users[0], _maxTimestamp, address(nftwEscrow)));
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(pk0, hash.toEthSignedMessageHash());
        assertTrue(hash.toEthSignedMessageHash().recover(abi.encodePacked(r,s,v)) == user0);

        hevm.prank(users[0]);
        hevm.warp(1643535901); // expire timestamp
        hevm.expectRevert(bytes("EX"));
        nftwEscrow.initialStake(tokenIds, weights, users[0], 0, 0, 0, 0, _maxTimestamp, abi.encodePacked(r,s,v));
    }

    function testInitialStake4() public {
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        uint[] memory weights = new uint[](2);
        weights[0] = 40000;
        weights[1] = 10000;
        uint32 _maxTimestamp = uint32(1643535900);
        bytes32 hash = keccak256(abi.encode(tokenIds, weights, users[1], _maxTimestamp, address(nftwEscrow)));
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(pk0, hash.toEthSignedMessageHash());
        assertTrue(hash.toEthSignedMessageHash().recover(abi.encodePacked(r,s,v)) == user0);

        hevm.prank(users[1]);
        hevm.expectRevert(bytes("E9"));
        nftwEscrow.initialStake(tokenIds, weights, users[1], 0, 0, 0, 0, _maxTimestamp, abi.encodePacked(r,s,v)); // not own world
    }

    function testStake() public {
        initializeWeights();
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        hevm.prank(users[0]);
        nftwEscrow.stake(tokenIds, users[1], 1, 2, 3, 4); // can stake to someone else
        {
            (uint32 totalWeight, uint96 b, uint32 c, uint96 d) = nftwEscrow.rewardsPerWeight();
            assertEq(uint(totalWeight), 50000);
        }
        {
            (uint32 stakedWeight, uint96 e, uint96 f) = nftwEscrow.rewards(users[1]);
            assertEq(uint(stakedWeight), 50000);
        }
        assertEq(nftwEscrow.balanceOf(users[0]), 0 ether);
        assertEq(nftwEscrow.balanceOf(users[1]), 2 ether);

        hevm.prank(users[1]);
        hevm.expectRevert("ERC20: Non-transferrable");
        nftwEscrow.transfer(users[0], 1 ether);

        hevm.prank(users[1]);
        nftwEscrow.updateRent(tokenIds,2,3,4,5); // can update rent
        hevm.expectRevert(bytes("E9"));
        hevm.prank(users[0]);
        nftwEscrow.unstake(tokenIds,users[0]); // can't unstake for someone else
        hevm.prank(users[1]);
        nftwEscrow.unstake(tokenIds,users[0]); // can unstake
        assertEq(nftwEscrow.balanceOf(users[1]), 0 ether);
    }

    function testStake1() public { // test error paths
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        hevm.expectRevert(bytes("ET"));
        nftwEscrow.stake(tokenIds, address(mockWRLD), 0, 0, 0, 0);

        hevm.expectRevert(bytes("ES"));
        nftwEscrow.stake(tokenIds, address(nftwEscrow), 0, 0, 0, 0);

        hevm.prank(users[0]);
        hevm.expectRevert(bytes("EA"));
        nftwEscrow.stake(tokenIds, users[0], 0, 0, 0, 0);

        initializeWeights();
        hevm.prank(users[1]);
        hevm.expectRevert(bytes("E9"));
        nftwEscrow.stake(tokenIds, users[0], 0, 0, 0, 0);
    }

    function testStake2() public { // test staking/unstaking same token multiple times
        initializeWeights();
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        hevm.startPrank(users[0]);
        nftwEscrow.stake(tokenIds, users[0], 0, 0, 0, 0);

        hevm.expectRevert(bytes("E9"));
        nftwEscrow.stake(tokenIds, users[0], 0, 0, 0, 0);

        nftwEscrow.unstake(tokenIds,users[0]);

        hevm.expectRevert(bytes("E9"));
        nftwEscrow.unstake(tokenIds,users[0]);

        nftwEscrow.stake(tokenIds, users[0], 0, 0, 0, 0);

        hevm.expectRevert(bytes("E9"));
        nftwEscrow.stake(tokenIds, users[0], 0, 0, 0, 0);
    }

    function testGasProfile() public {
        initializeWeights();
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = 1;

        hevm.prank(users[0]);
        nftwEscrow.stake(tokenIds, users[2], 1, 2, 3, 4);

        tokenIds[0] = 4;

        hevm.prank(users[1]);
        uint startGas = gasleft();
        nftwEscrow.stake(tokenIds, users[2], 1, 2, 3, 4);
        uint endGas = gasleft();
        console.log("Staking gas for 1:", startGas - endGas);
        startGas = gasleft();
        hevm.prank(users[2]);
        nftwEscrow.unstake(tokenIds,users[0]);
        console.log("Unstaking gas for 1:", startGas - gasleft());
    }

    function testGasProfile1() public {
        initializeWeights();
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        hevm.prank(users[0]);
        nftwEscrow.stake(tokenIds, users[2], 1, 2, 3, 4);

        tokenIds[0] = 4;
        tokenIds[1] = 5;

        hevm.prank(users[1]);
        uint startGas = gasleft();
        nftwEscrow.stake(tokenIds, users[2], 1, 2, 3, 4);
        console.log("Staking gas for 2:", startGas - gasleft());
        startGas = gasleft();
        hevm.prank(users[2]);
        nftwEscrow.unstake(tokenIds,users[0]);
        console.log("Unstaking gas for 2:", startGas - gasleft());
    }

    function testGasProfile2() public {
        initializeWeights();
        mintInitialized(6,50,users[1]);
        assertGt(mockNFTW721.balanceOf(users[1]), 50);
        uint[] memory tokenIds0 = new uint[](2);
        tokenIds0[0] = 1;
        tokenIds0[1] = 2;

        hevm.prank(users[0]);
        nftwEscrow.stake(tokenIds0, users[2], 1, 2, 3, 4);

        uint[] memory tokenIds = new uint[](50);
        for (uint i = 0; i < 50; i++) {
            tokenIds[i] = 6+i;
        }


        hevm.prank(users[1]);
        uint startGas = gasleft();
        nftwEscrow.stake(tokenIds, users[2], 1, 2, 3, 4);
        console.log("Staking gas for 50:", startGas - gasleft());
        startGas = gasleft();
        hevm.prank(users[2]);
        nftwEscrow.unstake(tokenIds,users[0]);
        console.log("Unstaking gas for 50:", startGas - gasleft());
    }

    function testRewards() public {
        initializeWeights();
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        hevm.prank(users[0]);
        nftwEscrow.stake(tokenIds, users[2], 1, 2, 3, 4);

        tokenIds[0] = 4;
        tokenIds[1] = 5;

        hevm.prank(users[1]);
        nftwEscrow.stake(tokenIds, users[3], 1, 2, 3, 4);

        nftwEscrow.setRewards(1643500000, 1643600000, 1 ether);

        hevm.warp(1643501000);
        assertEq(nftwEscrow.checkUserRewards(users[2]), 500 ether);
        assertEq(nftwEscrow.checkUserRewards(users[3]), 500 ether);

        hevm.prank(users[2]);
        nftwEscrow.claim(users[1]);
        assertEq(nftwEscrow.checkUserRewards(users[2]), 0 ether);
        assertEq(mockWRLD.balanceOf(users[1]), 500 ether);

        hevm.warp(1643502000);
        assertEq(nftwEscrow.checkUserRewards(users[2]), 500 ether);
        assertEq(nftwEscrow.checkUserRewards(users[3]), 1000 ether);

        hevm.prank(users[3]);
        nftwEscrow.unstake(tokenIds,users[0]);
        hevm.warp(1643503000);
        assertEq(nftwEscrow.checkUserRewards(users[2]), 1500 ether);
        assertEq(nftwEscrow.checkUserRewards(users[3]), 1000 ether);
    }

    function testRent() public {
        initializeWeights();
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        hevm.prank(users[0]);
        hevm.expectRevert(bytes("ER"));
        nftwEscrow.stake(tokenIds, users[1], 4001, 1000, 3, 1644364000); // deposit too high
        hevm.prank(users[0]);
        nftwEscrow.stake(tokenIds, users[1], 4000, 1000, 3, 1644364000); // 4k deposit, 1k daily rent, 3 days min, 10 days max

        hevm.startPrank(users[2]);
        hevm.expectRevert(bytes("ED"));
        nftwRental.rentWorld(1, 1000000, 1000); // too little
        nftwRental.rentWorld(1, 1000000, 6000);
        assertEq(mockWRLD.balanceOf(users[1]), 6000 ether);
        assertEq(mockWRLD.balanceOf(users[2]), (5000000-6000)*1e18);
        assertEq(nftwRental.rentalPaidUntil(1), 1644018400); // paid 6 days

        nftwRental.payRent(1, 1000); // can pay rent
        assertEq(mockWRLD.balanceOf(users[1]), 7000 ether);
        assertEq(nftwRental.rentalPaidUntil(1), 1644104800); // paid 7 days
        hevm.prank(users[1]);
        hevm.expectRevert(bytes("EE"));
        nftwRental.payRent(1, 1000); // can't pay rent for someone else
        assertEq(mockWRLD.balanceOf(users[1]), 7000 ether);

        nftwRental.payRent(1, 10000); // can pay rent but not too much
        assertEq(mockWRLD.balanceOf(users[1]), 10000 ether); // don't pay to much
        assertEq(mockWRLD.balanceOf(users[2]), (5000000-10000)*1e18);
        assertEq(nftwRental.rentalPaidUntil(1), 1644364000); // paid 10 days

        hevm.prank(users[3]);
        hevm.expectRevert(bytes("EB"));
        nftwRental.rentWorld(1, 1000000, 1000); // can't rent when went active

        hevm.prank(users[1]);
        hevm.expectRevert(bytes("EB"));
        nftwRental.terminateRental(1); // can't terminate before end

        hevm.warp(1644364001); // end of rentableUntil
        hevm.expectRevert(bytes("E9"));
        nftwRental.terminateRental(1); // can't terminate for someone else
        hevm.prank(users[1]);
        nftwRental.terminateRental(1); // can terminate

        hevm.expectRevert(bytes("EC"));
        nftwRental.rentWorld(1, 1000000, 1000); // can't rent anymore
    }

    function testRent2() public {
        initializeWeights();
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        hevm.prank(users[0]);
        nftwEscrow.stake(tokenIds, users[1], 4000, 1000, 3, 1644364000); // 4k deposit, 1k daily rent, 3 days min, 10 days max

        hevm.startPrank(users[2]);
        nftwRental.rentWorld(1, 1000000, 200000);
        assertEq(mockWRLD.balanceOf(users[1]), 10000 ether); // don't pay to much
        assertEq(mockWRLD.balanceOf(users[2]), (5000000-10000)*1e18);

    }

    function testRent3() public {
        initializeWeights();
        uint[] memory tokenIds = new uint[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        hevm.prank(users[0]);
        nftwEscrow.stake(tokenIds, users[1], 0, 0, 0, 1644364000); // free rent, 10 days max

        hevm.startPrank(users[2]);
        nftwRental.rentWorld(1, 1000000, 200000);
        assertEq(mockWRLD.balanceOf(users[1]), 0 ether); // don't pay to much
        assertEq(mockWRLD.balanceOf(users[2]), (5000000)*1e18);

        hevm.startPrank(users[1]);
        hevm.expectRevert(bytes("EB"));
        nftwEscrow.unstake(tokenIds,users[0]);
        hevm.expectRevert(bytes("EB"));
        nftwRental.terminateRental(1);

        hevm.warp(1644364001); // end of rentableUntil
        nftwRental.terminateRental(1);
        nftwEscrow.unstake(tokenIds,users[0]);
    }


}
