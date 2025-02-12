// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import {Test} from "forge-std/Test.sol";
import {IUpgradeExecutor} from "src/interfaces/IUpgradeExecutor.sol";
import {DisableUSDTAction} from "src/gov-action-contracts/AIPs/DisableUSDT/DisableUSDTAction.sol";

contract DisableUSDTActionTest is Test {
    DisableUSDTAction public disableUSDTAction;
    IUpgradeExecutor ue = IUpgradeExecutor(0x3ffFbAdAF827559da092217e474760E2b2c3CeDd);
    address timelock = 0xE6841D92B0C345144506576eC13ECf5103aC7f49;

    error InsufficientSubmissionCost(uint,uint);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_URL"), 21833226);
        disableUSDTAction = new DisableUSDTAction();
    }

    function testPerform() public {
        // should fail without funding
        vm.expectRevert(abi.encodeWithSelector(InsufficientSubmissionCost.selector, 2441046598032, 0));
        vm.prank(timelock);
        ue.execute(address(disableUSDTAction), abi.encodeWithSelector(disableUSDTAction.perform.selector));

        // should pass with funding
        vm.deal(address(ue), 2441046598032);
        vm.prank(timelock);
        ue.execute(address(disableUSDTAction), abi.encodeWithSelector(disableUSDTAction.perform.selector));
    }

    function testBridgeRevert() public {
        revert("TODO");
    }
}