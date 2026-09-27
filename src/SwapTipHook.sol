// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Optional per-swap ETH tips, held as PoolManager claims until the recipient withdraws.
/// @dev Only the two advertised swap callbacks exist. No initialize/liquidity callback can gate a launch.
contract SwapTipHook is IUnlockCallback {
    using SafeCast for uint256;

    IPoolManager public immutable poolManager;
    uint256 public constant MAX_TIP_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    mapping(address recipient => uint256 amount) public balanceOf;
    mapping(PoolId poolId => uint256 amount) public totalTipped;
    mapping(address tipper => uint256 amount) public tippedBy;
    mapping(address recipient => uint256 amount) public receivedBy;

    // A claim may only be paid during the unlock initiated by claim().
    bool private claiming;

    error OnlyPoolManager();
    error InvalidPoolManager();
    error TipTooHigh();
    error PartialFill();
    error NothingToClaim();
    error ClaimInProgress();
    error NoClaimInProgress();

    event Tipped(
        PoolId indexed poolId, address indexed tipper, address indexed recipient, uint16 bps, uint256 amount
    );
    event Claimed(address indexed recipient, uint256 amount);

    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert InvalidPoolManager();
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.currency0.isAddressZero()) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        (uint256 bps, address recipient) = _tip(hookData);
        int128 fee;
        if (bps != 0 && _ethSpecified(params)) {
            fee = _fee(_abs(params.amountSpecified), bps);
            _credit(key.toId(), recipient, bps, fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);
        (uint256 bps, address recipient) = _tip(hookData);
        bool ethSpecified = _ethSpecified(params);
        int128 specifiedFee = ethSpecified ? _fee(_abs(params.amountSpecified), bps) : int128(0);

        // PoolManager passes its raw pool delta, before subtracting either hook delta.
        // For an ETH-specified sell it must produce requested ETH + fee; for a buy it
        // must consume requested ETH - fee. Subtracting the fee then restores the exact request.
        int256 filled = ethSpecified ? int256(delta.amount0()) : int256(delta.amount1());
        if (filled - int256(specifiedFee) != params.amountSpecified) revert PartialFill();

        int128 fee;
        if (!ethSpecified && bps != 0) {
            fee = _fee(_abs(int256(delta.amount0())), bps);
            _credit(key.toId(), recipient, bps, fee);
        }
        return (IHooks.afterSwap.selector, fee);
    }

    /// @notice Withdraw all ETH owed to msg.sender. Reverts atomically if the recipient rejects ETH.
    function claim() external {
        if (claiming) revert ClaimInProgress();
        uint256 amount = balanceOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        balanceOf[msg.sender] = 0;
        claiming = true;
        poolManager.unlock(abi.encode(msg.sender, amount));
        claiming = false;
        emit Claimed(msg.sender, amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!claiming) revert NoClaimInProgress();
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        // burn credits the hook's transient delta; take debits it by exactly the same amount.
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), recipient, amount);
        return "";
    }

    function _tip(bytes calldata data) private view returns (uint256 bps, address recipient) {
        if (data.length != 64) return (0, address(0));
        uint256 recipientWord;
        (bps, recipientWord) = abi.decode(data, (uint256, uint256));
        if (bps > MAX_TIP_BPS) revert TipTooHigh();
        if (bps == 0 || recipientWord >= 1 << 160) return (0, address(0));
        recipient = address(uint160(recipientWord));
        if (recipient == address(0) || recipient == address(this) || recipient == address(poolManager)) {
            return (0, address(0));
        }
    }

    function _ethSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _abs(int256 amount) private pure returns (uint256) {
        // Also defined for int256.min; unusually large requests still face v4's int128 limits.
        unchecked {
            return amount < 0 ? uint256(-(amount + 1)) + 1 : uint256(amount);
        }
    }

    function _fee(uint256 base, uint256 bps) private pure returns (int128) {
        return FullMath.mulDiv(base, bps, BPS_DENOMINATOR).toInt128();
    }

    function _credit(PoolId poolId, address recipient, uint256 bps, int128 fee) private {
        if (fee == 0) return;
        uint256 amount = uint128(fee);
        balanceOf[recipient] += amount;
        totalTipped[poolId] += amount;
        // tx.origin is a public leaderboard label only, never an authorization identity.
        tippedBy[tx.origin] += amount;
        receivedBy[recipient] += amount;
        poolManager.mint(address(this), 0, amount);
        emit Tipped(poolId, tx.origin, recipient, uint16(bps), amount);
    }
}
