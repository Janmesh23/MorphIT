// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// import "@openzeppelin/contracts/access/Ownable.sol";
// import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./UsernameRegistry.sol";
import "./MeshUSD.sol";
import "./MeshToken.sol";

contract MerchantTerminal is ReentrancyGuard {
    MeshUSD public meshUSD;
    MeshToken public meshToken;
    
    mapping(address => bool) public registeredMerchants;
    mapping(address => uint256) public merchantVolume;
    
    uint256 public constant CASHBACK_RATE = 200; // 2% = 200 basis points
    uint256 public constant BASIS_POINTS = 10000;
    
    event MerchantRegistered(address indexed merchant);
    event MerchantPaid(address indexed customer, address indexed merchant, uint256 amount);
    event CashbackRewarded(address indexed customer, uint256 cashbackAmount);

    constructor(address _meshUSD, address _meshToken) {
        meshUSD = MeshUSD(_meshUSD);
        meshToken = MeshToken(_meshToken);
    }

    function registerMerchant() external {
        require(!registeredMerchants[msg.sender], "Already registered");
        registeredMerchants[msg.sender] = true;
        emit MerchantRegistered(msg.sender);
    }

    function pay(address merchant, uint256 amount) external nonReentrant {
        require(registeredMerchants[merchant], "Not a valid merchant");
        require(amount > 0, "Amount must be greater than 0");
        require(merchant != msg.sender, "Cannot pay yourself");
        
        // Transfer payment to merchant
        require(meshUSD.transferFrom(msg.sender, merchant, amount), "Payment failed");
        
        // Update merchant volume
        merchantVolume[merchant] += amount;
        
        // Calculate and mint cashback
        uint256 cashbackAmount = (amount * CASHBACK_RATE) / BASIS_POINTS;
        if (cashbackAmount > 0) {
            meshToken.mint(msg.sender, cashbackAmount);
            emit CashbackRewarded(msg.sender, cashbackAmount);
        }
        
        emit MerchantPaid(msg.sender, merchant, amount);
    }
}
