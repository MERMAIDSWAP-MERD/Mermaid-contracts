// SPDX-License-Identifier: MIT

pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/IMerdReferral.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./Mermaid.sol";


// MasterChef is the master of Merd. He can make Merd and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once MERD is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardLockedUp; // Reward locked up.
        //
        // We do some fancy math here. Basically, any point in time, the amount of MERDs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accMerdPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accMerdPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. MERDs to distribute per block.
        uint256 lastRewardBlock; // Last block number that MERDs distribution occurs.
        uint256 accMerdPerShare; // Accumulated MERDs per share, times 1e12. See below.
        uint16 withdrawFeeBP; // Withdraw fee in basis points
    }

    // The MERD TOKEN!
    Mermaid public merd;
    // Dev address.
    address public devAddress = 0xa4eb523d38De6E18198C5ba6C11D4A7EFE615aba;
    // Withdraw Fee address
    address public feeAddress = 0x4083F74df59551EdC368c8Ac0385D9cF20b1076d;
    // burn address
    address public burnAddress = 0x2D110aba362AA34e3595244Dd03fDF2Db455b31d;
    
    // MERD tokens created per block.
    uint256 public merdPerBlock;
    // Initial emission rate: 0.5 MERD per block.
    uint256 public constant INITIAL_EMISSION_RATE = 0.5 ether;
    // Reduce emission every 600 blocks ~ 30 min.
    uint256 public constant EMISSION_REDUCTION_PERIOD_BLOCKS = 600;
    // Emission reduction rate per period in basis points: 5%.
    uint256 public constant EMISSION_REDUCTION_RATE_PER_PERIOD = 500;
    // Last reduction period index
    uint256 public lastReductionPeriodIndex = 0;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when MERD mining starts.
    uint256 public startBlock;
    
    // Merd referral contract address.
    IMerdReferral public merdReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 200;
    // Max referral commission rate: 2%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 200;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event EmissionRateUpdated(
        address indexed caller,
        uint256 previousAmount,
        uint256 newAmount
    );
    event ReferralCommissionPaid(
        address indexed user,
        address indexed referrer,
        uint256 commissionAmount
    );
    event RewardLockedUp(
        address indexed user,
        uint256 indexed pid,
        uint256 amountLockedUp
    );

    event addEvent(uint256 _allocPoint,
        IBEP20 _lpToken,
        uint16 _withdrawFeeBP,
        bool _withUpdate);

    event setEvent( uint256 _pid,
        uint256 _allocPoint,
        uint16 _withdrawFeeBP,
        bool _withUpdate);
    event massUpdatePoolEvent();
    event setDevAddressEvent(address _newDevAddress);
    event setFeeAddressEvent(address _feeAddress);
    event setReferralAddressEvent(IMerdReferral _newAddress);
    event setReferralCommissionRateEvent(uint256 _newRate);

    constructor(Mermaid _merd,  IMerdReferral _merdReferral, uint256 _startBlock) public {
        merd = _merd;
        startBlock = _startBlock;
        merdPerBlock = INITIAL_EMISSION_RATE;
        if (block.number > startBlock) {
            uint256 currentIndex = block.number.sub(startBlock).div(
                EMISSION_REDUCTION_PERIOD_BLOCKS
            );
            lastReductionPeriodIndex = currentIndex;
        }
        merdReferral = _merdReferral;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IBEP20 => bool) public poolExistence;
    modifier nonDuplicated(IBEP20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        uint16 _withdrawFeeBP,
        bool _withUpdate
    ) public onlyOwner nonDuplicated(_lpToken) {
        require(_withdrawFeeBP <= 400, "add: invalid withdraw fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accMerdPerShare: 0,
                withdrawFeeBP: _withdrawFeeBP
            })
        );
        poolExistence[_lpToken] = true;
        emit addEvent(_allocPoint,_lpToken,_withdrawFeeBP,_withUpdate);
    }

    // Update the given pool's MERD allocation point and withdraw fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _withdrawFeeBP,
        bool _withUpdate
    ) public onlyOwner {
        require(_withdrawFeeBP <= 400, "set: invalid withdraw fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].withdrawFeeBP = _withdrawFeeBP;
        emit setEvent(_pid, _allocPoint, _withdrawFeeBP, _withUpdate);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        pure
        returns (uint256)
    {
        return _to.sub(_from);
    }

    // View function to see pending MERDS on frontend.
    function pendingMerd(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accMerdPerShare = pool.accMerdPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 merdReward = multiplier
                .mul(merdPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accMerdPerShare = accMerdPerShare.add(
                merdReward.mul(1e12).div(lpSupply)
            );
        }
        uint256 pending = user.amount.mul(accMerdPerShare).div(1e12).sub(
            user.rewardDebt
        );
        return pending.add(user.rewardLockedUp);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
        emit massUpdatePoolEvent();
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 merdReward = multiplier
            .mul(merdPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);
            //9% dev and 1% burn address
        
        merd.mint(devAddress, merdReward.mul(9).div(100));
        merd.mint(burnAddress, merdReward.div(100));
        merd.mint(address(this), merdReward);
        pool.accMerdPerShare = pool.accMerdPerShare.add(
            merdReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for MERD allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _referrer
    ) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        
        if (
            _amount > 0 &&
            address(merdReferral) != address(0) &&
            _referrer != address(0) &&
            _referrer != msg.sender
        ) {
            merdReferral.recordReferral(msg.sender, _referrer);
        }

       

        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.accMerdPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            if (pending > 0) {
                uint256 refIncome = pending.mul(referralCommissionRate).div(10000);
                safeMerdTransfer(msg.sender, pending.sub(refIncome));
                payReferralCommission(msg.sender, pending);
            }
        }

        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            
        }
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accMerdPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
        updateEmissionRate();
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accMerdPerShare).div(1e12).sub(
            user.rewardDebt
        );
        if (pending > 0) {
            uint256 refIncome = pending.mul(referralCommissionRate).div(10000);
            safeMerdTransfer(msg.sender, pending.sub(refIncome));
            payReferralCommission(msg.sender, pending);
        }
        if (_amount > 0) {

            if (pool.withdrawFeeBP > 0) {
                uint256 withdrawFee = _amount.mul(pool.withdrawFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, withdrawFee);
                pool.lpToken.safeTransfer(address(msg.sender), _amount.sub(withdrawFee));
            } 
            else{
                pool.lpToken.safeTransfer(address(msg.sender), _amount);
            }
            user.amount = user.amount.sub(_amount);
            
        }
        user.rewardDebt = user.amount.mul(pool.accMerdPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
        updateEmissionRate();
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe merd transfer function, just in case if rounding error causes pool to not have enough MERDs.
    function safeMerdTransfer(address _to, uint256 _amount) internal {
        uint256 merdBal = merd.balanceOf(address(this));
        if (_amount > merdBal) {
            merd.transfer(_to, merdBal);
        } else {
            merd.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
        emit setDevAddressEvent(_devAddress);
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
        emit setFeeAddressEvent(_feeAddress);
    }

    // Update the merd referral contract address by the owner
    function setMerdReferral(IMerdReferral _merdReferral) public onlyOwner {
        merdReferral = _merdReferral;
        emit setReferralAddressEvent(_merdReferral);
    }

    // Update the burn wallet
    function setBurnWallet(address _burnWallet) public onlyOwner {
        burnAddress = _burnWallet;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate)
        public
        onlyOwner
    {
        require(
            _referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE,
            "setReferralCommissionRate: invalid referral commission rate basis points"
        );
        referralCommissionRate = _referralCommissionRate;
        emit setReferralCommissionRateEvent(_referralCommissionRate);
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(merdReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = merdReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(
                10000
            );

            if (referrer != address(0) && commissionAmount > 0) {
                safeMerdTransfer(referrer, commissionAmount);
                merdReferral.recordReferralCommission(
                    referrer,
                    commissionAmount
                );
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Reduce emission rate by 5% every 600 blocks ~ 30 min. This function can be called publicly.
    function updateEmissionRate() public {
        if(merdPerBlock<=0.05 ether){
            return;
        }
        if (block.number > startBlock) {
            uint256 currentIndex = block.number.sub(startBlock).div(
                EMISSION_REDUCTION_PERIOD_BLOCKS
            );
            uint256 newEmissionRate = merdPerBlock;

            if (currentIndex > lastReductionPeriodIndex) {
                for (
                    uint256 index = lastReductionPeriodIndex;
                    index < currentIndex;
                    ++index
                ) {
                    newEmissionRate = newEmissionRate
                        .mul(1e4 - EMISSION_REDUCTION_RATE_PER_PERIOD)
                        .div(1e4);
                }
                if (newEmissionRate < merdPerBlock) {
                    massUpdatePools();
                    lastReductionPeriodIndex = currentIndex;
                    uint256 previousEmissionRate = merdPerBlock;
                    merdPerBlock = newEmissionRate;
                    if(merdPerBlock <= 0.05 ether){
                        merdPerBlock = 0.05 ether;
                    }
                    emit EmissionRateUpdated(
                        msg.sender,
                        previousEmissionRate,
                        newEmissionRate
                    );
                }
            }
        }
    }
}
