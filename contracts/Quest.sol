// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "./lib/DQuestStructLib.sol";
import "./lib/MissionFormula.sol";
import "./lib/OutcomeManager.sol";
import "./lib/NodeId2IteratorHelper.sol";
import "./interface/IQuest.sol";
import "./interface/IMission.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract Quest is IQuest, Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using MissionFormula for MissionFormula.efficientlyResetableFormula;
    using OutcomeManager for OutcomeManager.efficientlyResetableOutcome;
    using mNodeId2Iterator for mNodeId2Iterator.ResetableId2iterator;

    // binary tree cycles detection helpers
    mNodeId2Iterator.ResetableId2iterator id2itr1;
    mNodeId2Iterator.ResetableId2iterator id2itr2;
    uint256 formulaRootNodeId;

    // contract storage
    MissionFormula.efficientlyResetableFormula missionNodeFormulas;
    OutcomeManager.efficientlyResetableOutcome outcomes;
    address[] allQuesters;
    mapping(address quester => QuesterProgress progress) questerProgresses;
    mapping(address quester => mapping(uint256 missionNodeId => bool isDone)) questerMissionsDone;
    uint256 startTimestamp;
    uint256 endTimestamp;
    bool public isRewardAvailable;

    bytes4 constant SELECTOR_TRANSFERFROM = bytes4(keccak256(bytes("transferFrom(address,address,uint256)")));
    bytes4 constant SELECTOR_SAFETRANSFERFROM = bytes4(keccak256(bytes("safeTransferFrom(address,address,uint256)")));
    bytes4 constant SELECTOR_NFTSTANDARDMINT =
        bytes4(keccak256(bytes("mint(uint256,address[],uint256,uint256[],bytes32[])")));
    bytes4 constant SELECTOR_SBTMINT = bytes4(keccak256(bytes("mint(address[],uint256)")));

    // utility mapping for NFT handler only
    mapping(address => mapping(uint256 => bool)) tokenUsed;

    // TODO: check allQuesters's role
    modifier onlyQuester() {
        require(questerProgresses[msg.sender] != QuesterProgress.NotEnrolled, "For questers only");
        _;
    }

    modifier questerNotEnrolled() {
        require(questerProgresses[msg.sender] == QuesterProgress.NotEnrolled, "Quester already joined");
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
     * @param outcomeList The array of outcomes to be executed.
     * @param questStartTime The timestamp at which the quest starts.
     * @param questEndTime The timestamp at which the quest ends.
     * Emits a `MissionNodeFormulasSet` event.
     */
    function init(
        address owner,
        DQuestStructLib.MissionNode[] calldata nodes,
        DQuestStructLib.Outcome[] calldata outcomeList,
        uint256 questStartTime,
        uint256 questEndTime
    ) external initializer {
        //TODO check carefully
        require(questStartTime < questEndTime, "Invalid quest lifetime");
        require(block.timestamp < questStartTime, "Starting time is over");
        startTimestamp = questStartTime;
        endTimestamp = questEndTime;
        __Ownable_init();
        __Pausable_init();
        setMissionNodeFormulas(nodes);
        setOutcomes(outcomeList);
        // d.quest's transfering ownership to quest admin
        transferOwnership(owner);
    }

    function setMissionStatus(
        address quester,
        uint256 missionNodeId,
        bool isMissionDone
    ) external {
        DQuestStructLib.MissionNode memory node = missionNodeFormulas._getNode(missionNodeId);
        require(
            msg.sender == node.missionHandlerAddress || msg.sender == node.oracleAddress,
            "Can not update cross-mission states"
        );
        require(questerProgresses[quester] != QuesterProgress.NotEnrolled, "Not a quester");
        questerMissionsDone[quester][missionNodeId] = isMissionDone;
    }

    function setMissionNodeFormulas(DQuestStructLib.MissionNode[] calldata nodes)
        public
        override
        onlyOwner
        whenInactive
    {
        // TODO: improve validation of input mission nodes
        validateFormulaInput(nodes);
        require(missionNodeFormulas._set(nodes), "Fail to set mission formula");
        emit MissionNodeFormulasSet(nodes);
    }

    /**
     * @dev evaluate mission formula
     * @param nodeId Always the root node of the formula
     */
    function evaluateMissionFormulaTree(
        uint256 nodeId
    ) private returns (bool) {
        //TODO validate the binary tree's depth
        DQuestStructLib.MissionNode memory node = missionNodeFormulas._getNode(nodeId);
        if (node.isMission) {
            return validateMission(nodeId);
        } else {
            bool leftResult = evaluateMissionFormulaTree(node.leftNode);
            bool rightResult = evaluateMissionFormulaTree(node.rightNode);
            if (node.operatorType == DQuestStructLib.OperatorType.AND) {
                return leftResult && rightResult;
            } else {
                return leftResult || rightResult;
            }
        }
    }

    function validateQuest() external override onlyQuester whenNotPaused returns (bool) {
        bool result = evaluateMissionFormulaTree(formulaRootNodeId);
        if (result == true) {
            questerProgresses[msg.sender] = QuesterProgress.Completed;
        }
        return result;
    }

    function validateMission(uint256 missionNodeId) public override onlyQuester whenNotPaused returns (bool) {
        DQuestStructLib.MissionNode memory node = missionNodeFormulas._getNode(missionNodeId);
        require(node.isMission == true, "Not a mission");
        bool cache = questerMissionsDone[msg.sender][missionNodeId];
        // if false, proceed validation at mission handler contract
        if (cache == false) {
            IMission mission = IMission(node.missionHandlerAddress);
            // subsequent call at this trigger will update back the cache
            return mission.validateMission(msg.sender, node);
        }
        return cache;
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
    function setOutcomes(DQuestStructLib.Outcome[] calldata _outcomes) public override onlyOwner whenInactive {
        require(_outcomes.length > 0, "No outcome provided");
        
        for (uint256 i = 0; i < _outcomes.length; i++) {
            if (_outcomes[i].isNative) {
                require(_outcomes[i].nativeAmount > 0, "Insufficient native reward amount");
            } else {
            require(_outcomes[i].tokenAddress != address(0), "Outcome address is invalid");
            require(_outcomes[i].functionSelector != 0, "functionSelector can't be empty");
            require(
                keccak256(abi.encodePacked(_outcomes[i].data)) != keccak256(abi.encodePacked("")),
                "outcomeData can't be empty"
            );
            if (_outcomes[i].isLimitedReward) {
                require(_outcomes[i].totalReward > 0, "Insufficient token reward amount");
            }}
        }
        outcomes._set(_outcomes);
        isRewardAvailable = true;

        emit OutcomeSet(_outcomes);
    }

    // check if quest has sufficient reward amount for Quester to claim
    function _checkSufficientReward() private {
        for (uint i = 0; i < outcomes._length(); i++)
        {
            DQuestStructLib.Outcome memory outcome = outcomes._getOutcome(i);
            if (outcome.isLimitedReward == false) {
                isRewardAvailable = true;
                break;
            }
            else if (outcome.isLimitedReward && outcome.totalReward > 0)
            {
                isRewardAvailable = true;
                break;
            }
            else {
                isRewardAvailable = false;
            }
        }
    }

    /**
    * @dev Executes the quest outcome for the specified quester.
    * Only the quest can call this function when the quest is active.
    * @param _quester The address of the quester whose outcome to execute.
    */
    function executeQuestOutcome(address _quester) external override whenActive nonReentrant {
        require(questerProgresses[_quester] == QuesterProgress.Completed, "Quester hasn't completed the Quest");
        require(isRewardAvailable, "The Quest's run out of Reward");
           for (uint256 i = 0; i < outcomes._length(); i++) {
            DQuestStructLib.Outcome memory outcome = outcomes._getOutcome(i);
            if (outcome.isNative) {
                outcome.totalReward = _executeNativeOutcome(_quester, outcome);
                outcomes._replace(i, outcome);
            }
            // If one of the Outcome has run out of Reward
            if (outcome.isLimitedReward && outcome.totalReward == 0)
            {
                continue;
            } 
            if (outcome.functionSelector == SELECTOR_TRANSFERFROM) {
                outcome.totalReward = _executeERC20Outcome(_quester, outcome);
                outcomes._replace(i, outcome); 
            }
            if (outcome.functionSelector == SELECTOR_SAFETRANSFERFROM) {
                (outcome.data, outcome.totalReward) = _executeERC721Outcome(_quester, outcome);
                outcomes._replace(i, outcome);
            }
            if (outcome.functionSelector == SELECTOR_SBTMINT) {
                _executeSBTOutcome(_quester, outcome);
            }
            if (outcome.functionSelector == SELECTOR_NFTSTANDARDMINT) {
                _executeNFTStandardOutcome(_quester, outcome);
            }
        }
        _checkSufficientReward();
        questerProgresses[_quester] = QuesterProgress.Rewarded;
        emit OutcomeExecuted(_quester);  
    }

    function _executeERC20Outcome(address _quester, DQuestStructLib.Outcome memory outcome)
        internal
        returns(uint256 totalRewardLeft)
    {
        address spender;
        uint256 value;
        bytes memory data = outcome.data;

        assembly {
            spender := mload(add(data, 36))
            value := mload(add(data, 100))
        }

        (bool success, bytes memory response) = outcome.tokenAddress.call(
            abi.encodeWithSelector(SELECTOR_TRANSFERFROM, spender, _quester, value)
        );

        require(success, string(response));

        uint256 _totalRewardLeft = outcome.totalReward - value;
        return _totalRewardLeft;
    }

    /**
    * @dev Executes the ERC721Outcome for the specified quester.
    * It's currently implemented with 
    * Admin: setApprovalForAll from Admin's balance
    * tokenId: sequential tokenId with 1st tokenId passing to Outcome.data
    * @param _quester The address of the quester whose outcome to execute.
    * @return newData for Outcome Struct 
    */
    function _executeERC721Outcome(address _quester, DQuestStructLib.Outcome memory outcome)
        internal
        returns (bytes memory newData, uint256 totalRewardLeft)
    {
        address spender;
        uint256 tokenId;
        bytes memory data = outcome.data;

        assembly {
            spender := mload(add(data, 36))
            tokenId := mload(add(data, 100))
        }

        (bool success, bytes memory response) = outcome.tokenAddress.call(
            abi.encodeWithSelector(SELECTOR_SAFETRANSFERFROM, spender, _quester, tokenId)
        );
        require(success, string(response));

        tokenId++;
        uint256 _totalRewardLeft = outcome.totalReward - 1;
        bytes memory _newData = abi.encodeWithSelector(SELECTOR_SAFETRANSFERFROM, spender, _quester, tokenId);

        return (_newData, _totalRewardLeft);
    }

    function _executeNFTStandardOutcome(address _quester, DQuestStructLib.Outcome memory outcome)
        internal
    {
        bytes memory data = outcome.data;
        uint256 mintingConditionId;
        uint256 amount;
        address[] memory quester = new address[](1);
        uint256[] memory clientIds;
        bytes32[] memory merkleRoot = new bytes32[](1);

        quester[0] = _quester;
        merkleRoot[0] = 0x0000000000000000000000000000000000000000000000000000000000000000;

        assembly {
            mintingConditionId := mload(add(data, 164))
            amount := mload(add(data, 228))
        }

        (bool success, bytes memory response) = outcome.tokenAddress.call(
            abi.encodeWithSelector(
                SELECTOR_NFTSTANDARDMINT,
                mintingConditionId,
                quester,
                amount,
                clientIds,
                merkleRoot
            )
        );
        
        require(success, string(response));
    }

    function _executeSBTOutcome(address _quester, DQuestStructLib.Outcome memory outcome)
        internal
    {
        bytes memory data = outcome.data;   
        uint256 expiration;
        address[] memory quester = new address[](1);
        quester[0] = _quester;

        assembly {
            expiration := mload(add(data, 196))
        }

        (bool success, bytes memory response) = outcome.tokenAddress.call(
            abi.encodeWithSelector(SELECTOR_SBTMINT, quester, expiration)
        );

        require(success, string(response));
    }

    function _executeNativeOutcome(address _quester, DQuestStructLib.Outcome memory outcome)
        internal
        returns(uint256 totalRewardLeft)
    {
        (bool success, bytes memory response) = payable(_quester).call{value: outcome.nativeAmount}("");
        require(success, string(response));

        uint256 _totalRewardLeft = outcome.totalReward - outcome.nativeAmount;
        return _totalRewardLeft;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // validate mission formula input
    function validateFormulaInput(DQuestStructLib.MissionNode[] memory nodes) private {
        require(nodes.length > 0, "formula input empty");
        // Check for repeated IDs
        for (uint256 i = 0; i < nodes.length; i++) {
            // validate for mission node (operator nodes don't need this)
            if(nodes[i].isMission == true) {
                if(nodes[i].missionHandlerAddress == address(0x0))
                    revert("handler address 0x0");
                if(nodes[i].oracleAddress == address(0x0))
                    revert("oracle address 0x0");
                if((nodes[i].leftNode | nodes[i].rightNode) != 0)
                    revert("leaf node left and right must be 0");
                if(nodes[i].data.length == 0)
                    revert("empty data");
            }
            for (uint256 j = i + 1; j < nodes.length; j++) {
                if (nodes[i].id == nodes[j].id) {
                    revert("MF1");
                }
            }
        }

        // Validate and find root node
        uint256 rootId = findRoot(nodes);

        //TODO Check for loops/cycles
        if(hasCycle(nodes, rootId))
            revert("mission formula has cycles/loops");

        formulaRootNodeId = rootId;
    }

    // detect Cycle in a directed binary tree
    function hasCycle(DQuestStructLib.MissionNode[] memory nodes, uint256 rootNodeId) private returns(bool) {
        bool[] memory visited = new bool[](nodes.length);
        id2itr1._setIterators(nodes);
        return hasCycleUtil(nodes, visited, rootNodeId);
    }

    // cycle detection helper
    function hasCycleUtil(
        DQuestStructLib.MissionNode[] memory nodes,
        bool[] memory visited,
        uint256 id
    ) private returns (bool) {
        DQuestStructLib.MissionNode memory node = nodes[id2itr1._getIterator(id)];
        visited[id2itr1._getIterator(id)] = true;
        if (node.leftNode != 0) {
            if (visited[id2itr1._getIterator(node.leftNode)]) {
                return true;
            }
            if (hasCycleUtil(nodes, visited, node.leftNode)) {
                return true;
            }
        }
        if (node.rightNode != 0) {
            if (visited[id2itr1._getIterator(node.rightNode)]) {
                return true;
            }
            if (hasCycleUtil(nodes, visited, node.rightNode)) {
                return true;
            }
        }
        return false;
    }

    // support find root node of a binary tree
    function findRoot(DQuestStructLib.MissionNode[] memory tree) private returns (uint256) {
        uint256 n = tree.length;
        id2itr2._setIterators(tree);
        bool[] memory isChild = new bool[](n);

        for (uint256 i = 0; i < n; i++) {
            if (tree[i].leftNode != 0) {
                isChild[id2itr2._getIterator(tree[i].leftNode)] = true;
            }
            if (tree[i].rightNode != 0) {
                isChild[id2itr2._getIterator(tree[i].rightNode)] = true;
            }
        }

        uint256 rootNode = 0;
        uint256 rootCount = 0;
        for (uint256 i = 0; i < n; i++) {
            if (!isChild[i]) {
                rootCount++;
                rootNode = tree[i].id;
                if (rootCount > 1)
                    revert("tree contains more than one root node");
            }
        }

        // there's no node that's referenced by nothing(the root node)
        if (rootCount == 0)
            revert("no root found");

        return rootNode;
    }

    function erc721SetTokenUsed(uint256 missionNodeId, address addr, uint256 tokenId) external override {
        DQuestStructLib.MissionNode memory node = missionNodeFormulas._getNode(missionNodeId);
        require(msg.sender == node.missionHandlerAddress, "Can not update cross-mission states");
        tokenUsed[addr][tokenId] = true;
    }

    function erc721GetTokenUsed(address addr, uint256 tokenId) external view override returns(bool) {
        return tokenUsed[addr][tokenId];
    }
}
