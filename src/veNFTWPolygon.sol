// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";


contract veNFTW_Polygon is Context, ERC20, ERC20Permit, ERC20Votes, Ownable {

    address public childChainManagerProxy;

    /**
    * address _childChainManagerProxy: The trusted polygon contract address for bridge deposits
    */

    constructor(address _childChainManagerProxy)
    ERC20("Vote-escrowed NFTWorld", "veNFTW") 
    ERC20Permit("Vote-escrowed NFTWorld") 
    {
        childChainManagerProxy = _childChainManagerProxy;
    }

    function deposit(address user, bytes calldata depositData) external {
        require(_msgSender() == childChainManagerProxy, "Address not allowed to deposit.");

        uint256 amount = abi.decode(depositData, (uint256));

        _mint(user, amount);
    }

    function withdraw(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    function updateChildChainManager(address _childChainManagerProxy) external onlyOwner {
        require(_childChainManagerProxy != address(0), "Bad ChildChainManagerProxy address.");

        childChainManagerProxy = _childChainManagerProxy;
    }


    /**
    * Overrides
    */

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        require(from == address(0) || to == address(0), "ERC20: Non-transferrable");
        super._beforeTokenTransfer(from, to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }

    function _msgSender() internal view override(Context) returns (address) {
        return super._msgSender();
    }

    function _msgData() internal view override(Context) returns (bytes calldata) {
        return super._msgData();
    }

    function _mint(address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._mint(to, amount);
    }

    function _burn(address account, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._burn(account, amount);
    }
}