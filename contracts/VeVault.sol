// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// Inheritance
import "./Pausable.sol";
import "./interfaces/IERC4626.sol";

// Custom errors
error Unauthorized();
error InsufficientBalance(uint256 available, uint256 required);
error NotWhitelisted();
error FundsInGracePeriod();
error FundsNotUnlocked();

abstract contract VeVault is ReentrancyGuard, Pausable, IERC4626 {
    using SafeERC20 for IERC20;

    struct Penalty {
        uint256 gracePeriod;
        uint256 maxPerc;
        uint256 minPerc;
        uint256 stepPerc;
    }
    
    struct LockTimer {
        uint256 min;
        uint256 max;
        uint256 epoch;
        bool    enforce;
    }

    /* ========== STATE VARIABLES ========== */

    // Asset
    address public _assetTokenAddress;
    uint256 public _totalManagedAssets;
    mapping(address => uint256) public _assetBalances;

    // Share (veToken)
    uint256 private _totalSupply;
    mapping(address => uint256) public _shareBalances;
    mapping(address => uint256) private _unlockDate;

    // ERC20 metadata
    string public _name;
    string public _symbol;

    LockTimer internal _lockTimer;
    Penalty internal _penalty;
    
    // Only allow recoverERC20 from this list
    mapping(address => bool) public whitelistRecoverERC20;

    // Constants
    uint256 private constant SEC_IN_DAY = 86400;
    uint256 private constant PRECISION = 1e2;
    // This value should be 1e17 but we are using 1e2 as precision
    uint256 private constant CONVERT_PRECISION  = 1e17 / PRECISION;
    // Polynomial coefficients used in veMult function
    uint256 private constant K_3 = 154143856;
    uint256 private constant K_2 = 74861590400;
    uint256 private constant K_1 = 116304927000000;
    uint256 private constant K = 90026564600000000;

    /* ========== CONSTRUCTOR ========== */

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }
    
    /* ========== VIEWS ========== */
    
    /**
     * The address of the underlying token 
     * used for the Vault for accounting, 
     * depositing, and withdrawing.
     */
    function asset() external view override returns (address assetTokenAddress) {
        return _assetTokenAddress;
    }

    /**
     * Total amount of the underlying asset that is “managed” by Vault.
     */
    function totalAssets() external view override returns (uint256 totalManagedAssets) {
        return _totalManagedAssets;
    }

    /**
     * Total of veTokens
     */
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * Total of veTokens currently hold by an address
     */
    function balanceOf(address account) external view override returns (uint256) {
        return _shareBalances[account];
    }

    /** 
     * Compliant to the ERC4626 interface.
     * The amount of shares that the Vault would exchange for the amount
     * of assets provided, in an ideal scenario where all the conditions are met.
     * Alwalys return the amount of veToken for the min amount of time locked.
     */
    function convertToShares(uint256 assets, uint256 lockTime) public pure returns (uint256 shares) {
        return assets * veMult(lockTime) / PRECISION;
    }

    function convertToShares(uint256 assets) override external view returns (uint256 shares) {
        return convertToShares(assets, _lockTimer.min);
    }
    
    /**
     * Compliant to the ERC4626 interface.
     * The amount of assets that the Vault would exchange for the amount 
     * of shares provided, in an ideal scenario where all the conditions are met.
     */
    function convertToAssets(uint256 shares, uint256 lockTime) public pure returns (uint256 assets) {
        return shares * PRECISION / veMult(lockTime);
    }

    function convertToAssets(uint256 shares) override external view returns (uint256 assets) {
        return convertToAssets(shares, _lockTimer.min);
    }
    
    /** 
     * Compliant to the ERC4626 interface.
     * Maximum amount of the underlying asset that can be deposited into
     * the Vault for the receiver, through a deposit call.
     */
    function maxDeposit(address) override external pure returns (uint256 maxAssets) {
        return 2 ** 256 - 1;
    }

    /** 
     * Compliant to the ERC4626 interface.
     * Allows an on-chain or off-chain user to simulate the effects of
     * their deposit at the current block, given current on-chain conditions.
     */
    function previewDeposit(uint256 assets, uint256 lockTime) public pure returns (uint256 shares) {
        return convertToShares(assets, lockTime);
    }

    function previewDeposit(uint256 assets) override external view returns (uint256 shares) {
        return previewDeposit(assets, _lockTimer.min);
    }
    
    /**
     * Compliant to the ERC4626 interface.
     * Maximum amount of shares that can be minted from the Vault for the receiver,
     * through a mint call.
     */
    function maxMint(address) override external pure returns (uint256 maxShares) {
        return 2 ** 256 - 1;
    }

    /**
     * Compliant to the ERC4626 interface.
     * Allows an on-chain or off-chain user to simulate the effects of their
     * mint at the current block, given current on-chain conditions.
     */
    function previewMint(uint256 shares, uint256 lockTime) public pure returns (uint256 assets) {
        return convertToAssets(shares, lockTime);
    }

    function previewMint(uint256 shares) override external view returns (uint256 assets) {
        return previewMint(shares, _lockTimer.min);
    }
    
    /**
     * Compliant to the ERC4626 interface.
     * Maximum amount of the underlying asset that can be withdrawn from the
     * owner balance in the Vault, through a withdraw call.
     */
    function maxWithdraw(address owner) override external view returns (uint256 maxAssets) {
        if (paused) {
            return 0;
        }
        return _assetBalances[owner];
    }

    /**
     * Compliant to the ERC4626 interface.
     * Allows an on-chain or off-chain user to simulate the effects of
     * their withdrawal at the current block, given current on-chain conditions.
     */
    function previewWithdraw(uint256 assets, uint256 lockTime) public pure returns (uint256 shares) {
        return convertToShares(assets, lockTime);
    }

    function previewWithdraw(uint256 assets) override external view returns (uint256 shares) {
        return previewWithdraw(assets, _lockTimer.min);
    }
    
    /**
     * Compliant to the ERC4626 interface.
     * Maximum amount of Vault shares that can be redeemed from the owner
     * balance in the Vault, through a redeem call.
     */
    function maxRedeem(address owner) override external view returns (uint256 maxShares) {
        if (paused) {
            return 0;
        }
        return _shareBalances[owner];
    }

    /**
     * Compliant to the ERC4626 interface.
     * Allows an on-chain or off-chain user to simulate the effects of their
     * redeemption at the current block, given current on-chain conditions.
     */
    function previewRedeem(uint256 shares, uint256 lockTime) public pure returns (uint256 assets) {
        return convertToAssets(shares, lockTime);
    }

    function previewRedeem(uint256 shares) override external view returns (uint256 assets) {
        return previewRedeem(shares, _lockTimer.min);
    }
    
    /**
     * Ve tokens are not transferable.
     * Always returns zero.
     */
    function allowance(address, address) override external pure returns (uint256) {
        return 0;
    }

    /**
     * Compliant to the ERC4626 interface.
     * Total assets deposited by address
     */
    function assetBalanceOf(address account) external view returns (uint256) {
        return _assetBalances[account];
    }

    /**
     * Unlock date for an account
     */
    function unlockDate(address account) external view returns (uint256) {
        return _unlockDate[account];
    }

    /**
     * How long is the grace period in seconds
     */
    function gracePeriod() external view returns (uint256) {
        return _penalty.gracePeriod;
    }

    /**
     * Percentage paid per epoch after grace period
     * plus the minimum percentage
     * This is paid to caller which withdraw veTokens
     * in name of account in the underlying asset.
     */
    function penaltyPercentage() external view returns (uint256) {
        return _penalty.stepPerc;
    }

    /**
     * Minimum lock time in seconds
     */
     function minLockTime() external view returns (uint256) {
         return _lockTimer.min;
     }
    
    /**
     * Maximum lock time in seconds
     */
     function maxLockTime() external view returns (uint256) {
         return _lockTimer.max;
     }

     /**
     * Returns the name of the token.
     */
    function name() public view returns (string memory) {
        return _name;
    }

    /**
     * Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }
    
    /* ========== ERC20 NOT ALLOWED FUNCTIONS ========== */

    function transfer(address, uint256) external pure override returns (bool) {
        revert Unauthorized();
    }

    function approve(address, uint256) external pure override returns (bool) {
        revert Unauthorized();
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        revert Unauthorized();
    }

    /* ========== PURE FUNCTIONS ========== */

    /**
     * @dev Super linear function.
     * Calculate the multipler applied to
     * the amount of tokens staked.
     * lockTime: time in seconds
     * Granularity is lost with lockTime between days
     * This functions implements the following polynomial:
     * f(x) = x^3 * 1.54143856e-09 - x^2 * 7.48615904e-07 + x * 1.16304927e-03 + 9.00265646e-01
     * Which can be simplified to:
     * f(x) = x^3 * K_3 - x^2 * K_2 + x * K_1 + K
     */
    function veMult(uint256 lockTime) internal pure returns (uint256) {
        return (
            (((lockTime / SEC_IN_DAY) ** 3) * K_3)
            + ((lockTime / SEC_IN_DAY) * K_1) + K
            - (((lockTime / SEC_IN_DAY) ** 2) * K_2)
            ) / CONVERT_PRECISION;
    }
    
    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * Compliant to the ERC4626 interface.
     * Mints shares Vault shares to receiver by
     * depositing exactly amount of underlying tokens.
     * Only allow deposits for caller equals receiver.
     * When a relock is performed, the furtherest date
     * in the future is the one selected.
     * The multiplier is applied to the total amount
     * of assets deposited since all value will be locked.
     */
    function deposit(uint256 assets, address receiver, uint256 lockTime)
            external 
            nonReentrant
            notPaused 
            returns (uint256 shares) {
        return _deposit(assets, receiver, lockTime);
    }
    
    function deposit(uint256 assets, address receiver)
            override
            external
            nonReentrant
            notPaused 
            returns (uint256 shares) {
        return _deposit(assets, receiver, _lockTimer.min);
    }
    
    /**
     * Not compliant to the ERC4626 interface
     * since it doesn't mint the exactly amount
     * of shares asked. The shares amount stays
     * within a 0.001% margin.
     * Mint shares for receiver by depositing
     * the necessary amount of underlying tokens.
     * Only allow deposits for caller equals receiver.
     * When a relock is performed, the furtherest date
     * in the future is the one selected.
     * The multiplier is applied to the total amount
     * of assets deposited since all value will be locked.
     */
    function mint(uint256 shares, address receiver, uint256 lockTime)
            external 
            nonReentrant
            notPaused
            returns (uint256 assets) {
        uint256 updatedShares = convertToShares(_assetBalances[receiver], lockTime);
        if (updatedShares > _shareBalances[receiver]) {
            uint256 diff = updatedShares - _shareBalances[receiver];
            if (shares <= diff)
                revert Unauthorized();
            assets = convertToAssets(shares - diff, lockTime);
        } else {
            uint256 diff = _shareBalances[receiver] - updatedShares;
            assets = convertToAssets(shares + diff, lockTime);
        }
        _deposit(assets, receiver, lockTime);
        return assets;
    }

    function mint(uint256 shares, address receiver)
            override
            external
            nonReentrant
            notPaused
            returns (uint256 assets) {
        uint256 updatedShares = convertToShares(_assetBalances[receiver], _lockTimer.min);
        if (updatedShares > _shareBalances[receiver]) {
            uint256 diff = updatedShares - _shareBalances[receiver];
            assets = convertToAssets(shares - diff, _lockTimer.min);
        } else {
            uint256 diff = _shareBalances[receiver] - updatedShares;
            assets = convertToAssets(shares + diff, _lockTimer.min);
        }
        _deposit(assets, receiver, _lockTimer.min);
        return assets;
    }
    
    /**
     * Compliant to the ERC4626 interface
     * Burns shares from owner and sends exactly
     * assets of underlying tokens to receiver.
     * Allows owner to send their assets to another
     * address.
     * A caller can only withdraw assets from owner
     * to owner, receiving a reward for doing so.
     * This reward is paid from owner asset balance.
     * Can only withdraw after unlockDate and withdraw
     * from another address after unlockDate plus grace
     * period.
     */
    function withdraw(uint256 assets, address receiver, address owner)
            override
            external 
            nonReentrant 
            notPaused
            returns (uint256 shares) {
        return _withdraw(assets, receiver, owner);
    }

    /**
     * Not compliant to the ERC4626 interface
     * since it doesn't burn the exactly amount
     * of shares asked. The shares amount stays
     * within a 0.001% margin.
     * Burns shares from owner and sends the correct
     * amount of underlying tokens to receiver.
     * Allows owner to send their assets to another
     * address.
     * A caller can only withdraw assets from owner
     * to owner, receiving a reward for doing so.
     * This reward is paid from owner asset balance.
     * Can only withdraw after unlockDate and withdraw
     * from another address after unlockDate plus grace
     * period.
     */
    function redeem(uint256 shares, address receiver, address owner)
            override
            external 
            nonReentrant 
            notPaused
            returns (uint256 assets) {
        uint256 diff = _shareBalances[owner] - _assetBalances[owner];
        if (shares < diff)
            revert Unauthorized();
        assets = shares - diff;
        _withdraw(assets, receiver, owner);
        return assets;
    }

    /**
     * Withdraw all funds for the caller
     */
    function exit()
            external 
            nonReentrant 
            notPaused
            returns (uint256 shares) {
        return _withdraw(_assetBalances[msg.sender], msg.sender, msg.sender);
    }

    /**
    * Owner can change the unlock rule to allow
    * withdraws before unlock date.
    * Ignores the rule if set to false.
    */
    function changeUnlockRule(bool flag) external onlyOwner {
        _lockTimer.enforce = flag;
    }

    /**
     * Owner can change state variabes which controls the penalty system
     */
    function changeGracePeriod(uint256 newGracePeriod) external onlyOwner {
        _penalty.gracePeriod = newGracePeriod;
    }
    
    function changeEpoch(uint256 newEpoch) external onlyOwner {
        _lockTimer.epoch = newEpoch;
    }
    
    function changeMinPenalty(uint256 newMinPenalty) external onlyOwner {
        _penalty.minPerc = newMinPenalty;
    }
    
    function changeMaxPenalty(uint256 newMaxPenalty) external onlyOwner {
        _penalty.maxPerc = newMaxPenalty;
    }
    
    // Whitelist a ERC20 to allow recoverERC20 function. Emits an event to alert users.
    function changeWhitelistRecoverERC20(address tokenAddress, bool flag) external onlyOwner {
        whitelistRecoverERC20[tokenAddress] = flag;
        emit ChangeWhitelistERC20(tokenAddress, flag);
    }

    // Added to support to recover ERC20 token within a whitelist 
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        if (whitelistRecoverERC20[tokenAddress] == false) revert NotWhitelisted();
        
        uint balance = IERC20(tokenAddress).balanceOf(address(this));
        if (balance < tokenAmount) revert InsufficientBalance({
                available: balance,
                required: tokenAmount
        });
        
        IERC20(tokenAddress).safeTransfer(owner, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    // Added to support to recover ERC721 
    function recoverERC721(address tokenAddress, uint256 tokenId) external onlyOwner {
        IERC721(tokenAddress).safeTransferFrom(address(this), owner, tokenId);
        emit RecoveredNFT(tokenAddress, tokenId);
    }

    /* ========== INTERNAL FUNCTIONS ========== */
    
    /**
     * Handles deposit in which
     * new veTokens are minted.
     * Transfer asset tokens to
     * vault and lock it for a period.
     */
    function _deposit(
        uint256 assets,
        address receiver,
        uint256 lockTime
        ) internal 
        updateShares(receiver, lockTime)
        returns (uint256 shares) {
        if (assets <= 0 || msg.sender != receiver
            || lockTime < _lockTimer.min || lockTime > _lockTimer.max)
            revert Unauthorized();

        // Update lockTime
        // Always choose the date futher in the future
        uint256 unlockTime = block.timestamp + lockTime;
        if (_unlockDate[receiver] < unlockTime)
            _unlockDate[receiver] = unlockTime;
        
        // Update assets
        _totalManagedAssets += assets;
        _assetBalances[receiver] += assets;
        IERC20(_assetTokenAddress).safeTransferFrom(receiver, address(this), assets);

        // The end balance of shares can be
        // lower than the amount returned by
        // this function
        shares = convertToShares(assets, lockTime);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }
    
    /**
     * Handles withdraw in which veTokens are burned.
     * Transfer asset tokens from vault to receiver.
     * Only allows withdraw after correct unlock date.
     */
    function _withdraw(
        uint256 assets,
        address receiver,
        address owner
        ) internal
        updateShares(receiver, _lockTimer.min)
        returns (uint256 shares) {
        if (owner == address(0)) revert Unauthorized();
        if (_assetBalances[owner] < assets)
            revert InsufficientBalance({
                available: _assetBalances[owner],
                required: assets
            });

        // To kickout someone
        if (msg.sender != owner) {
            // Must send the funds to owner
            if (receiver != owner)
                revert Unauthorized();
            // Only kickout after gracePeriod
            if (_lockTimer.enforce && (block.timestamp < _unlockDate[owner] + _penalty.gracePeriod))
                revert FundsNotUnlocked();
            // Pay reward to caller
            assets -= _payPenalty(owner, assets);
        }
        // Self withdraw
        else if (_lockTimer.enforce && block.timestamp < _unlockDate[owner])
            revert FundsNotUnlocked();

        // Withdraw assets
        _totalManagedAssets -= assets;
        _assetBalances[owner] -= assets;
        IERC20(_assetTokenAddress).safeTransfer(receiver, assets);
        // The end balance of shares can be
        // lower than the amount returned by
        // this function
        shares = assets;
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    /**
     * Pay penalty to withdraw caller.
     * The reward is paid from owner account
     * with their underlying asset.
     * Only after the grace period it's paid.
     * It starts at the minimum penalty and
     * after each epoch it's increased. It's
     * capped at the max penalty.
     */
    function _payPenalty(address owner, uint256 assets) internal returns (uint256 amountPenalty) {
        uint256 penaltyAmount = _penalty.minPerc 
                        + (((block.timestamp - (_unlockDate[owner] + _penalty.gracePeriod))
                            / _lockTimer.epoch)
                        * _penalty.stepPerc);

        if (penaltyAmount > _penalty.maxPerc) {
            penaltyAmount = _penalty.maxPerc;
        }
        amountPenalty = (assets * penaltyAmount) / 100;

        // Safety check 
        if (_assetBalances[owner] < amountPenalty)
            revert InsufficientBalance({
                available: _assetBalances[owner],
                required: amountPenalty
            });

        _totalManagedAssets -= amountPenalty;
        _assetBalances[owner] -= amountPenalty;

        IERC20(_assetTokenAddress).safeTransfer(msg.sender, amountPenalty);
        emit PayPenalty(msg.sender, owner, amountPenalty);
        return amountPenalty;
    }
    
    /**
     * Update the correct amount of shares
     * In case of a deposit, always consider
     * the last lockTime for the multiplier.
     * But the unlockDate will always be the
     * one futherest in the future.
     * In a case of a withdraw, the min multiplier
     * is applied for the leftover assets in vault. 
     */
    modifier updateShares(address receiver, uint256 lockTime) {
        _;
        uint256 shares = convertToShares(_assetBalances[receiver], lockTime);
        uint256 oldShares = _shareBalances[receiver];
        if (oldShares < shares) {
            uint256 diff = shares - oldShares;
            _totalSupply += diff;
            emit Mint(receiver, diff);
        } else if (oldShares > shares) {
            uint256 diff = oldShares - shares;
            _totalSupply -= diff;
            emit Burn(receiver, diff);
        }
        _shareBalances[receiver] = shares;
    }
    
    /* ========== EVENTS ========== */

    event PayPenalty(address indexed caller, address indexed owner, uint256 assets);
    event Burn(address indexed user, uint256 shares);
    event Mint(address indexed user, uint256 shares);
    event Recovered(address token, uint256 amount);
    event RecoveredNFT(address tokenAddress, uint256 tokenId);
    event ChangeWhitelistERC20(address indexed tokenAddress, bool whitelistState);
}