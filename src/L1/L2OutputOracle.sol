// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@redprint-openzeppelin/proxy/utils/Initializable.sol";
import {ISemver} from "@redprint-core/universal/interfaces/ISemver.sol";
import {Types} from "@redprint-core/libraries/Types.sol";

/// @custom:security-contact Consult full code at https://github.com/ethereum-optimism/optimism/blob/v1.9.4/packages/contracts-bedrock/src/L1/L2OutputOracle.sol
contract L2OutputOracle is Initializable, ISemver {
    uint256 public startingBlockNumber;
    /// @notice The timestamp of the first L2 block recorded in this contract.
    uint256 public startingTimestamp;
    /// @notice An array of L2 output proposals.
    Types.OutputProposal[] internal l2Outputs;
    /// @notice The interval in L2 blocks at which checkpoints must be submitted.
    /// @custom:network-specific
    uint256 public submissionInterval;
    /// @notice The time between L2 blocks in seconds. Once set, this value MUST NOT be modified.
    /// @custom:network-specific
    uint256 public l2BlockTime;
    /// @notice The address of the challenger. Can be updated via upgrade.
    /// @custom:network-specific
    address public challenger;
    /// @notice The address of the proposer. Can be updated via upgrade.
    /// @custom:network-specific
    address public proposer;
    /// @notice The minimum time (in seconds) that must elapse before a withdrawal can be finalized.
    /// @custom:network-specific
    uint256 public finalizationPeriodSeconds;
    /// @notice Emitted when an output is proposed.
    /// @param outputRoot    The output root.
    /// @param l2OutputIndex The index of the output in the l2Outputs array.
    /// @param l2BlockNumber The L2 block number of the output root.
    /// @param l1Timestamp   The L1 timestamp when proposed.
    event OutputProposed(
        bytes32 indexed outputRoot, uint256 indexed l2OutputIndex, uint256 indexed l2BlockNumber, uint256 l1Timestamp
    );
    /// @notice Emitted when outputs are deleted.
    /// @param prevNextOutputIndex Next L2 output index before the deletion.
    /// @param newNextOutputIndex  Next L2 output index after the deletion.
    event OutputsDeleted(uint256 indexed prevNextOutputIndex, uint256 indexed newNextOutputIndex);
    /// @notice Semantic version.
    /// @custom:semver 1.8.1-beta.2
    string public constant version = "1.8.1-beta.2";

    constructor() {
        initialize({
            _submissionInterval: 1,
            _l2BlockTime: 1,
            _startingBlockNumber: 0,
            _startingTimestamp: 0,
            _proposer: address(0),
            _challenger: address(0),
            _finalizationPeriodSeconds: 0
        });
    }

    function initialize(uint256 _submissionInterval, uint256 _l2BlockTime, uint256 _startingBlockNumber, uint256 _startingTimestamp, address _proposer, address _challenger, uint256 _finalizationPeriodSeconds)
        public
        initializer
    {
        require(_submissionInterval > 0, "L2OutputOracle: submission interval must be greater than 0");
        require(_l2BlockTime > 0, "L2OutputOracle: L2 block time must be greater than 0");
        require(
            _startingTimestamp <= block.timestamp,
            "L2OutputOracle: starting L2 timestamp must be less than current time"
        );

        submissionInterval = _submissionInterval;
        l2BlockTime = _l2BlockTime;
        startingBlockNumber = _startingBlockNumber;
        startingTimestamp = _startingTimestamp;
        proposer = _proposer;
        challenger = _challenger;
        finalizationPeriodSeconds = _finalizationPeriodSeconds;
    }

    function SUBMISSION_INTERVAL() external view returns (uint256) {
        return submissionInterval;
    }

    function CHALLENGER() external view returns (address) {
        return challenger;
    }

    function L2_BLOCK_TIME() external view returns (uint256) {
        return l2BlockTime;
    }

    function PROPOSER() external view returns (address) {
        return proposer;
    }

    function FINALIZATION_PERIOD_SECONDS() external view returns (uint256) {
        return finalizationPeriodSeconds;
    }

    function deleteL2Outputs(uint256 _l2OutputIndex) external {
        require(msg.sender == challenger, "L2OutputOracle: only the challenger address can delete outputs");

        // Make sure we're not *increasing* the length of the array.
        require(
            _l2OutputIndex < l2Outputs.length, "L2OutputOracle: cannot delete outputs after the latest output index"
        );

        // Do not allow deleting any outputs that have already been finalized.
        require(
            block.timestamp - l2Outputs[_l2OutputIndex].timestamp < finalizationPeriodSeconds,
            "L2OutputOracle: cannot delete outputs that have already been finalized"
        );

        uint256 prevNextL2OutputIndex = nextOutputIndex();

        // Use assembly to delete the array elements because Solidity doesn't allow it.
        assembly {
            sstore(l2Outputs.slot, _l2OutputIndex)
        }

        emit OutputsDeleted(prevNextL2OutputIndex, _l2OutputIndex);
    }

    function proposeL2Output(bytes32 _outputRoot, uint256 _l2BlockNumber, bytes32 _l1BlockHash, uint256 _l1BlockNumber)
        external payable
    {
        require(msg.sender == proposer, "L2OutputOracle: only the proposer address can propose new outputs");

        require(
            _l2BlockNumber == nextBlockNumber(),
            "L2OutputOracle: block number must be equal to next expected block number"
        );

        require(
            computeL2Timestamp(_l2BlockNumber) < block.timestamp,
            "L2OutputOracle: cannot propose L2 output in the future"
        );

        require(_outputRoot != bytes32(0), "L2OutputOracle: L2 output proposal cannot be the zero hash");

        if (_l1BlockHash != bytes32(0)) {
            // This check allows the proposer to propose an output based on a given L1 block,
            // without fear that it will be reorged out.
            // It will also revert if the blockheight provided is more than 256 blocks behind the
            // chain tip (as the hash will return as zero). This does open the door to a griefing
            // attack in which the proposer's submission is censored until the block is no longer
            // retrievable, if the proposer is experiencing this attack it can simply leave out the
            // blockhash value, and delay submission until it is confident that the L1 block is
            // finalized.
            require(
                blockhash(_l1BlockNumber) == _l1BlockHash,
                "L2OutputOracle: block hash does not match the hash at the expected height"
            );
        }

        emit OutputProposed(_outputRoot, nextOutputIndex(), _l2BlockNumber, block.timestamp);

        l2Outputs.push(
            Types.OutputProposal({
                outputRoot: _outputRoot,
                timestamp: uint128(block.timestamp),
                l2BlockNumber: uint128(_l2BlockNumber)
            })
        );
    }

    function getL2Output(uint256 _l2OutputIndex)
        external
        view
        returns (Types.OutputProposal memory)
    {
        return l2Outputs[_l2OutputIndex];
    }

    function getL2OutputIndexAfter(uint256 _l2BlockNumber)
        public
        view
        returns (uint256)
    {
        // Make sure an output for this block number has actually been proposed.
        require(
            _l2BlockNumber <= latestBlockNumber(),
            "L2OutputOracle: cannot get output for a block that has not been proposed"
        );

        // Make sure there's at least one output proposed.
        require(l2Outputs.length > 0, "L2OutputOracle: cannot get output as no outputs have been proposed yet");

        // Find the output via binary search, guaranteed to exist.
        uint256 lo = 0;
        uint256 hi = l2Outputs.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (l2Outputs[mid].l2BlockNumber < _l2BlockNumber) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        return lo;
    }

    function getL2OutputAfter(uint256 _l2BlockNumber)
        external
        view
        returns (Types.OutputProposal memory)
    {
        return l2Outputs[getL2OutputIndexAfter(_l2BlockNumber)];
    }

    function latestOutputIndex() external view returns (uint256) {
        return l2Outputs.length - 1;
    }

    function nextOutputIndex() public view returns (uint256) {
        return l2Outputs.length;
    }

    function latestBlockNumber() public view returns (uint256) {
        return l2Outputs.length == 0 ? startingBlockNumber : l2Outputs[l2Outputs.length - 1].l2BlockNumber;
    }

    function nextBlockNumber() public view returns (uint256) {
        return latestBlockNumber() + submissionInterval;
    }

    function computeL2Timestamp(uint256 _l2BlockNumber)
        public
        view
        returns (uint256)
    {
         return startingTimestamp + ((_l2BlockNumber - startingBlockNumber) * l2BlockTime);
    }
}
