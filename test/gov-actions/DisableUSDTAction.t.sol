// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUpgradeExecutor} from "src/interfaces/IUpgradeExecutor.sol";
import {DisableUSDTAction} from "src/gov-action-contracts/AIPs/DisableUSDT/DisableUSDTAction.sol";

interface IL1GatewayRouter {
    function outboundTransfer(
        address _token,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable returns (bytes memory);
}

contract DisableUSDTActionTest is Test {
    using SafeERC20 for IERC20;

    uint256 l2ForkBlock = 306_033_004;
    uint256 l1ForkBlock = 21_845_939;

    DisableUSDTAction public disableUSDTAction;
    IUpgradeExecutor ue = IUpgradeExecutor(0x3ffFbAdAF827559da092217e474760E2b2c3CeDd);
    address timelock = 0xE6841D92B0C345144506576eC13ECf5103aC7f49;
    IL1GatewayRouter public l1GatewayRouter =
        IL1GatewayRouter(0x72Ce9c846789fdB6fC1f34aC4AD25Dd9ef7031ef);
    IERC20 public usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    error InsufficientSubmissionCost(uint256, uint256);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_URL"), l1ForkBlock);
        disableUSDTAction = new DisableUSDTAction();
    }

    function testPerform() public {
        // should fail without funding
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientSubmissionCost.selector, 3_569_349_724_304, 0)
        );
        _upgradeL1();

        // should pass with funding
        vm.deal(address(ue), 3_569_349_724_304);
        _upgradeL1();
    }

    function testBridgeDisabled() public {
        address whale = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
        vm.startPrank(whale);
        usdt.safeApprove(0xcEe284F754E854890e311e3280b767F80797180d, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientSubmissionCost.selector, 4_633_503_679_376, 0)
        );
        l1GatewayRouter.outboundTransfer(
            address(usdt), whale, 10e6, 0, 0, abi.encode(uint256(0), bytes(""))
        );
        vm.stopPrank();

        vm.deal(address(ue), 3_569_349_724_304);
        _upgradeL1();

        vm.prank(whale);
        vm.expectRevert(bytes(""));
        l1GatewayRouter.outboundTransfer(
            address(usdt), whale, 10e6, 0, 0, abi.encode(uint256(0), bytes(""))
        );
    }

    function _upgradeL1() internal {
        vm.prank(timelock);
        ue.execute(
            address(disableUSDTAction), abi.encodeWithSelector(disableUSDTAction.perform.selector)
        );
    }
}
