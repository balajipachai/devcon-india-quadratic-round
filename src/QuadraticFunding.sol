// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title QuadraticFunding
/// @notice A single quadratic-funding round for grassroots projects, paid in ETH.
///         Eligible community members contribute during a fixed window; when it closes, each project's
///         match is its quadratic score, scaled so all matches together never exceed the matching pool.
/// @dev Round lifecycle:
///        Registration (now < roundStart): the operator registers projects; anyone may fund the pool.
///        Contribution (roundStart <= now <= roundEnd): eligible members contribute.
///        Closed (now > roundEnd): anyone calls `finalize()` once; then each project withdraws once.
///
///      Anti-gaming properties, all enforced here and not off-chain:
///        - Contributions are aggregated per contributor per project *before* the square root is
///          taken, so splitting one cheque into many transactions buys nothing.
///        - Eligibility is a Merkle root fixed at deployment, so nobody can edit the list after seeing
///          contributions. `contribute` checks the proof against `msg.sender`.
///        - The operator can only register projects, and only before the round starts. There is no
///          function to change a match, change eligibility, add a project mid-round, or withdraw the
///          matching pool.
contract QuadraticFunding is ReentrancyGuard {
    /// @dev Upper bound on projects so `finalize()`, which loops over them, always fits in a block.
    uint256 public constant MAX_PROJECTS = 50;

    /// @dev Fixed-point scale for square roots: we take sqrt(contribution * SCALE) so contributions
    ///      of a few wei-sized units keep precision. Scores are divided back by SCALE.
    uint256 private constant SCALE = 1e18;

    address public immutable operator;
    bytes32 public immutable eligibilityRoot;
    uint256 public immutable roundStart;
    uint256 public immutable roundEnd;

    struct Project {
        address recipient;
        string name;
        uint256 raised; // total ETH contributed to this project
        uint256 contributors; // distinct eligible addresses that contributed
        uint256 sumSqrt; // sum over contributors of sqrt(total contributed * SCALE)
        uint256 matchAmount; // fixed at finalize
        bool withdrawn;
    }

    Project[] private _projects;

    /// @notice What `contributor` has put into `projectId` in total.
    mapping(uint256 projectId => mapping(address contributor => uint256)) public contributionOf;

    uint256 public matchingPool;
    uint256 public totalMatched;
    bool public finalized;

    event ProjectRegistered(uint256 indexed projectId, address indexed recipient, string name);
    event PoolFunded(address indexed funder, uint256 amount);
    event Contributed(uint256 indexed projectId, address indexed contributor, uint256 amount);
    event Finalized(uint256 matchingPool, uint256 totalMatched, uint256 totalMatchWeight);
    event Withdrawn(uint256 indexed projectId, address indexed recipient, uint256 contributions, uint256 matchAmount);

    error InvalidRound();
    error NotOperator();
    error InvalidRecipient();
    error TooManyProjects();
    error RegistrationClosed();
    error UnknownProject();
    error RoundNotStarted();
    error RoundEnded();
    error RoundNotEnded();
    error NotEligible();
    error ZeroAmount();
    error AlreadyFinalized();
    error NotFinalized();
    error AlreadyWithdrawn();
    error TransferFailed();

    constructor(address operator_, bytes32 eligibilityRoot_, uint256 roundStart_, uint256 roundEnd_) {
        // Round windows are measured in days; validator timestamp drift of seconds is acceptable.
        // slither-disable-next-line timestamp
        if (operator_ == address(0) || eligibilityRoot_ == bytes32(0) || roundStart_ < block.timestamp || roundEnd_ <= roundStart_) {
            revert InvalidRound();
        }
        operator = operator_;
        eligibilityRoot = eligibilityRoot_;
        roundStart = roundStart_;
        roundEnd = roundEnd_;
    }

    // ------------------------------------------------------------------ registration & pool

    /// @notice Register a project. Operator only, and only before the round starts.
    function registerProject(address recipient, string calldata name) external returns (uint256 projectId) {
        if (msg.sender != operator) revert NotOperator();
        // Round windows are measured in days; validator timestamp drift of seconds is acceptable.
        // slither-disable-next-line timestamp
        if (block.timestamp >= roundStart) revert RegistrationClosed();
        if (recipient == address(0)) revert InvalidRecipient();
        projectId = _projects.length;
        if (projectId >= MAX_PROJECTS) revert TooManyProjects();

        _projects.push();
        Project storage p = _projects[projectId];
        p.recipient = recipient;
        p.name = name;

        emit ProjectRegistered(projectId, recipient, name);
    }

    /// @notice Add ETH to the matching pool. Open to anyone (the operator, a sponsor) until the round ends.
    ///         There is deliberately no way to take it back out.
    function fundPool() external payable {
        if (msg.value == 0) revert ZeroAmount();
        // Round windows are measured in days; validator timestamp drift of seconds is acceptable.
        // slither-disable-next-line timestamp
        if (block.timestamp > roundEnd) revert RoundEnded();
        matchingPool += msg.value;
        emit PoolFunded(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------ contributions

    /// @notice Whether `account` is on the eligibility list, given its Merkle proof.
    function isEligible(address account, bytes32[] calldata proof) public view returns (bool) {
        return MerkleProof.verifyCalldata(proof, eligibilityRoot, _leaf(account));
    }

    /// @notice Contribute `msg.value` to a project. Reverts unless `msg.sender` is on the eligibility list.
    /// @param proof Merkle proof that `msg.sender` is in `eligibilityRoot`.
    function contribute(uint256 projectId, bytes32[] calldata proof) external payable {
        if (projectId >= _projects.length) revert UnknownProject();
        // Round windows are measured in days; validator timestamp drift of seconds is acceptable.
        // slither-disable-next-line timestamp
        if (block.timestamp < roundStart) revert RoundNotStarted();
        // Round windows are measured in days; validator timestamp drift of seconds is acceptable.
        // slither-disable-next-line timestamp
        if (block.timestamp > roundEnd) revert RoundEnded();
        if (msg.value == 0) revert ZeroAmount();
        if (!MerkleProof.verifyCalldata(proof, eligibilityRoot, _leaf(msg.sender))) revert NotEligible();

        Project storage p = _projects[projectId];
        uint256 before = contributionOf[projectId][msg.sender];
        uint256 total = before + msg.value;
        contributionOf[projectId][msg.sender] = total;

        // The square root is taken of this contributor's *running total* for the project, never of a
        // single transaction. Replacing the old root with the new one keeps `sumSqrt` exactly equal to
        // the sum of each contributor's root, however many transactions they used.
        if (before == 0) p.contributors += 1;
        p.sumSqrt = p.sumSqrt - Math.sqrt(before * SCALE) + Math.sqrt(total * SCALE);
        p.raised += msg.value;

        emit Contributed(projectId, msg.sender, msg.value);
    }

    // ------------------------------------------------------------------ the maths (all public views)

    /// @notice Quadratic score: (sum of square roots of each contributor's total)^2, in wei.
    function quadraticScore(uint256 projectId) public view returns (uint256) {
        if (projectId >= _projects.length) revert UnknownProject();
        uint256 s = _projects[projectId].sumSqrt;
        return Math.mulDiv(s, s, SCALE);
    }

    /// @notice The part of the score that comes from breadth: score minus what was actually contributed.
    ///         One contributor alone gives zero; many contributors give a lot. This is what the pool is split by.
    /// @dev    This is the capital-constrained quadratic-funding rule (Buterin, Hitzig & Weyl): each project is
    ///         matched by its subsidy, and `finalize()` scales every subsidy by `pool / sum of all subsidies`,
    ///         so matches never exceed the pool. With one contributor the subsidy is zero.
    function matchWeight(uint256 projectId) public view returns (uint256) {
        uint256 score = quadraticScore(projectId);
        uint256 raised = _projects[projectId].raised;
        return score > raised ? score - raised : 0;
    }

    /// @notice Sum of every project's match weight.
    function totalMatchWeight() public view returns (uint256 total) {
        uint256 n = _projects.length;
        for (uint256 i = 0; i < n; i++) {
            total += matchWeight(i);
        }
    }

    // ------------------------------------------------------------------ closing the round

    /// @notice Fix every project's match. Anyone can call, once, after the round ends. Each match is
    ///         `matchingPool * matchWeight / totalMatchWeight`, rounded down, so the matches add up to
    ///         at most the pool. Rounding remainders stay in the contract and show in `unallocated()`.
    function finalize() external {
        // Round windows are measured in days; validator timestamp drift of seconds is acceptable.
        // slither-disable-next-line timestamp
        if (block.timestamp <= roundEnd) revert RoundNotEnded();
        if (finalized) revert AlreadyFinalized();
        finalized = true;

        uint256 n = _projects.length;
        uint256 pool = matchingPool;
        uint256 totalWeight = totalMatchWeight();
        uint256 matched = 0;

        if (totalWeight > 0) {
            for (uint256 i = 0; i < n; i++) {
                uint256 m = Math.mulDiv(pool, matchWeight(i), totalWeight);
                _projects[i].matchAmount = m;
                matched += m;
            }
        }
        totalMatched = matched;

        emit Finalized(pool, matched, totalWeight);
    }

    /// @notice Pool left over after matches: rounding dust, or the whole pool if no project had a match weight.
    function unallocated() external view returns (uint256) {
        return matchingPool - totalMatched;
    }

    // ------------------------------------------------------------------ paying out

    /// @notice Pay a project its contributions plus its match, to its registered recipient. Callable once
    ///         per project, by anyone, once the round is finalized. Funds can only ever go to the recipient.
    function withdraw(uint256 projectId) external nonReentrant {
        if (!finalized) revert NotFinalized();
        if (projectId >= _projects.length) revert UnknownProject();
        Project storage p = _projects[projectId];
        if (p.withdrawn) revert AlreadyWithdrawn();

        p.withdrawn = true; // effect before interaction
        uint256 contributions = p.raised;
        uint256 matchAmount = p.matchAmount;
        uint256 amount = contributions + matchAmount;
        address recipient = p.recipient;

        emit Withdrawn(projectId, recipient, contributions, matchAmount);

        if (amount > 0) {
            // .call so a smart-wallet recipient can receive; `withdrawn` is already set and nonReentrant guards.
            // slither-disable-next-line low-level-calls
            (bool ok,) = recipient.call{value: amount}("");
            if (!ok) revert TransferFailed();
        }
    }

    // ------------------------------------------------------------------ views for the results page

    function projectCount() external view returns (uint256) {
        return _projects.length;
    }

    function getProject(uint256 projectId) external view returns (Project memory) {
        if (projectId >= _projects.length) revert UnknownProject();
        return _projects[projectId];
    }

    function _leaf(address account) private view returns (bytes32) {
        // Double hash, with this contract's address in the preimage so a list built for another round
        // (or another deployment) can't be replayed here.
        return keccak256(bytes.concat(keccak256(abi.encode(address(this), account))));
    }
}
