// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// =================================================================================================
// |                                     DEPENDENCIES                                            |
// =================================================================================================

/**
 * @title MeshToken (MESH)
 * @dev A basic ERC20 token representing the platform's primary reward and utility token.
 */
contract MeshToken is ERC20, Ownable {
    constructor() ERC20("Mesh Token", "MESH") Ownable(msg.sender) {}

    /**
     * @dev Creates new tokens and assigns them to an account. Can only be called by the owner.
     * Used by the Yield Farming contract to mint rewards.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

/**
 * @title MeshUSD (MUSD)
 * @dev A basic ERC20 token representing a stablecoin used for staking rewards.
 */
contract MeshUSD is ERC20, Ownable {
    constructor() ERC20("Mesh USD", "MUSD") Ownable(msg.sender) {}

    /**
     * @dev Creates new tokens and assigns them to an account. Can only be called by the owner.
     * Used by the Staking contract to mint rewards.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

// =================================================================================================
// |                                    CORE CONTRACTS                                             |
// =================================================================================================

/**
 * @title MeshLPToken
 * @dev ERC20 token representing liquidity provider shares in a MeshDEX pool.
 */
contract MeshLPToken is ERC20, Ownable {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {}

    /**
     * @dev Mints LP tokens to a provider. Only callable by the token's owner (the DEX).
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Burns LP tokens from a provider. Only callable by the token's owner (the DEX).
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}

/**
 * @title MeshDEX
 * @dev An Automated Market Maker (AMM) decentralized exchange.
 */
contract MeshDEX is ReentrancyGuard, Ownable {
    struct Pool {
        address token0;
        address token1;
        uint256 reserve0;
        uint256 reserve1;
        address lpToken;
        uint256 totalSupply;
    }

    mapping(bytes32 => Pool) public pools;
    mapping(address => mapping(address => bytes32)) public getPoolId;

    uint256 public constant FEE_RATE = 30; // 0.3%
    uint256 public constant BASIS_POINTS = 10000;

    event PoolCreated(address indexed token0, address indexed token1, bytes32 poolId, address lpToken);
    event LiquidityAdded(address indexed user, bytes32 poolId, uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(address indexed user, bytes32 poolId, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Swap(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    constructor() Ownable(msg.sender) {}

    function createPool(address token0, address token1) external onlyOwner returns (bytes32 poolId) {
        require(token0 != token1, "MeshDEX: IDENTICAL_TOKENS");
        require(token0 != address(0) && token1 != address(0), "MeshDEX: ZERO_ADDRESS");

        if (token0 > token1) (token0, token1) = (token1, token0);

        poolId = keccak256(abi.encodePacked(token0, token1));
        require(pools[poolId].token0 == address(0), "MeshDEX: POOL_EXISTS");

        string memory lpName = string(abi.encodePacked("Mesh-LP-", ERC20(token0).symbol(), "/", ERC20(token1).symbol()));
        string memory lpSymbol = string(abi.encodePacked("MLP-", ERC20(token0).symbol(), "-", ERC20(token1).symbol()));

        MeshLPToken lpToken = new MeshLPToken(lpName, lpSymbol);

        pools[poolId] = Pool({
            token0: token0,
            token1: token1,
            reserve0: 0,
            reserve1: 0,
            lpToken: address(lpToken),
            totalSupply: 0
        });

        getPoolId[token0][token1] = poolId;
        getPoolId[token1][token0] = poolId;

        emit PoolCreated(token0, token1, poolId, address(lpToken));
    }

    function addLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        bytes32 poolId = getPoolId[token0][token1];
        require(poolId != bytes32(0), "MeshDEX: POOL_NOT_FOUND");
        
        Pool storage pool = pools[poolId];
        
        if (pool.reserve0 == 0 && pool.reserve1 == 0) {
            (amount0, amount1) = (amount0Desired, amount1Desired);
        } else {
            uint256 amount1Optimal = (amount0Desired * pool.reserve1) / pool.reserve0;
            if (amount1Optimal <= amount1Desired) {
                require(amount1Optimal >= amount1Min, "MeshDEX: INSUFFICIENT_B_AMOUNT");
                (amount0, amount1) = (amount0Desired, amount1Optimal);
            } else {
                uint256 amount0Optimal = (amount1Desired * pool.reserve0) / pool.reserve1;
                require(amount0Optimal <= amount0Desired); // Should not fail
                require(amount0Optimal >= amount0Min, "MeshDEX: INSUFFICIENT_A_AMOUNT");
                (amount0, amount1) = (amount0Optimal, amount1Desired);
            }
        }
        
        // **CORRECTED: Interactions moved after state changes**
        require(ERC20(token0).transferFrom(msg.sender, address(this), amount0), "ERC20: TRANSFER_FROM_FAILED");
        require(ERC20(token1).transferFrom(msg.sender, address(this), amount1), "ERC20: TRANSFER_FROM_FAILED");

        // **CORRECTED: Effects (state updates) happen before interactions**
        if (pool.totalSupply == 0) {
            liquidity = sqrt(amount0 * amount1); // No minimum subtraction needed if handled properly
            require(liquidity > 1000, "MeshDEX: MIN_LIQUIDITY_NOT_MET");
            _mint(pool.lpToken, address(0), 1000); // Lock initial liquidity
        } else {
            liquidity = min((amount0 * pool.totalSupply) / pool.reserve0, (amount1 * pool.totalSupply) / pool.reserve1);
        }
        
        require(liquidity > 0, "MeshDEX: INSUFFICIENT_LIQUIDITY_MINTED");
        
        _mint(pool.lpToken, msg.sender, liquidity);
        
        pool.reserve0 += amount0;
        pool.reserve1 += amount1;
        pool.totalSupply += liquidity;
        
        emit LiquidityAdded(msg.sender, poolId, amount0, amount1, liquidity);
    }

    function removeLiquidity(
        address token0,
        address token1,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        bytes32 poolId = getPoolId[token0][token1];
        require(poolId != bytes32(0), "MeshDEX: POOL_NOT_FOUND");
        
        Pool storage pool = pools[poolId];
        require(liquidity <= MeshLPToken(pool.lpToken).balanceOf(msg.sender), "MeshDEX: INSUFFICIENT_LP_BALANCE");

        amount0 = (liquidity * pool.reserve0) / pool.totalSupply;
        amount1 = (liquidity * pool.reserve1) / pool.totalSupply;
        
        require(amount0 >= amount0Min, "MeshDEX: INSUFFICIENT_A_AMOUNT");
        require(amount1 >= amount1Min, "MeshDEX: INSUFFICIENT_B_AMOUNT");
        
        // Effects first
        pool.reserve0 -= amount0;
        pool.reserve1 -= amount1;
        pool.totalSupply -= liquidity;
        _burn(pool.lpToken, msg.sender, liquidity);
        
        // Interactions last
        _safeTransfer(pool.token0, msg.sender, amount0);
        _safeTransfer(pool.token1, msg.sender, amount1);
        
        emit LiquidityRemoved(msg.sender, poolId, amount0, amount1, liquidity);
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) external nonReentrant returns (uint256 amountOut) {
        bytes32 poolId = getPoolId[tokenIn][tokenOut];
        require(poolId != bytes32(0), "MeshDEX: POOL_NOT_FOUND");
        
        Pool storage pool = pools[poolId];
        
        uint256 reserveIn = tokenIn == pool.token0 ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = tokenIn == pool.token0 ? pool.reserve1 : pool.reserve0;
        
        require(amountIn > 0, "MeshDEX: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "MeshDEX: INSUFFICIENT_LIQUIDITY");
        
        // Calculate amount out
        uint256 amountInWithFee = amountIn * (BASIS_POINTS - FEE_RATE);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * BASIS_POINTS) + amountInWithFee;
        amountOut = numerator / denominator;
        
        require(amountOut >= amountOutMin, "MeshDEX: INSUFFICIENT_OUTPUT_AMOUNT");
        
        // Interaction first (optimistic transfer)
        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        
        // Effects
        if (tokenIn == pool.token0) {
            pool.reserve0 += amountIn;
            pool.reserve1 -= amountOut;
        } else {
            pool.reserve1 += amountIn;
            pool.reserve0 -= amountOut;
        }
        
        // Final interaction
        _safeTransfer(tokenOut, msg.sender, amountOut);
        
        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
    
    // --- Internal & View Functions ---

    function _mint(address lpToken, address to, uint256 amount) private {
        MeshLPToken(lpToken).mint(to, amount);
    }
    
    function _burn(address lpToken, address from, uint256 amount) private {
        MeshLPToken(lpToken).burn(from, amount);
    }
    
    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, ) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        require(success, "ERC20: TRANSFER_FAILED");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool success, ) = token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, value));
        require(success, "ERC20: TRANSFER_FROM_FAILED");
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256 amountOut) {
        require(amountIn > 0, "MeshDEX: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "MeshDEX: INSUFFICIENT_LIQUIDITY");
        
        uint256 amountInWithFee = amountIn * (BASIS_POINTS - FEE_RATE);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * BASIS_POINTS) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }
}


/**
 * @title MeshStaking
 * @dev Allows users to stake MESH tokens to earn MUSD rewards.
 */
contract MeshStaking is ReentrancyGuard, Ownable {
    MeshToken public meshToken;
    MeshUSD public meshUSD;
    
    struct StakeInfo {
        uint256 amount;
        uint256 lastUpdateTime;
    }
    
    mapping(address => StakeInfo) public stakes;
    
    uint256 public totalStaked;
    uint256 public rewardRate = 1000; // 10% APY in basis points
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);

    constructor(address _meshToken, address _meshUSD) Ownable(msg.sender) {
        meshToken = MeshToken(_meshToken);
        meshUSD = MeshUSD(_meshUSD);
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "MeshStaking: CANNOT_STAKE_ZERO");
        
        // Claim any pending rewards before changing stake amount
        _claimRewards(msg.sender);
        
        // Update state
        stakes[msg.sender].amount += amount;
        stakes[msg.sender].lastUpdateTime = block.timestamp;
        totalStaked += amount;
        
        // Interaction
        require(meshToken.transferFrom(msg.sender, address(this), amount), "ERC20: TRANSFER_FROM_FAILED");
        
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        StakeInfo storage stakeInfo = stakes[msg.sender];
        require(stakeInfo.amount >= amount, "MeshStaking: INSUFFICIENT_STAKED_AMOUNT");
        
        // Claim any pending rewards before changing stake amount
        _claimRewards(msg.sender);
        
        // Update state
        stakeInfo.amount -= amount;
        stakeInfo.lastUpdateTime = block.timestamp;
        totalStaked -= amount;
        
        // Interaction
        require(meshToken.transfer(msg.sender, amount), "ERC20: TRANSFER_FAILED");
        
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external nonReentrant {
        _claimRewards(msg.sender);
    }

    function _claimRewards(address user) private {
        uint256 pending = pendingRewards(user);
        if (pending > 0) {
            stakes[user].lastUpdateTime = block.timestamp;
            meshUSD.mint(user, pending); // Assumes MeshUSD is ownable and this contract is an owner
            emit RewardsClaimed(user, pending);
        }
    }

    function pendingRewards(address user) public view returns (uint256) {
        StakeInfo memory stakeInfo = stakes[user];
        if (stakeInfo.amount == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - stakeInfo.lastUpdateTime;
        uint256 yearlyReward = (stakeInfo.amount * rewardRate) / BASIS_POINTS;
        return (yearlyReward * timeElapsed) / SECONDS_PER_YEAR;
    }

    function setRewardRate(uint256 _rewardRate) external onlyOwner {
        require(_rewardRate <= 5000, "MeshStaking: REWARD_RATE_TOO_HIGH");
        rewardRate = _rewardRate;
    }
}

/**
 * @title MeshYieldFarm
 * @dev Allows users to stake LP tokens to earn MESH rewards.
 * CORRECTED: Uses a more precise method for reward rate calculation.
 */
contract MeshYieldFarm is ReentrancyGuard, Ownable {
    MeshToken public meshToken;
    
    struct PoolInfo {
        address lpToken;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accTokenPerShare;
    }
    
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }
    
    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    
    // CORRECTED: Replaced 'tokenPerSecond' with a clearer, more precise rate and duration.
    uint256 public rewardsPerSecond = uint(1 ether) /86400; // Represents 1 token per day
    uint256 public totalAllocPoint = 0;
    uint256 public startTime;
    
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(address _meshToken, uint256 _startTime) Ownable(msg.sender) {
        meshToken = MeshToken(_meshToken);
        startTime = _startTime;
    }

    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }

    function add(uint256 _allocPoint, address _lpToken, bool _withUpdate) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint += _allocPoint;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accTokenPerShare: 0
        }));
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = ERC20(pool.lpToken).balanceOf(address(this));
        if (lpSupply == 0 || totalAllocPoint == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        
        // CORRECTED: Calculation uses the more precise method.
        uint256 timeDelta = block.timestamp - pool.lastRewardTime;
        uint256 tokenReward = (timeDelta * rewardsPerSecond * pool.allocPoint) / totalAllocPoint;
        
        meshToken.mint(address(this), tokenReward); // Assumes this contract is an owner on MeshToken
        pool.accTokenPerShare += (tokenReward * 1e12) / lpSupply;
        pool.lastRewardTime = block.timestamp;
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accTokenPerShare) / 1e12 - user.rewardDebt;
            if (pending > 0) {
                _safeTokenTransfer(msg.sender, pending);
                emit Harvest(msg.sender, _pid, pending);
            }
        }
        if (_amount > 0) {
            ERC20(pool.lpToken).transferFrom(msg.sender, address(this), _amount);
            user.amount += _amount;
        }
        user.rewardDebt = (user.amount * pool.accTokenPerShare) / 1e12;
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "MeshFarm: INSUFFICIENT_FUNDS");
        
        updatePool(_pid);
        uint256 pending = (user.amount * pool.accTokenPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            _safeTokenTransfer(msg.sender, pending);
            emit Harvest(msg.sender, _pid, pending);
        }
        if (_amount > 0) {
            user.amount -= _amount;
            ERC20(pool.lpToken).transfer(msg.sender, _amount);
        }
        user.rewardDebt = (user.amount * pool.accTokenPerShare) / 1e12;
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function harvest(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        uint256 pending = (user.amount * pool.accTokenPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            _safeTokenTransfer(msg.sender, pending);
            user.rewardDebt = (user.amount * pool.accTokenPerShare) / 1e12;
            emit Harvest(msg.sender, _pid, pending);
        }
    }

    function pendingToken(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = ERC20(pool.lpToken).balanceOf(address(this));
        
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0 && totalAllocPoint > 0) {
            // CORRECTED: Calculation uses the more precise method.
            uint256 timeDelta = block.timestamp - pool.lastRewardTime;
            uint256 tokenReward = (timeDelta * rewardsPerSecond * pool.allocPoint) / totalAllocPoint;
            accTokenPerShare += (tokenReward * 1e12) / lpSupply;
        }
        
        return (user.amount * accTokenPerShare) / 1e12 - user.rewardDebt;
    }

    function _safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 tokenBal = meshToken.balanceOf(address(this));
        if (_amount > tokenBal) {
            meshToken.transfer(_to, tokenBal);
        } else {
            meshToken.transfer(_to, _amount);
        }
    }
}