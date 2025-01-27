// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IChainlinkMissionHandler {
    event RequestFulfilled(bytes32 indexed requestId);

    /// @dev receive response from oracle
    /// @param requestId: oracle request ID
    /// @param quester: user address to do mission
    /// @param missionId: mission ID
    /// @param completed: mission status
    function fulfill(bytes32 requestId, address quester, uint256 missionId, bool completed) external;

    /// @dev withdraw all fee in contract
    function withdraw() external;

    function setJob(bytes32 id) external;

    function setOracle(address oracle) external;

    function setLink(address linkAddress) external;

    function setFee(uint256 fee) external;
}
