// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MeshUSD.sol";
import "./MeshToken.sol";

// 1. LP Token for DEX pairs
contract MeshLPToken is ERC20, Ownable(msg.sender) {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}

// 2. AMM DEX Contract
contract MeshDEX is ReentrancyGuard, Ownable(msg.sender) {
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
    
    uint256 public constant FEE_RATE = 30; // 0.3% = 30 basis points
    uint256 public constant BASIS_POINTS = 10000;
    
    event PoolCreated(address indexed token0, address indexed token1, bytes32 poolId);
    event LiquidityAdded(address indexed user, bytes32 poolId, uint256 amount0, uint256 amount1);
    event LiquidityRemoved(address indexed user, bytes32 poolId, uint256 amount0, uint256 amount1);
    event Swap(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    function createPool(address token0, address token1) external returns (bytes32 poolId) {
        require(token0 != token1, "Identical tokens");
        require(token0 != address(0) && token1 != address(0), "Zero address");
        
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }
        
        poolId = keccak256(abi.encodePacked(token0, token1));
        require(pools[poolId].token0 == address(0), "Pool exists");
        
        string memory lpName = string(abi.encodePacked("Mesh-LP-", ERC20(token0).symbol(), "-", ERC20(token1).symbol()));
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
        
        emit PoolCreated(token0, token1, poolId);
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
        require(poolId != bytes32(0), "Pool doesn't exist");
        
        Pool storage pool = pools[poolId];
        
        if (pool.reserve0 == 0 && pool.reserve1 == 0) {
            (amount0, amount1) = (amount0Desired, amount1Desired);
        } else {
            uint256 amount1Optimal = (amount0Desired * pool.reserve1) / pool.reserve0;
            if (amount1Optimal <= amount1Desired) {
                require(amount1Optimal >= amount1Min, "Insufficient token1 amount");
                (amount0, amount1) = (amount0Desired, amount1Optimal);
            } else {
                uint256 amount0Optimal = (amount1Desired * pool.reserve0) / pool.reserve1;
                assert(amount0Optimal <= amount0Desired);
                require(amount0Optimal >= amount0Min, "Insufficient token0 amount");
                (amount0, amount1) = (amount0Optimal, amount1Desired);
            }
        }
        
        require(ERC20(token0).transferFrom(msg.sender, address(this), amount0), "Transfer failed");
        require(ERC20(token1).transferFrom(msg.sender, address(this), amount1), "Transfer failed");
        
        if (pool.totalSupply == 0) {
            liquidity = sqrt(amount0 * amount1) - 1000; // Minimum liquidity
        } else {
            liquidity = min((amount0 * pool.totalSupply) / pool.reserve0, (amount1 * pool.totalSupply) / pool.reserve1);
        }
        
        require(liquidity > 0, "Insufficient liquidity minted");
        
        MeshLPToken(pool.lpToken).mint(msg.sender, liquidity);
        
        pool.reserve0 += amount0;
        pool.reserve1 += amount1;
        pool.totalSupply += liquidity;
        
        emit LiquidityAdded(msg.sender, poolId, amount0, amount1);
    }

    function removeLiquidity(
        address token0,
        address token1,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        bytes32 poolId = getPoolId[token0][token1];
        require(poolId != bytes32(0), "Pool doesn't exist");
        
        Pool storage pool = pools[poolId];
        
        amount0 = (liquidity * pool.reserve0) / pool.totalSupply;
        amount1 = (liquidity * pool.reserve1) / pool.totalSupply;
        
        require(amount0 >= amount0Min, "Insufficient token0 amount");
        require(amount1 >= amount1Min, "Insufficient token1 amount");
        
        MeshLPToken(pool.lpToken).burn(msg.sender, liquidity);
        
        require(ERC20(token0).transfer(msg.sender, amount0), "Transfer failed");
        require(ERC20(token1).transfer(msg.sender, amount1), "Transfer failed");
        
        pool.reserve0 -= amount0;
        pool.reserve1 -= amount1;
        pool.totalSupply -= liquidity;
        
        emit LiquidityRemoved(msg.sender, poolId, amount0, amount1);
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) external nonReentrant returns (uint256 amountOut) {
        bytes32 poolId = getPoolId[tokenIn][tokenOut];
        require(poolId != bytes32(0), "Pool doesn't exist");
        
        Pool storage pool = pools[poolId];
        
        uint256 reserveIn = tokenIn == pool.token0 ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = tokenIn == pool.token0 ? pool.reserve1 : pool.reserve0;
        
        require(amountIn > 0, "Insufficient input amount");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");
        
        uint256 amountInWithFee = amountIn * (BASIS_POINTS - FEE_RATE);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BASIS_POINTS + amountInWithFee;
        amountOut = numerator / denominator;
        
        require(amountOut >= amountOutMin, "Insufficient output amount");
        require(amountOut < reserveOut, "Insufficient liquidity");
        
        require(ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "Transfer failed");
        require(ERC20(tokenOut).transfer(msg.sender, amountOut), "Transfer failed");
        
        if (tokenIn == pool.token0) {
            pool.reserve0 += amountIn;
            pool.reserve1 -= amountOut;
        } else {
            pool.reserve1 += amountIn;
            pool.reserve0 -= amountOut;
        }
        
        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256 amountOut) {
        require(amountIn > 0, "Insufficient input amount");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");
        
        uint256 amountInWithFee = amountIn * (BASIS_POINTS - FEE_RATE);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BASIS_POINTS + amountInWithFee;
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

// 3. Staking Contract
contract MeshStaking is ReentrancyGuard, Ownable(msg.sender) {
    MeshToken public meshToken;
    MeshUSD public meshUSD;
    
    struct StakeInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastStakeTime;
    }
    
    mapping(address => StakeInfo) public stakes;
    
    uint256 public totalStaked;
    uint256 public rewardRate = 1000; // 10% APY = 1000 basis points
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);

    constructor(address _meshToken, address _meshUSD) {
        meshToken = MeshToken(_meshToken);
        meshUSD = MeshUSD(_meshUSD);
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Cannot stake 0");
        
        StakeInfo storage stakeInfo = stakes[msg.sender];
        
        // Claim pending rewards
        if (stakeInfo.amount > 0) {
            uint256 pending = pendingRewards(msg.sender);
            if (pending > 0) {
                meshUSD.mint(msg.sender, pending);
                emit RewardsClaimed(msg.sender, pending);
            }
        }
        
        require(meshToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        stakeInfo.amount += amount;
        stakeInfo.lastStakeTime = block.timestamp;
        totalStaked += amount;
        
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        StakeInfo storage stakeInfo = stakes[msg.sender];
        require(stakeInfo.amount >= amount, "Insufficient staked amount");
        
        // Claim pending rewards
        uint256 pending = pendingRewards(msg.sender);
        if (pending > 0) {
            meshUSD.mint(msg.sender, pending);
            emit RewardsClaimed(msg.sender, pending);
        }
        
        stakeInfo.amount -= amount;
        stakeInfo.lastStakeTime = block.timestamp;
        totalStaked -= amount;
        
        require(meshToken.transfer(msg.sender, amount), "Transfer failed");
        
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external nonReentrant {
        uint256 pending = pendingRewards(msg.sender);
        require(pending > 0, "No rewards to claim");
        
        stakes[msg.sender].lastStakeTime = block.timestamp;
        meshUSD.mint(msg.sender, pending);
        
        emit RewardsClaimed(msg.sender, pending);
    }

    function pendingRewards(address user) public view returns (uint256) {
        StakeInfo memory stakeInfo = stakes[user];
        if (stakeInfo.amount == 0) return 0;
        
        uint256 timeStaked = block.timestamp - stakeInfo.lastStakeTime;
        uint256 yearlyReward = (stakeInfo.amount * rewardRate) / BASIS_POINTS;
        return (yearlyReward * timeStaked) / SECONDS_PER_YEAR;
    }

    function setRewardRate(uint256 _rewardRate) external onlyOwner {
        require(_rewardRate <= 5000, "Reward rate too high"); // Max 50%
        rewardRate = _rewardRate;
    }
}

// 4. Yield Farming Contract
contract MeshYieldFarm is ReentrancyGuard, Ownable(msg.sender) {
    MeshToken public meshToken;
    
    struct PoolInfo {
        address lpToken;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accTokenPerShare;
        uint256 totalStaked;
    }
    
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }
    
    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    
    uint256 public tokenPerSecond = 1e18; // 1 token per second
    uint256 public totalAllocPoint = 0;
    uint256 public startTime;
    
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(address _meshToken, uint256 _startTime) {
        meshToken = MeshToken(_meshToken);
        startTime = _startTime;
    }

    function add(uint256 _allocPoint, address _lpToken) external onlyOwner {
        massUpdatePools();
        
        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint += _allocPoint;
        
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accTokenPerShare: 0,
            totalStaked: 0
        }));
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        
        uint256 lpSupply = pool.totalStaked;
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        
        uint256 multiplier = block.timestamp - pool.lastRewardTime;
        uint256 tokenReward = (multiplier * tokenPerSecond * pool.allocPoint) / totalAllocPoint;
        
        meshToken.mint(address(this), tokenReward);
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
                meshToken.transfer(msg.sender, pending);
                emit Harvest(msg.sender, _pid, pending);
            }
        }
        
        if (_amount > 0) {
            ERC20(pool.lpToken).transferFrom(msg.sender, address(this), _amount);
            user.amount += _amount;
            pool.totalStaked += _amount;
        }
        
        user.rewardDebt = (user.amount * pool.accTokenPerShare) / 1e12;
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "Insufficient amount");
        
        updatePool(_pid);
        
        uint256 pending = (user.amount * pool.accTokenPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            meshToken.transfer(msg.sender, pending);
            emit Harvest(msg.sender, _pid, pending);
        }
        
        if (_amount > 0) {
            user.amount -= _amount;
            pool.totalStaked -= _amount;
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
            meshToken.transfer(msg.sender, pending);
            user.rewardDebt = (user.amount * pool.accTokenPerShare) / 1e12;
            emit Harvest(msg.sender, _pid, pending);
        }
    }

    function pendingToken(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 lpSupply = pool.totalStaked;
        
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = block.timestamp - pool.lastRewardTime;
            uint256 tokenReward = (multiplier * tokenPerSecond * pool.allocPoint) / totalAllocPoint;
            accTokenPerShare += (tokenReward * 1e12) / lpSupply;
        }
        
        return (user.amount * accTokenPerShare) / 1e12 - user.rewardDebt;
    }
}