// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorPreventLateQuorumUpgradeable.sol";
import
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import
    "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title  L2ArbitrumGovernor
/// @notice Governance controls for the Arbitrum DAO
/// @dev    Standard governor with some special functionality to avoid counting
///         votes of some excluded tokens. Also allows for an owner to set parameters by calling
///         relay.
contract L2ArbitrumGovernor is
    Initializable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorTimelockControlUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorPreventLateQuorumUpgradeable,
    OwnableUpgradeable
{
    /// @notice address for which votes will not be counted toward quorum
    /// @dev    A portion of the Arbitrum tokens will be held by entities (eg the treasury) that
    ///         are not eligible to vote. However, even if their voting/delegation is restricted their
    ///         tokens will still count towards the total supply, and will therefore affect the quorum.
    ///         Restricted addresses should be forced to delegate their votes to this special exclude
    ///         addresses which is not counted when calculating quorum
    ///         Example address that should be excluded: DAO treasury, foundation, unclaimed tokens,
    ///         burned tokens and swept (see TokenDistributor) tokens.
    ///         Note that Excluded Address is a readable name with no code of PK associated with it, and thus can't vote.
    address public constant EXCLUDE_ADDRESS = address(0xA4b86);

    /// @notice Get the proposer of a proposal
    mapping(uint256 => address) public proposalProposer;

    constructor() {
        _disableInitializers();
    }

    /// @param _token The token to read vote delegation from
    /// @param _timelock A time lock for proposal execution
    /// @param _owner The executor through which all upgrades should be finalised
    /// @param _votingDelay The delay between a proposal submission and voting starts
    /// @param _votingPeriod The period for which the vote lasts
    /// @param _quorumNumerator The proportion of the circulating supply required to reach a quorum
    /// @param _proposalThreshold The number of delegated votes required to create a proposal
    /// @param _minPeriodAfterQuorum The minimum number of blocks available for voting after the quorum is reached
    function initialize(
        IVotesUpgradeable _token,
        TimelockControllerUpgradeable _timelock,
        address _owner,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _quorumNumerator,
        uint256 _proposalThreshold,
        uint64 _minPeriodAfterQuorum
    ) external initializer {
        __Governor_init("L2ArbitrumGovernor");
        __GovernorSettings_init(_votingDelay, _votingPeriod, _proposalThreshold);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(_token);
        __GovernorTimelockControl_init(_timelock);
        __GovernorVotesQuorumFraction_init(_quorumNumerator);
        __GovernorPreventLateQuorum_init(_minPeriodAfterQuorum);
        _transferOwnership(_owner);
    }

    /// @notice Allows the owner to make calls from the governor
    /// @dev    We want the owner to be able to upgrade settings and parametes on this Governor
    ///         however we can't use onlyGovernance as it requires calls originate from the governor
    ///         contract. The normal flow for onlyGovernance to work is to call execute on the governor
    ///         which will then call out to the _executor(), which will then call back in to the governor to set
    ///         a parameter. At the point of setting the parameter onlyGovernance is checked, and this includes
    ///         a check this call originated in the execute() function. The purpose of this is an added
    ///         safety measure that ensure that all calls originate at the governor, and if second entrypoint is
    ///         added to the _executor() contract, that new entrypoint will not be able to pass the onlyGovernance check.
    ///         You can read more about this in the comments on onlyGovernance()
    ///         This flow doesn't work for Arbitrum governance as we require an proposal on L2 to first
    ///         be relayed to L1, and then back again to L2 before calling into the governor to update
    ///         settings. This means that updating settings can't be done in a single transaction.
    ///         There are two potential solutions to this problem:
    ///         1.  Use a more persistent record that a specific upgrade is taking place. This adds
    ///             a lot of complexity, as we have multiple layers of calldata wrapping each other to
    ///             define the multiple transactions that occur in a round-trip upgrade. So safely recording
    ///             execution of the would be difficult and brittle.
    ///         2.  Override this protection and just ensure elsewhere that the executor only has the
    ///             the correct entrypoints and access control. We've gone for this option.
    ///         By overriding the relay function we allow the executor to make any call originating
    ///         from the governor, and by setting the _executor() to be the governor itself we can use the
    ///         relay function to call back into the governor to update settings e.g:
    ///
    ///         l2ArbitrumGovernor.relay(
    ///             address(l2ArbitrumGovernor),
    ///             0,
    ///             abi.encodeWithSelector(l2ArbitrumGovernor.updateQuorumNumerator.selector, 4)
    ///         );
    function relay(address target, uint256 value, bytes calldata data)
        external
        virtual
        override
        onlyOwner
    {
        AddressUpgradeable.functionCallWithValue(target, data, value);
    }

    /** 
     * @notice Cancel a proposal. Can only be called by the proposer.
     */
    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public virtual returns (uint256 proposalId) {
        proposalId = hashProposal(targets, values, calldatas, descriptionHash);
        require(state(proposalId) == ProposalState.Pending, "L2ArbitrumGovernor: too late to cancel");
        require(_msgSender() == proposalProposer[proposalId], "L2ArbitrumGovernor: not proposer");
        _cancel(targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev See {IGovernor-propose}. This function has opt-in frontrunning protection, described in {_isValidDescriptionForProposer}.
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override(IGovernorUpgradeable, GovernorUpgradeable) returns (uint256) {
        address _proposer = _msgSender();
        require(_isValidDescriptionForProposer(_proposer, description), "L2ArbitrumGovernor: proposer restricted");
        uint256 proposalId = GovernorUpgradeable.propose(targets, values, calldatas, description);
        proposalProposer[proposalId] = _proposer;
        return proposalId;
    }

    /// @notice returns l2 executor address; used internally for onlyGovernance check
    function _executor()
        internal
        view
        override(GovernorTimelockControlUpgradeable, GovernorUpgradeable)
        returns (address)
    {
        return address(this);
    }

    /// @notice Get "circulating" votes supply; i.e., total minus excluded vote exclude address.
    function getPastCirculatingSupply(uint256 blockNumber) public view virtual returns (uint256) {
        return
            token.getPastTotalSupply(blockNumber) - token.getPastVotes(EXCLUDE_ADDRESS, blockNumber);
    }

    /// @notice Calculates the quorum size, excludes token delegated to the exclude address
    function quorum(uint256 blockNumber)
        public
        view
        override(IGovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        return (getPastCirculatingSupply(blockNumber) * quorumNumerator(blockNumber))
            / quorumDenominator();
    }

    /// @inheritdoc GovernorVotesQuorumFractionUpgradeable
    function quorumDenominator()
        public
        pure
        override(GovernorVotesQuorumFractionUpgradeable)
        returns (uint256)
    {
        // update to 10k to allow for higher precision
        return 10_000;
    }

    // Overrides:

    // @notice Votes required for proposal.
    function proposalThreshold()
        public
        view
        override(GovernorSettingsUpgradeable, GovernorUpgradeable)
        returns (uint256)
    {
        return GovernorSettingsUpgradeable.proposalThreshold();
    }

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return GovernorTimelockControlUpgradeable.state(proposalId);
    }

    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        string memory reason,
        bytes memory params
    )
        internal
        override(GovernorUpgradeable, GovernorPreventLateQuorumUpgradeable)
        returns (uint256)
    {
        return GovernorPreventLateQuorumUpgradeable._castVote(
            proposalId, account, support, reason, params
        );
    }

    function proposalDeadline(uint256 proposalId)
        public
        view
        override(IGovernorUpgradeable, GovernorUpgradeable, GovernorPreventLateQuorumUpgradeable)
        returns (uint256)
    {
        return GovernorPreventLateQuorumUpgradeable.proposalDeadline(proposalId);
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        GovernorTimelockControlUpgradeable._execute(
            proposalId, targets, values, calldatas, descriptionHash
        );
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint256)
    {
        return
            GovernorTimelockControlUpgradeable._cancel(targets, values, calldatas, descriptionHash);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        bytes4 governorCancelId = this.cancel.selector ^ this.proposalProposer.selector;
        return interfaceId == governorCancelId || GovernorTimelockControlUpgradeable.supportsInterface(interfaceId);
    }

    /**
     * @dev This project uses OZ v4.7.3, which has a vulnerability in proposal cancellation that was patched in v4.9.1.
     *
     * For details on the vulnerability, see here: 
     * https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories/GHSA-5h3x-9wvq-w4m2
     *
     * _isValidDescriptionForProposer and its usage in propose is a backport of the fix in OZ v4.9.1, which can be found here:
     * https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/commit/66f390fa516b550838e2c2f65132b5bc2afe1ced
     * Check if the proposer is authorized to submit a proposal with the given description.
     *
     * If the proposal description ends with `#proposer=0x???`, where `0x???` is an address written as a hex string
     * (case insensitive), then the submission of this proposal will only be authorized to said address.
     *
     * This is used for frontrunning protection. By adding this pattern at the end of their proposal, one can ensure
     * that no other address can submit the same proposal. An attacker would have to either remove or change that part,
     * which would result in a different proposal id.
     *
     * If the description does not match this pattern, it is unrestricted and anyone can submit it. This includes:
     * - If the `0x???` part is not a valid hex string.
     * - If the `0x???` part is a valid hex string, but does not contain exactly 40 hex digits.
     * - If it ends with the expected suffix followed by newlines or other whitespace.
     * - If it ends with some other similar suffix, e.g. `#other=abc`.
     * - If it does not end with any such suffix.
     */
    function _isValidDescriptionForProposer(
        address proposer_,
        string memory description
    ) internal view virtual returns (bool) {
        uint256 len = bytes(description).length;

        // Length is too short to contain a valid proposer suffix
        if (len < 52) {
            return true;
        }

        // Extract what would be the `#proposer=0x` marker beginning the suffix
        bytes12 marker;
        assembly {
            // - Start of the string contents in memory = description + 32
            // - First character of the marker = len - 52
            //   - Length of "#proposer=0x0000000000000000000000000000000000000000" = 52
            // - We read the memory word starting at the first character of the marker:
            //   - (description + 32) + (len - 52) = description + (len - 20)
            // - Note: Solidity will ignore anything past the first 12 bytes
            marker := mload(add(description, sub(len, 20)))
        }

        // If the marker is not found, there is no proposer suffix to check
        if (marker != bytes12("#proposer=0x")) {
            return true;
        }

        // Parse the 40 characters following the marker as uint160
        uint160 recovered = 0;
        for (uint256 i = len - 40; i < len; ++i) {
            (bool isHex, uint8 value) = _tryHexToUint(bytes(description)[i]);
            // If any of the characters is not a hex digit, ignore the suffix entirely
            if (!isHex) {
                return true;
            }
            recovered = (recovered << 4) | value;
        }

        return recovered == uint160(proposer_);
    }

    /**
     * from https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/commit/66f390fa516b550838e2c2f65132b5bc2afe1ced
     * @dev Try to parse a character from a string as a hex value. Returns `(true, value)` if the char is in
     * `[0-9a-fA-F]` and `(false, 0)` otherwise. Value is guaranteed to be in the range `0 <= value < 16`
     */
    function _tryHexToUint(bytes1 char) private pure returns (bool, uint8) {
        uint8 c = uint8(char);
        unchecked {
            // Case 0-9
            if (47 < c && c < 58) {
                return (true, c - 48);
            }
            // Case A-F
            else if (64 < c && c < 71) {
                return (true, c - 55);
            }
            // Case a-f
            else if (96 < c && c < 103) {
                return (true, c - 87);
            }
            // Else: not a hex char
            else {
                return (false, 0);
            }
        }
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}
