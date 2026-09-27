// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Permissionless creation of curated quadratic funding rounds denominated in MTCH.
/// @dev Use the fixed-supply LaunchToken. There is no identity or Sybil resistance.
contract QuadraticFunding is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_DURATION = 1 days;
    uint256 public constant MAX_DURATION = 30 days;
    uint256 public constant MAX_PROJECTS = 50;
    uint256 public constant MIN_CONTRIBUTION = 1 ether; // 1 MTCH (18 decimals), never native ETH.
    uint256 public constant MAX_ROUND_DEPOSITS = 1_000_000_000 * 10 ** 18;

    IERC20 public immutable token;
    uint256 public roundCount;

    struct Round {
        address creator;
        uint256 start;
        uint256 end;
        uint256 pool;
        uint256 projectCount;
        uint256 totalContributions;
        bool finalized;
        bool refundable;
    }

    struct Project {
        address payout;
        uint256 contributions;
        uint256 sumSqrt;
        uint256 matchAmount;
        bool claimed;
    }

    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => mapping(uint256 => Project)) private _projects;
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) private _contributions;
    /// @notice Funding deposited by each funder; cleared when reclaimed in a zero-weight round.
    mapping(uint256 => mapping(address => uint256)) public fundingOf;

    error InvalidToken();
    error InvalidSchedule();
    error InvalidRound();
    error InvalidProject();
    error RoundEnded();
    error OutsideContributionWindow();
    error RoundStillOpen();
    error OnlyCreator();
    error InvalidPayout();
    error ProjectLimit();
    error InvalidAmount();
    error DepositLimit();
    error UnexpectedTransferAmount();
    error AlreadyFinalized();
    error NotFinalized();
    error OnlyPayout();
    error AlreadyClaimed();
    error NotRefundable();
    error NothingToReclaim();

    event RoundCreated(uint256 indexed roundId, address indexed creator, uint256 start, uint256 end);
    event Funded(uint256 indexed roundId, address indexed funder, uint256 amount);
    event Registered(uint256 indexed roundId, uint256 indexed projectId, address indexed payout);
    event Contributed(
        uint256 indexed roundId,
        uint256 indexed projectId,
        address indexed contributor,
        uint256 amount,
        uint256 contributorTotal
    );
    event Finalized(uint256 indexed roundId, uint256 pool, uint256 totalWeight, bool refundable);
    event Claimed(uint256 indexed roundId, uint256 indexed projectId, address indexed payout, uint256 amount);
    event Reclaimed(uint256 indexed roundId, address indexed funder, uint256 amount);

    /// @param token_ The LaunchToken deployed for this project (factory argument: $token).
    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
    }

    /// @return roundId Zero-based round identifier.
    function createRound(uint256 start, uint256 end) external nonReentrant returns (uint256 roundId) {
        if (start < block.timestamp || end <= start) revert InvalidSchedule();
        uint256 duration = end - start;
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidSchedule();
        roundId = roundCount++;
        _rounds[roundId] = Round(msg.sender, start, end, 0, 0, 0, false, false);
        emit RoundCreated(roundId, msg.sender, start, end);
    }

    /// @notice Add matching funds, including before the round starts. Positive base-unit amounts are allowed.
    function fund(uint256 roundId, uint256 amount) external nonReentrant {
        Round storage r = _getRound(roundId);
        if (block.timestamp >= r.end) revert RoundEnded();
        if (amount == 0) revert InvalidAmount();
        _checkDeposit(r, amount);
        r.pool += amount;
        fundingOf[roundId][msg.sender] += amount;
        _pullExact(amount);
        emit Funded(roundId, msg.sender, amount);
    }

    /// @notice Only the creator curates projects. Registration remains open until end.
    function register(uint256 roundId, address payout) external nonReentrant returns (uint256 projectId) {
        Round storage r = _getRound(roundId);
        if (msg.sender != r.creator) revert OnlyCreator();
        if (block.timestamp >= r.end) revert RoundEnded();
        if (payout == address(0)) revert InvalidPayout();
        if (r.projectCount >= MAX_PROJECTS) revert ProjectLimit();
        projectId = r.projectCount++;
        _projects[roundId][projectId].payout = payout;
        emit Registered(roundId, projectId, payout);
    }

    /// @notice Every payment is at least one MTCH; repeated payments accumulate per contributor/project.
    function contribute(uint256 roundId, uint256 projectId, uint256 amount) external nonReentrant {
        Round storage r = _getRound(roundId);
        Project storage p = _getProject(roundId, r, projectId);
        if (block.timestamp < r.start || block.timestamp >= r.end) revert OutsideContributionWindow();
        if (amount < MIN_CONTRIBUTION) revert InvalidAmount();
        _checkDeposit(r, amount);
        uint256 previous = _contributions[roundId][projectId][msg.sender];
        uint256 updated = previous + amount;
        _contributions[roundId][projectId][msg.sender] = updated;
        p.sumSqrt += Math.sqrt(updated) - Math.sqrt(previous);
        p.contributions += amount;
        r.totalContributions += amount;
        _pullExact(amount);
        emit Contributed(roundId, projectId, msg.sender, amount, updated);
    }

    /// @notice Permissionless settlement at/after end; makes no external token calls.
    function finalize(uint256 roundId) external nonReentrant {
        Round storage r = _getRound(roundId);
        if (r.finalized) revert AlreadyFinalized();
        if (block.timestamp < r.end) revert RoundStillOpen();
        (uint256[] memory amounts, uint256 totalWeight) = _matchingAmounts(roundId, r);
        r.finalized = true;
        r.refundable = totalWeight == 0;
        for (uint256 i; i < amounts.length; ++i) {
            _projects[roundId][i].matchAmount = amounts[i];
        }
        emit Finalized(roundId, r.pool, totalWeight, r.refundable);
    }

    /// @notice The configured payout address collects its project's entire entitlement once.
    function claim(uint256 roundId, uint256 projectId) external nonReentrant {
        Round storage r = _getRound(roundId);
        Project storage p = _getProject(roundId, r, projectId);
        if (!r.finalized) revert NotFinalized();
        if (msg.sender != p.payout) revert OnlyPayout();
        if (p.claimed) revert AlreadyClaimed();
        p.claimed = true;
        uint256 amount = p.contributions + p.matchAmount;
        if (amount != 0) token.safeTransfer(msg.sender, amount);
        emit Claimed(roundId, projectId, msg.sender, amount);
    }

    /// @notice Each funder can reclaim its own deposits only when the finalized round had no contributions.
    function reclaim(uint256 roundId) external nonReentrant {
        Round storage r = _getRound(roundId);
        if (!r.finalized) revert NotFinalized();
        if (!r.refundable) revert NotRefundable();
        uint256 amount = fundingOf[roundId][msg.sender];
        if (amount == 0) revert NothingToReclaim();
        fundingOf[roundId][msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Reclaimed(roundId, msg.sender, amount);
    }

    function round(uint256 roundId) external view returns (Round memory) {
        return _getRound(roundId);
    }

    function project(uint256 roundId, uint256 projectId) external view returns (Project memory) {
        return _getProject(roundId, _getRound(roundId), projectId);
    }

    function contributionOf(uint256 roundId, uint256 projectId, address account) external view returns (uint256) {
        _getProject(roundId, _getRound(roundId), projectId);
        return _contributions[roundId][projectId][account];
    }

    /// @notice Includes current rounding dust; estimates change with later funding, contributions and projects.
    /// @dev After finalization returns the immutable allocation, including after it is claimed.
    function estimateMatch(uint256 roundId, uint256 projectId) external view returns (uint256) {
        Round storage r = _getRound(roundId);
        Project storage p = _getProject(roundId, r, projectId);
        if (r.finalized) return p.matchAmount;
        (uint256[] memory amounts,) = _matchingAmounts(roundId, r);
        return amounts[projectId];
    }

    function _getRound(uint256 roundId) private view returns (Round storage r) {
        if (roundId >= roundCount) revert InvalidRound();
        return _rounds[roundId];
    }

    function _getProject(uint256 roundId, Round storage r, uint256 projectId) private view returns (Project storage p) {
        if (projectId >= r.projectCount) revert InvalidProject();
        return _projects[roundId][projectId];
    }

    function _checkDeposit(Round storage r, uint256 amount) private view {
        // Naturally enforced by MTCH's supply, made explicit to bound arithmetic even with a different token.
        if (amount > MAX_ROUND_DEPOSITS - r.pool - r.totalContributions) revert DepositLimit();
    }

    function _pullExact(uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert UnexpectedTransferAmount();
    }

    function _matchingAmounts(uint256 roundId, Round storage r)
        private
        view
        returns (uint256[] memory amounts, uint256 totalWeight)
    {
        amounts = new uint256[](r.projectCount);
        uint256 largest;
        uint256 largestWeight;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 sum = _projects[roundId][i].sumSqrt;
            // Each contributor total >= 1e18, so sqrt(total) <= total/1e9.
            // Deposits <= 1e27 bound sum <= 1e18 and the sum of all weights <= 1e36.
            uint256 weight = sum * sum;
            amounts[i] = weight;
            totalWeight += weight;
            if (weight > largestWeight) {
                largestWeight = weight;
                largest = i; // Strict comparison preserves the lowest id on ties.
            }
        }
        if (totalWeight == 0) return (amounts, 0);
        uint256 allocated;
        for (uint256 i; i < amounts.length; ++i) {
            amounts[i] = Math.mulDiv(r.pool, amounts[i], totalWeight);
            allocated += amounts[i];
        }
        amounts[largest] += r.pool - allocated;
    }
}
