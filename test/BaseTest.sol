// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IMidnight } from "morpho-midnight-1.0.0/src/interfaces/IMidnight.sol";
import { IEIP712 } from "permit2-1.0.0/src/interfaces/IEIP712.sol";
import { ISignatureTransfer } from "permit2-1.0.0/src/interfaces/ISignatureTransfer.sol";

import { Test } from "forge-std/Test.sol";
import { Midnight } from "morpho-midnight-1.0.0/src/Midnight.sol";
import { CollateralParams, Market, Offer } from "morpho-midnight-1.0.0/src/interfaces/IMidnight.sol";
import { MAX_TICK } from "morpho-midnight-1.0.0/src/libraries/TickLib.sol";
import { UtilsLib } from "morpho-midnight-1.0.0/src/libraries/UtilsLib.sol";
import { ERC20Permit } from "morpho-midnight-1.0.0/test/erc20s/ERC20Permit.sol";
import { DummyRatifier } from "morpho-midnight-1.0.0/test/helpers/DummyRatifier.sol";
import { Oracle } from "morpho-midnight-1.0.0/test/helpers/Oracle.sol";
import { PermitHash } from "permit2-1.0.0/src/libraries/PermitHash.sol";
import { DeployPermit2 } from "permit2-1.0.0/test/utils/DeployPermit2.sol";

import { IMidnightLeverageCallback } from "src/interfaces/IMidnightLeverageCallback.sol";
import { IMockSwapRouter } from "test/mocks/interfaces/IMockSwapRouter.sol";

import { MidnightLeverageCallback } from "src/MidnightLeverageCallback.sol";
import { MockSwapRouter } from "test/mocks/MockSwapRouter.sol";

abstract contract BaseTest is Test, DeployPermit2 {
    uint256 internal constant LLTV = 0.77e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
    uint256 internal constant MARKET_DURATION = 365 days;
    uint256 internal constant OFFER_DURATION = 30 days;
    uint256 internal constant ONE_TO_ONE_PRICE_TICK = MAX_TICK;

    address internal s_owner;
    uint256 internal s_borrowerPrivateKey;
    address internal s_borrower;
    address internal s_lender;
    address internal s_otherLender;

    ISignatureTransfer internal s_permit2;
    Midnight internal s_midnight;
    ERC20Permit internal s_loanToken;
    ERC20Permit internal s_collateralToken1;
    ERC20Permit internal s_collateralToken2;
    Oracle internal s_oracle1;
    Oracle internal s_oracle2;
    Market internal s_market;
    bytes32 internal s_id;

    MockSwapRouter internal s_router;
    DummyRatifier internal s_ratifier;
    MidnightLeverageCallback internal s_callback;

    error BaseTest__CollateralNotFound();

    function setUp() public virtual {
        s_owner = makeAddr("owner");
        (s_borrower, s_borrowerPrivateKey) = makeAddrAndKey("borrower");
        s_lender = makeAddr("lender");
        s_otherLender = makeAddr("otherLender");

        s_permit2 = ISignatureTransfer(deployPermit2());
        s_midnight = new Midnight();
        s_loanToken = new ERC20Permit("Loan", "LOAN");
        s_collateralToken1 = new ERC20Permit("Collateral 1", "COL1");
        s_collateralToken2 = new ERC20Permit("Collateral 2", "COL2");
        s_oracle1 = new Oracle();
        s_oracle2 = new Oracle();
        s_midnight.setFeeSetter(address(this));
        s_midnight.setTickSpacingSetter(address(this));
        s_midnight.enableLiquidationCursor(LIQUIDATION_CURSOR);
        s_midnight.enableLltv(LLTV);
        _buildMarket();
        s_id = s_midnight.touchMarket(s_market);
        s_midnight.setMarketTickSpacing(s_id, 1);

        s_router = new MockSwapRouter();
        s_ratifier = new DummyRatifier();
        s_callback = new MidnightLeverageCallback(IMidnight(address(s_midnight)), s_permit2, s_owner);
        vm.prank(s_owner);
        s_callback.setIsAllowedSwapRouter(address(s_router), true);

        vm.prank(s_lender);
        s_midnight.setIsAuthorized(address(s_ratifier), true, s_lender);
        vm.prank(s_otherLender);
        s_midnight.setIsAuthorized(address(s_ratifier), true, s_otherLender);
        vm.prank(s_lender);
        s_loanToken.approve(address(s_midnight), type(uint256).max);
        vm.prank(s_otherLender);
        s_loanToken.approve(address(s_midnight), type(uint256).max);
        vm.startPrank(s_borrower);
        s_loanToken.approve(address(s_callback), type(uint256).max);
        s_loanToken.approve(address(s_permit2), type(uint256).max);
        s_midnight.setIsAuthorized(address(s_callback), true, s_borrower);
        vm.stopPrank();
    }

    function _buildMarket() internal {
        s_market.loanToken = address(s_loanToken);
        s_market.chainId = block.chainid;
        s_market.midnight = address(s_midnight);
        s_market.maturity = block.timestamp + MARKET_DURATION;
        s_market.rcfThreshold = 0;

        CollateralParams memory params1 = CollateralParams({
            token: address(s_collateralToken1),
            lltv: LLTV,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(s_oracle1)
        });
        CollateralParams memory params2 = CollateralParams({
            token: address(s_collateralToken2),
            lltv: LLTV,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(s_oracle2)
        });
        if (bytes20(params1.token) < bytes20(params2.token)) {
            s_market.collateralParams.push(params1);
            s_market.collateralParams.push(params2);
        } else {
            s_market.collateralParams.push(params2);
            s_market.collateralParams.push(params1);
        }
    }

    function _collateralIndex(address _token) internal view returns (uint256) {
        for (uint256 i = 0; i < s_market.collateralParams.length; i++) {
            if (s_market.collateralParams[i].token == _token) return i;
        }
        revert BaseTest__CollateralNotFound();
    }

    function _lenderOffer(address _maker, uint256 _maxUnits) internal view returns (Offer memory) {
        Offer memory offer;
        offer.market = s_market;
        offer.buy = true;
        offer.maker = _maker;
        offer.start = block.timestamp;
        offer.expiry = block.timestamp + OFFER_DURATION;
        offer.ratifier = address(s_ratifier);
        offer.maxUnits = UtilsLib.toUint128(_maxUnits);
        offer.continuousFeeCap = s_midnight.continuousFee(s_id);
        offer.tick = ONE_TO_ONE_PRICE_TICK;
        return offer;
    }

    function _open(
        address _maker,
        uint256 _units,
        uint256 _marginAmount,
        uint256 _collateralIndexValue,
        uint256 _collateralOut,
        uint256 _minCollateralAssets
    )
        internal
    {
        _open(
            _maker,
            _units,
            _marginAmount,
            _collateralIndexValue,
            _collateralOut,
            _minCollateralAssets,
            _units + _marginAmount
        );
    }

    function _open(
        address _maker,
        uint256 _units,
        uint256 _marginAmount,
        uint256 _collateralIndexValue,
        uint256 _collateralOut,
        uint256 _minCollateralAssets,
        uint256 _amountToPull
    )
        internal
    {
        deal(address(s_loanToken), _maker, s_loanToken.balanceOf(_maker) + _units);
        deal(address(s_loanToken), s_borrower, s_loanToken.balanceOf(s_borrower) + _marginAmount);

        Offer memory offer = _lenderOffer(_maker, _units);
        IMidnightLeverageCallback.OpenParams memory _params =
            _openParams(_marginAmount, _collateralIndexValue, _collateralOut, _minCollateralAssets, _amountToPull);
        vm.prank(s_borrower);
        s_midnight.take(offer, hex"", _units, s_borrower, address(s_callback), address(s_callback), abi.encode(_params));
    }

    function _openParams(
        uint256 _marginAmount,
        uint256 _collateralIndexValue,
        uint256 _collateralOut,
        uint256 _minCollateralAssets,
        uint256 _amountToPull
    )
        internal
        returns (IMidnightLeverageCallback.OpenParams memory)
    {
        address collateralToken = s_market.collateralParams[_collateralIndexValue].token;
        deal(collateralToken, address(s_router), _collateralOut);

        IMidnightLeverageCallback.OpenParams memory _params = IMidnightLeverageCallback.OpenParams({
            marginAmount: _marginAmount,
            collateralIndex: _collateralIndexValue,
            swapRouter: address(s_router),
            swapCalldata: abi.encodeCall(
                IMockSwapRouter.swap, (address(s_loanToken), collateralToken, _collateralOut, _amountToPull)
            ),
            minCollateralAssets: _minCollateralAssets,
            auth: _emptyPullAuthorization()
        });
        return _params;
    }

    function _signMarginAuthorization(
        IMidnightLeverageCallback.OpenParams memory _params,
        uint256 _nonce
    )
        internal
        view
        returns (IMidnightLeverageCallback.PullAuthorization memory)
    {
        _params.auth.nonce = _nonce;
        _params.auth.deadline = block.timestamp + 1 days;
        address collateralToken = s_market.collateralParams[_params.collateralIndex].token;
        (ISignatureTransfer.PermitTransferFrom memory _permit, bytes32 _witness, string memory _witnessTypeString) =
            s_callback.buildMarginPermitData(address(s_loanToken), s_id, collateralToken, _params);
        return _signPullAuthorization(_permit, _witness, _witnessTypeString);
    }

    function _close(
        uint256 _units,
        uint256 _collateralIndexValue,
        uint256 _collateralAmount,
        uint256 _loanOut,
        uint256 _minLoanAssets,
        uint256 _maxRepayShortfall,
        uint256 _amountToPull
    )
        internal
    {
        IMidnightLeverageCallback.CloseParams memory _params = _closeParams(
            _collateralIndexValue, _collateralAmount, _loanOut, _minLoanAssets, _maxRepayShortfall, _amountToPull
        );

        vm.prank(s_borrower);
        s_midnight.repay(s_market, _units, s_borrower, address(s_callback), abi.encode(_params));
    }

    function _closeParams(
        uint256 _collateralIndexValue,
        uint256 _collateralAmount,
        uint256 _loanOut,
        uint256 _minLoanAssets,
        uint256 _maxRepayShortfall,
        uint256 _amountToPull
    )
        internal
        returns (IMidnightLeverageCallback.CloseParams memory)
    {
        deal(address(s_loanToken), address(s_router), s_loanToken.balanceOf(address(s_router)) + _loanOut);

        IMidnightLeverageCallback.CloseParams memory _params = IMidnightLeverageCallback.CloseParams({
            collateralIndex: _collateralIndexValue,
            collateralAmount: _collateralAmount,
            swapRouter: address(s_router),
            swapCalldata: abi.encodeCall(
                IMockSwapRouter.swap,
                (s_market.collateralParams[_collateralIndexValue].token, address(s_loanToken), _loanOut, _amountToPull)
            ),
            minLoanAssets: _minLoanAssets,
            maxRepayShortfall: _maxRepayShortfall,
            auth: _emptyPullAuthorization()
        });
        return _params;
    }

    function _signRepayAuthorization(
        IMidnightLeverageCallback.CloseParams memory _params,
        uint256 _permittedAmount,
        uint256 _nonce
    )
        internal
        view
        returns (IMidnightLeverageCallback.PullAuthorization memory)
    {
        _params.auth.nonce = _nonce;
        _params.auth.deadline = block.timestamp + 1 days;
        address collateralToken = s_market.collateralParams[_params.collateralIndex].token;
        (ISignatureTransfer.PermitTransferFrom memory _permit, bytes32 _witness, string memory _witnessTypeString) =
            s_callback.buildRepayPermitData(address(s_loanToken), s_id, collateralToken, _params);
        assertEq(_permit.permitted.amount, _permittedAmount);
        return _signPullAuthorization(_permit, _witness, _witnessTypeString);
    }

    function _emptyPullAuthorization() internal pure returns (IMidnightLeverageCallback.PullAuthorization memory) {
        IMidnightLeverageCallback.PullAuthorization memory auth;
        return auth;
    }

    function _signPullAuthorization(
        ISignatureTransfer.PermitTransferFrom memory _permit,
        bytes32 _witness,
        string memory _witnessTypeString
    )
        internal
        view
        returns (IMidnightLeverageCallback.PullAuthorization memory)
    {
        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(PermitHash._TOKEN_PERMISSIONS_TYPEHASH, _permit.permitted.token, _permit.permitted.amount)
        );
        bytes32 permitTypeHash =
            keccak256(abi.encodePacked(PermitHash._PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB, _witnessTypeString));
        bytes32 dataHash = keccak256(
            abi.encode(
                permitTypeHash, tokenPermissionsHash, address(s_callback), _permit.nonce, _permit.deadline, _witness
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IEIP712(address(s_permit2)).DOMAIN_SEPARATOR(), dataHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(s_borrowerPrivateKey, digest);

        return IMidnightLeverageCallback.PullAuthorization({
            nonce: _permit.nonce, deadline: _permit.deadline, signature: abi.encodePacked(r, s, v)
        });
    }
}
