// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract veCarvs is Multicall {
    struct Position {
        address user;
        uint256 balance;
        uint256 end;
    }

    struct EpochPoint {
        uint256 bias;
        int256 slope;
        uint32 epochIndex;
    }

    /*---------- event ----------*/
    event Deposit(uint64 indexed positionID, address indexed user, uint256 amount, uint256 begin, uint256 duration);
    event Withdraw(uint64 indexed positionID);

    /*---------- token infos ----------*/
    address public token;
    string public name;
    string public symbol;

    /*---------- Global algorithm parameters ----------*/
    // The contract will define the length of min time period here.
    uint256 public constant DURATION_PER_EPOCH = 1 days;
    // Carv is exchanged for veCarv(s) according to a linear exchange,
    // and veCarv(s) is obtained at a ratio of 1:1 after [stakingFactor] epochs.
    uint256 public constant stakingFactor = 20;
    uint256 public immutable initialTimestamp;
    // epoch -> delta slope
    mapping(uint32 => int256) public slopeChanges;
    // epoch -> point
    EpochPoint[] public epochPoints;

    /*---------- User algorithm parameters ----------*/
    mapping(address => mapping(uint32 => int256)) public userSlopeChanges;
    mapping(address => EpochPoint[]) public userEpochPoints;

    /*---------- User position parameters ----------*/
    uint64 public positionIndex;
    mapping(uint64 => Position) public positions;

    constructor(string memory name_, string memory symbol_, address carvToken) {
        name = name_;
        symbol = symbol_;
        token = carvToken;
        initialTimestamp = (block.timestamp / DURATION_PER_EPOCH) * DURATION_PER_EPOCH;
        epochPoints.push(EpochPoint(0, 0, 0));
    }

    function balanceOf(address user) external view returns (uint256) {
        return balanceOfAt(user, block.timestamp);
    }

    function balanceOfAt(address user, uint256 timestamp) public view returns (uint256) {
        return _biasAt(userEpochPoints[user], userSlopeChanges[user], timestamp);
    }

    function totalSupply() external view returns (uint256) {
        return totalSupplyAt(block.timestamp);
    }

    function totalSupplyAt(uint256 timestamp) public view returns (uint256) {
        return _biasAt(epochPoints, slopeChanges, timestamp);
    }

    function epoch() public view returns (uint32) {
        return epochAt(block.timestamp);
    }

    function epochAt(uint256 timestamp) public view returns (uint32) {
        return uint32((timestamp - initialTimestamp) / DURATION_PER_EPOCH);
    }

    function epochTimestamp(uint32 epochIndex) public view returns (uint256) {
        return epochIndex * DURATION_PER_EPOCH + initialTimestamp;
    }

    function deposit(uint256 amount, uint256 duration) external {
        require(duration % DURATION_PER_EPOCH == 0, "invalid duration");
        require(amount > 0, "invalid amount");
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        uint256 beginTimestamp = (block.timestamp / DURATION_PER_EPOCH) * DURATION_PER_EPOCH;
        positionIndex++;
        positions[positionIndex] = Position(msg.sender, amount, beginTimestamp + duration);

        checkEpoch(msg.sender);
        _updateCurrentPoint(msg.sender, amount, beginTimestamp, duration);

        emit Deposit(positionIndex, msg.sender, amount, beginTimestamp, duration);
    }

    function withdraw(uint64 positionID) external {
        Position storage position = positions[positionID];

        require(position.user == msg.sender, "user not match or already withdrawn");
        require(position.end <= block.timestamp, "locked");

        IERC20(token).transfer(msg.sender, position.balance);
        delete positions[positionID];
        emit Withdraw(positionID);
    }

    function checkEpoch(address withUser) public {
        _checkEpoch(epochPoints, slopeChanges);

        if (withUser != address(0)) {
            if (userEpochPoints[withUser].length == 0) {
                // initialize user array
                userEpochPoints[withUser].push(EpochPoint(0, 0, epoch()));
                return;
            }
            _checkEpoch(userEpochPoints[withUser], userSlopeChanges[withUser]);
        }
    }

    function _biasAt(EpochPoint[] memory epochPoints_, mapping(uint32 => int256) storage slopeChanges_, uint256 timestamp) internal view returns (uint256) {
        EpochPoint memory lastRecordEpochPoint = epochPoints_[epochPoints_.length-1];
        uint32 targetEpoch = epochAt(timestamp);

        if (targetEpoch < lastRecordEpochPoint.epochIndex) {
            for (uint256 epochPointsIndex = epochPoints_.length-2; ; epochPointsIndex--) {
                EpochPoint memory epochPoint = epochPoints_[epochPointsIndex];
                if (targetEpoch >= epochPoint.epochIndex) {
                    return calculate(epochPoint.bias, epochPoint.slope, timestamp - epochTimestamp(epochPoint.epochIndex));
                }
            }
        }

        uint256 tmpBias = lastRecordEpochPoint.bias;
        int256 tmpSlope = lastRecordEpochPoint.slope;
        for (uint32 epochIndex = lastRecordEpochPoint.epochIndex; epochIndex < targetEpoch; epochIndex++) {
            tmpBias = calculate(tmpBias, tmpSlope, DURATION_PER_EPOCH);
            tmpSlope += slopeChanges_[epochIndex+1];
        }
        return calculate(tmpBias, tmpSlope, timestamp - epochTimestamp(targetEpoch));
    }

    function _checkEpoch(EpochPoint[] storage epochPoints_, mapping(uint32 => int256) storage slopeChanges_) internal {
        uint32 currentEpoch = epoch();
        uint32 lastRecordEpoch = epochPoints_[epochPoints_.length-1].epochIndex;

        if (currentEpoch <= lastRecordEpoch) {
            return;
        }

        // From the epoch of the previous Point to the current epoch
        for (uint32 epochIndex = lastRecordEpoch+1; epochIndex <= currentEpoch; epochIndex++) {
            // EpochPoints will be updated only when the slope changes or reaches the current epoch.
            if (slopeChanges_[epochIndex] == 0 && epochIndex < currentEpoch) {
                continue;
            }

            EpochPoint memory lastEpochPoint = epochPoints_[epochPoints_.length-1];
            EpochPoint memory newEpochPoint;
            newEpochPoint.slope = lastEpochPoint.slope + slopeChanges_[epochIndex];
            newEpochPoint.bias = calculate(lastEpochPoint.bias, lastEpochPoint.slope, (epochIndex - lastEpochPoint.epochIndex) * DURATION_PER_EPOCH);
            newEpochPoint.epochIndex = epochIndex;
            epochPoints_.push(newEpochPoint);
        }
    }

    // update slope and bias
    function _updateCurrentPoint(address user, uint256 amount, uint256 beginTimestamp, uint256 duration) internal {
        uint256 initialBias = amount * duration / (stakingFactor * DURATION_PER_EPOCH);
        uint256 slope = initialBias / duration + 1;
        uint32 endEpoch = epochAt(beginTimestamp + duration);

        // update global slope and bias
        slopeChanges[endEpoch] -= int256(slope);
        epochPoints[epochPoints.length-1].slope += int256(slope);
        epochPoints[epochPoints.length-1].bias += initialBias;
        // update user's slope and bias
        userSlopeChanges[user][endEpoch] -= int256(slope);
        userEpochPoints[user][userEpochPoints[user].length-1].slope += int256(slope);
        userEpochPoints[user][userEpochPoints[user].length-1].bias += initialBias;
    }

    function calculate(uint256 bias, int256 slope, uint256 duration) internal pure returns (uint256) {
        if (bias < uint256(slope) * (duration)) {
            return 0;
        }
        return (bias - uint256(slope) * (duration));
    }
}