// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// import "@openzeppelin/contracts/access/Ownable.sol";
// import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";


contract UsernameRegistry is Ownable(msg.sender) {
    mapping(string => address) public usernames;
    mapping(address => string[]) public userIdentities;
    
    event Registered(string indexed username, address indexed owner);
    event Unregistered(string indexed username, address indexed owner);

    function register(string memory username, address wallet) external onlyOwner {
        require(usernames[username] == address(0), "Username already taken");
        require(bytes(username).length > 0, "Username cannot be empty");
        
        usernames[username] = wallet;
        userIdentities[wallet].push(username);
        emit Registered(username, wallet);
    }

    function resolve(string memory username) external view returns (address) {
        return usernames[username];
    }

    function getUserIdentities(address wallet) external view returns (string[] memory) {
        return userIdentities[wallet];
    }

    function unregister(string memory username) external onlyOwner {
        address wallet = usernames[username];
        require(wallet != address(0), "Username not found");
        
        delete usernames[username];
        
        // Remove from userIdentities array
        string[] storage identities = userIdentities[wallet];
        for (uint i = 0; i < identities.length; i++) {
            if (keccak256(bytes(identities[i])) == keccak256(bytes(username))) {
                identities[i] = identities[identities.length - 1];
                identities.pop();
                break;
            }
        }
        
        emit Unregistered(username, wallet);
    }
}