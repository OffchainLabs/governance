// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

interface IL1GatewayRouter {
    function setGateways(
        address[] memory _token,
        address[] memory _gateway,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost
    ) external payable returns (uint256);
    function getGateway(address _token) external view returns (address gateway);
}

/// @notice Set the USDT gateway to address(1) to disable USDT on the token bridge
contract DisableUSDTAction {
    /// @notice The token bridge L1 gateway router
    IL1GatewayRouter public constant gatewayRouter = IL1GatewayRouter(0x72Ce9c846789fdB6fC1f34aC4AD25Dd9ef7031ef);
    /// @notice The USDT token address
    address public constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    /// @notice The new gateway address (address(1) disables the token)
    address public constant newGateway = address(1);

    function perform() external {
        address[] memory tokens = new address[](1);
        address[] memory gateways = new address[](1);

        tokens[0] = usdt;
        gateways[0] = newGateway;

        // set the gateway
        // send the UpgradeExecutor balance as submission fee
        // the UpgradeExecutor must be funded with selfdestruct before action execution
        gatewayRouter.setGateways{value: address(this).balance}(
            tokens,
            gateways,
            0,
            0,
            address(this).balance
        );

        // check that the gateway was set correctly
        require(gatewayRouter.getGateway(usdt) == address(0), "DisableUSDTAction: gateway not disabled");
    }
}