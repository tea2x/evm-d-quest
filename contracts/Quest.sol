// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "./lib/DQuestStructLib.sol";
import "./lib/MissionFormula.sol";
import "./interface/IQuest.sol";
import "./interface/IMission.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract Quest is IQuest, Initializable, OwnableUpgradeable, PausableUpgradeable {
    using MissionFormula for MissionFormula.efficientlyResetableFormula;

    address public dQuestOracle; // todo: single or many oracles for dquest?
    MissionFormula.efficientlyResetableFormula missionNodeFormulas;
    address[] allQuesters;
    mapping(address quester =>  QuesterProgress progress) questerProgresses;
    uint256 startTimestamp;
    uint256 endTimestamp;

    modifier onlyOracle() {
        require(msg.sender == dQuestOracle, "For oracle only");
        _;
    }

    // TODO: check allQuesters's role
    modifier onlyQuester() {
        require(
            questerProgresses[msg.sender] != QuesterProgress.NotEnrolled,
            "For questers only"
        );
        _;
    }

    modifier questerNotEnrolled() {
        require(
            questerProgresses[msg.sender] == QuesterProgress.NotEnrolled,
            "Quester already joined"
        );
        _;
    }
    
    // when quest is inactive
    modifier whenInactive() {
        require(block.timestamp < startTimestamp, "Quest has started");
        _;
    }

    // when quest is active
    modifier whenActive() {
        //require(status == QuestStatus.Active, "Quest is not Active");
        require(startTimestamp <= block.timestamp && block.timestamp <= endTimestamp, "Quest is not Active");
        _;
    }

    // when quest is closed/expired
    modifier whenClosed() {
        //require(status != QuestStatus.Closed, "Quest is expired");
        require(block.timestamp > endTimestamp, "Quest is expired");
        _;
    }

    // prettier-ignore
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
    * @dev Initializes the contract with the specified mission nodes and quest start/end times.
    * @notice This function can only be called during the initialization phase of the contract.
    * @notice Check docstrings of setMissionNodeFormulas carefully
    * @param nodes The array of mission nodes to set.
    * @param questStartTime The timestamp at which the quest starts.
    * @param questEndTime The timestamp at which the quest ends.
    * Emits a `MissionNodeFormulasSet` event.
    */
    function init(
        DQuestStructLib.MissionNode[] calldata nodes,
        DQuestStructLib.Outcome[] calldata outcomes,
        address oracle,
        uint256 questStartTime,
        uint256 questEndTime
    ) internal onlyInitializing {
        //TODO check carefully
        require(questStartTime < questEndTime, "Invalid quest lifetime");
        __Ownable_init();
        __Pausable_init();
        setMissionNodeFormulas(nodes);
        setOutcomes(outcomes);
        setOracle(oracle);
        startTimestamp = questStartTime;
        endTimestamp = questEndTime;
    }

    function setOracle(address oracle) public override onlyOwner {
        require(oracle != address(0x0), "Oracle can't be address 0x0");
        dQuestOracle = oracle;
    }

    function setMissionNodeFormulas(DQuestStructLib.MissionNode[] calldata nodes)
        public
        override
        onlyOwner
        whenInactive
    {
        require(nodes.length > 0, "Empty node list");
        // TODO: Validation of input mission nodes: mission interface, binary tree index...
        missionNodeFormulas._set(nodes);
        emit MissionNodeFormulasSet(nodes);
    }

    /**
     * @dev evaluate mission formula
     * @param nodeId Always the root node of the formula
     * @param user address of user's to be verified
     */
    function evalMF(
        uint256 nodeId,
        address user
    ) private returns (bool) {
        //TODO validate the binary tree's depth
        DQuestStructLib.MissionNode memory node = missionNodeFormulas._getNode(nodeId);
        if (node.isMission) {
            return validateMission(nodeId);
        } else {
            bool leftResult = evalMF(node.leftNode, user);
            bool rightResult = evalMF(node.rightNode, user);
            if (node.operatorType == DQuestStructLib.OperatorType.AND) {
                return leftResult && rightResult;
            } else {
                return leftResult || rightResult;
            }
        }
    }

    function validateQuest() external override onlyQuester whenNotPaused returns (bool) {
        bool result = evalMF(0, msg.sender);
        if (result == true) {
            questerProgresses[msg.sender] = QuesterProgress.Completed;
        } else {
            questerProgresses[msg.sender] = QuesterProgress.InProgress;
        }
        return result;
    }

    function validateMission(uint256 missionNodeId) public override onlyQuester whenNotPaused returns(bool) {
        DQuestStructLib.MissionNode memory node = missionNodeFormulas._getNode(missionNodeId);
        require(node.isMission == true, "Not a mission");
        IMission mission = IMission(node.missionHandlerAddress);
        return mission.validateMission(msg.sender, node);
    }

    function pauseQuest() external override onlyOwner {
        _pause();
    }

    function resumeQuest() external override onlyOwner {
        _unpause();
    }

    function addQuester() external override whenActive questerNotEnrolled {
        allQuesters.push(msg.sender);
        questerProgresses[msg.sender] = QuesterProgress.InProgress;
        emit QuesterAdded(msg.sender);
    }

    function getTotalQuesters() external view override returns (uint256 totalQuesters) {
        return allQuesters.length;
    }

    /**
    * @dev Sets the list of possible outcomes for the quest.
    * Only the contract owner can call this function.
    * @param _outcomes The list of possible outcomes to set.
    */
    function setOutcomes(DQuestStructLib.Outcome[] calldata _outcomes) public override onlyOwner {
        // TODO
    }

    /**
    * @dev Executes the quest outcome for the specified quester.
    * Only the quest can call this function when the quest is active.
    * @param _quester The address of the quester whose outcome to execute.
    * @return result Whether the outcome was successfully executed.
    */
    function executeQuestOutcome(address _quester) external override whenActive returns (bool result) {
        //TODO set questerProgresses[msg.sender] = QuesterProgress.Rewarded;
    }
}