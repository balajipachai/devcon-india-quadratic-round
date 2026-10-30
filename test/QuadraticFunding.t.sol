// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {QuadraticFunding} from "../src/QuadraticFunding.sol";

/// @dev Sorted-pair Merkle tree matching OpenZeppelin's MerkleProof. An unpaired node is promoted.
library TestMerkle {
    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i = 0; i < next.length; i++) {
                next[i] = (2 * i + 1 < level.length) ? _pair(level[2 * i], level[2 * i + 1]) : level[2 * i];
            }
            level = next;
        }
        return level[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](32);
        uint256 n;
        bytes32[] memory level = leaves;
        uint256 idx = index;
        while (level.length > 1) {
            uint256 sib = idx ^ 1;
            if (sib < level.length) out[n++] = level[sib];
            bytes32[] memory next = new bytes32[]((level.length + 1) / 2);
            for (uint256 i = 0; i < next.length; i++) {
                next[i] = (2 * i + 1 < level.length) ? _pair(level[2 * i], level[2 * i + 1]) : level[2 * i];
            }
            level = next;
            idx /= 2;
        }
        assembly {
            mstore(out, n)
        }
    }
}

contract ReentrantRecipient {
    QuadraticFunding public round;
    uint256 public projectId;
    uint256 public attempts;
    bool public reenterSucceeded;

    function setTarget(QuadraticFunding round_, uint256 projectId_) external {
        round = round_;
        projectId = projectId_;
    }

    receive() external payable {
        attempts++;
        if (attempts < 3) {
            try round.withdraw(projectId) {
                reenterSucceeded = true;
            } catch {}
        }
    }
}

contract QuadraticFundingTest is Test {
    using TestMerkle for bytes32[];

    uint256 internal constant MEMBERS = 14; // m0..m12 are ordinary members, m13 is the whale
    QuadraticFunding internal round;

    address internal operator = makeAddr("operator");
    address internal sponsor = makeAddr("sponsor");
    address internal outsider = makeAddr("outsider");
    address[] internal members;
    bytes32[] internal leaves;
    bytes32 internal root;

    address internal guwahati = makeAddr("guwahati-club");
    address internal marathi = makeAddr("marathi-videos");
    address internal kit = makeAddr("meetup-kit");

    uint256 internal start;
    uint256 internal end;

    function setUp() public {
        for (uint256 i = 0; i < MEMBERS; i++) {
            members.push(makeAddr(string.concat("member", vm.toString(i))));
            vm.deal(members[i], 1000 ether);
        }
        vm.deal(sponsor, 1000 ether);
        vm.deal(outsider, 1000 ether);

        start = block.timestamp + 1 days;
        end = start + 7 days;
        round = _deploy(start, end);
        _registerAll(round);
    }

    // ---------------------------------------------------------------- helpers

    function _leafFor(QuadraticFunding r, address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(address(r), a))));
    }

    /// @dev The root depends on the contract address, so predict it before deploying.
    function _deploy(uint256 s, uint256 e) internal returns (QuadraticFunding r) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        delete leaves;
        for (uint256 i = 0; i < members.length; i++) {
            leaves.push(keccak256(bytes.concat(keccak256(abi.encode(predicted, members[i])))));
        }
        root = TestMerkle.root(leaves);
        r = new QuadraticFunding(operator, root, s, e);
        assertEq(address(r), predicted);
    }

    function _registerAll(QuadraticFunding r) internal {
        vm.startPrank(operator);
        r.registerProject(guwahati, "Student Ethereum club, Guwahati");
        r.registerProject(marathi, "Marathi Solidity video series");
        r.registerProject(kit, "Meetup kit for tier-3 cities");
        vm.stopPrank();
    }

    function _proof(uint256 memberIndex) internal view returns (bytes32[] memory) {
        return TestMerkle.proof(leaves, memberIndex);
    }

    function _give(uint256 memberIndex, uint256 projectId, uint256 amount) internal {
        bytes32[] memory p = _proof(memberIndex);
        vm.prank(members[memberIndex]);
        round.contribute{value: amount}(projectId, p);
    }

    function _open() internal {
        vm.warp(start);
    }

    function _close() internal {
        vm.warp(end + 1);
    }

    // ---------------------------------------------------------------- rubric 1: (sum of square roots)^2

    /// Hand-worked: 4 members x 1 ETH. Each root is 1, so the sum is 4 and the score is 16 ETH.
    /// 4 ETH of that is their own money, so 12 ETH is the breadth bonus the pool is split by.
    function test_rubric1_scoreIsSquareOfSummedRoots_handWorked() public {
        _open();
        for (uint256 i = 0; i < 4; i++) _give(i, 0, 1 ether);

        assertEq(round.quadraticScore(0), 16 ether);
        assertEq(round.matchWeight(0), 12 ether);
        assertEq(round.getProject(0).raised, 4 ether);
        assertEq(round.getProject(0).contributors, 4);
    }

    /// Unequal cheques: roots of 4 ETH, 1 ETH, 0.25 ETH are 2, 1, 0.5 -> sum 3.5 -> score 12.25 ETH.
    function test_rubric1_unequalContributionsHandWorked() public {
        _open();
        _give(0, 0, 4 ether);
        _give(1, 0, 1 ether);
        _give(2, 0, 0.25 ether);

        assertEq(round.quadraticScore(0), 12.25 ether);
        assertEq(round.matchWeight(0), 12.25 ether - 5.25 ether);
    }

    /// The trap: a square root per transaction. One member splitting 1 ETH into 100 x 0.01 ETH must score
    /// exactly like one 1 ETH cheque, not 100x more.
    function test_rubric1_splittingOneChequeBuysNothing() public {
        _open();
        for (uint256 i = 0; i < 100; i++) _give(0, 0, 0.01 ether);
        _give(1, 1, 1 ether);

        assertEq(round.contributionOf(0, members[0]), 1 ether);
        assertEq(round.quadraticScore(0), round.quadraticScore(1), "split cheque must equal one cheque");
        assertEq(round.quadraticScore(0), 1 ether);
        assertEq(round.matchWeight(0), 0, "one contributor earns no breadth bonus");
        assertEq(round.getProject(0).contributors, 1);
    }

    // ---------------------------------------------------------------- rubric 2: scaled to the pool

    /// Pool 84 ETH. Project 0: 4 x 1 ETH (weight 12). Project 1: 9 x 1 ETH (score 81, weight 72).
    /// Weights sum to 84, so matches are exactly 12 and 72.
    function test_rubric2_matchesScaledToPool_handWorked() public {
        vm.prank(sponsor);
        round.fundPool{value: 84 ether}();
        _open();
        for (uint256 i = 0; i < 4; i++) _give(i, 0, 1 ether);
        for (uint256 i = 0; i < 9; i++) _give(i, 1, 1 ether);
        _close();
        round.finalize();

        assertEq(round.getProject(0).matchAmount, 12 ether);
        assertEq(round.getProject(1).matchAmount, 72 ether);
        assertEq(round.totalMatched(), 84 ether);
        assertEq(round.unallocated(), 0);
    }

    function test_rubric2_matchesNeverExceedPool_andRemainderStaysVisible() public {
        vm.prank(sponsor);
        round.fundPool{value: 84 ether + 1}();
        _open();
        for (uint256 i = 0; i < 4; i++) _give(i, 0, 1 ether);
        for (uint256 i = 0; i < 9; i++) _give(i, 1, 1 ether);
        _close();
        round.finalize();

        assertLe(round.totalMatched(), round.matchingPool());
        assertEq(round.unallocated(), 1, "the 1 wei rounding remainder stays in the pool");
    }

    function testFuzz_rubric2_matchesNeverExceedPool(uint96 pool, uint8 a, uint8 b, uint8 c) public {
        pool = uint96(bound(pool, 1, 500 ether));
        vm.prank(sponsor);
        round.fundPool{value: pool}();
        _open();
        uint256 na = bound(a, 0, 10);
        uint256 nb = bound(b, 0, 10);
        uint256 nc = bound(c, 0, 10);
        for (uint256 i = 0; i < na; i++) _give(i, 0, 1 ether + i * 0.37 ether);
        for (uint256 i = 0; i < nb; i++) _give(i, 1, 0.1 ether + i * 0.01 ether);
        for (uint256 i = 0; i < nc; i++) _give(i, 2, 3 ether);
        _close();
        round.finalize();

        assertLe(round.totalMatched(), pool);
        assertEq(round.unallocated(), pool - round.totalMatched());
    }

    // ---------------------------------------------------------------- rubric 3: eligibility in the contract

    function test_rubric3_ineligibleAddressCannotContribute() public {
        _open();
        bytes32[] memory p = _proof(0); // a real member's proof, used by someone else
        vm.prank(outsider);
        vm.expectRevert(QuadraticFunding.NotEligible.selector);
        round.contribute{value: 1 ether}(0, p);
    }

    function test_rubric3_emptyProofRejected() public {
        _open();
        vm.prank(members[0]);
        vm.expectRevert(QuadraticFunding.NotEligible.selector);
        round.contribute{value: 1 ether}(0, new bytes32[](0));
    }

    function test_rubric3_eligibleMemberCanContribute() public {
        _open();
        _give(5, 0, 1 ether);
        assertEq(round.contributionOf(0, members[5]), 1 ether);
    }

    function test_rubric3_isEligibleView() public view {
        assertTrue(round.isEligible(members[3], _proof(3)));
        assertFalse(round.isEligible(outsider, _proof(3)));
    }

    /// A proof built for another deployment of the contract must not work here (scope is in the leaf).
    function test_rubric3_proofFromAnotherRoundDoesNotReplay() public {
        QuadraticFunding other = _deploy(start, end);
        bytes32[] memory otherProof = _proof(2); // valid for `other`
        vm.warp(start);
        vm.prank(members[2]);
        vm.expectRevert(QuadraticFunding.NotEligible.selector);
        round.contribute{value: 1 ether}(0, otherProof);
        assertTrue(other.isEligible(members[2], otherProof));
    }

    // ---------------------------------------------------------------- rubric 4: withdraw once

    function test_rubric4_projectWithdrawsOnce() public {
        vm.prank(sponsor);
        round.fundPool{value: 84 ether}();
        _open();
        for (uint256 i = 0; i < 4; i++) _give(i, 0, 1 ether);
        for (uint256 i = 0; i < 9; i++) _give(i, 1, 1 ether);
        _close();
        round.finalize();

        uint256 before = guwahati.balance;
        round.withdraw(0);
        assertEq(guwahati.balance, before + 4 ether + 12 ether, "contributions plus match");

        vm.expectRevert(QuadraticFunding.AlreadyWithdrawn.selector);
        round.withdraw(0);
        assertEq(guwahati.balance, before + 16 ether);
    }

    function test_rubric4_reentrancyCannotWithdrawTwice() public {
        ReentrantRecipient evil = new ReentrantRecipient();
        QuadraticFunding r = _deploy(start, end);
        vm.startPrank(operator);
        r.registerProject(address(evil), "evil");
        r.registerProject(marathi, "other");
        vm.stopPrank();
        evil.setTarget(r, 0);

        vm.prank(sponsor);
        r.fundPool{value: 10 ether}();
        vm.warp(start);
        for (uint256 i = 0; i < 4; i++) {
            bytes32[] memory p = TestMerkle.proof(leaves, i);
            vm.prank(members[i]);
            r.contribute{value: 1 ether}(0, p);
        }
        vm.warp(end + 1);
        r.finalize();
        uint256 expected = 4 ether + r.getProject(0).matchAmount;

        r.withdraw(0);

        assertGt(evil.attempts(), 0, "recipient never re-entered");
        assertFalse(evil.reenterSucceeded());
        assertEq(address(evil).balance, expected);
    }

    function test_rubric4_withdrawBeforeFinalizeReverts() public {
        _open();
        _give(0, 0, 1 ether);
        _close();
        vm.expectRevert(QuadraticFunding.NotFinalized.selector);
        round.withdraw(0);
    }

    // ---------------------------------------------------------------- rubric 5: events carry the contributor

    function test_rubric5_contributionEventCarriesContributor() public {
        _open();
        bytes32[] memory p = _proof(4);
        vm.expectEmit(true, true, false, true, address(round));
        emit QuadraticFunding.Contributed(1, members[4], 2 ether);
        vm.prank(members[4]);
        round.contribute{value: 2 ether}(1, p);
    }

    // ---------------------------------------------------------------- rubric 6: finalize only after the round

    function test_rubric6_finalizeRevertsBeforeRoundEnds() public {
        vm.expectRevert(QuadraticFunding.RoundNotEnded.selector);
        round.finalize();

        _open();
        vm.expectRevert(QuadraticFunding.RoundNotEnded.selector);
        round.finalize();

        vm.warp(end);
        vm.expectRevert(QuadraticFunding.RoundNotEnded.selector);
        round.finalize();
    }

    function test_rubric6_finalizeWorksOnceAfterEnd() public {
        _close();
        round.finalize();
        assertTrue(round.finalized());
        vm.expectRevert(QuadraticFunding.AlreadyFinalized.selector);
        round.finalize();
    }

    // ---------------------------------------------------------------- rubric 7: contributions only inside the window

    function test_rubric7_contributeRevertsAfterRoundEnds() public {
        vm.warp(end);
        _give(0, 0, 1 ether); // the last second still counts

        vm.warp(end + 1);
        bytes32[] memory p = _proof(1);
        vm.prank(members[1]);
        vm.expectRevert(QuadraticFunding.RoundEnded.selector);
        round.contribute{value: 1 ether}(0, p);
    }

    function test_rubric7_contributeRevertsBeforeRoundStarts() public {
        bytes32[] memory p = _proof(0);
        vm.prank(members[0]);
        vm.expectRevert(QuadraticFunding.RoundNotStarted.selector);
        round.contribute{value: 1 ether}(0, p);
    }

    // ---------------------------------------------------------------- rubric 8: only the operator registers

    function test_rubric8_onlyOperatorRegistersProjects() public {
        vm.prank(outsider);
        vm.expectRevert(QuadraticFunding.NotOperator.selector);
        round.registerProject(outsider, "mine");

        vm.prank(members[0]);
        vm.expectRevert(QuadraticFunding.NotOperator.selector);
        round.registerProject(members[0], "mine");

        vm.prank(operator);
        round.registerProject(kit, "ok");
        assertEq(round.projectCount(), 4);
    }

    // ---------------------------------------------------------------- brief traps: no committee

    function test_trap_operatorCannotAddProjectOnceRoundStarts() public {
        vm.warp(start);
        vm.prank(operator);
        vm.expectRevert(QuadraticFunding.RegistrationClosed.selector);
        round.registerProject(kit, "late");
    }

    function test_trap_matchingPoolOnlyLeavesViaWithdrawToRecipients() public {
        vm.prank(sponsor);
        round.fundPool{value: 10 ether}();
        _open();
        for (uint256 i = 0; i < 4; i++) _give(i, 0, 1 ether);
        _close();
        round.finalize();

        uint256 operatorBefore = operator.balance;
        vm.prank(operator);
        round.withdraw(0); // operator can trigger it, but money goes to the recipient only
        assertEq(operator.balance, operatorBefore);
        assertEq(guwahati.balance, 4 ether + 10 ether);
    }

    function test_trap_cannotFundPoolAfterRoundEnds() public {
        _close();
        vm.prank(sponsor);
        vm.expectRevert(QuadraticFunding.RoundEnded.selector);
        round.fundPool{value: 1 ether}();
    }

    // ---------------------------------------------------------------- craft: edge cases

    function test_loneWhaleGetsNoMatchButKeepsOwnMoney() public {
        vm.prank(sponsor);
        round.fundPool{value: 12 ether}();
        _open();
        _give(13, 2, 100 ether); // the whale, alone, on project 2
        for (uint256 i = 0; i < 4; i++) _give(i, 0, 1 ether); // four small backers on project 0
        _close();
        round.finalize();

        assertEq(round.getProject(2).matchAmount, 0, "a lone 100 ETH cheque earns no match");
        assertEq(round.getProject(0).matchAmount, 12 ether, "four 1 ETH backers take the whole pool");
        round.withdraw(2);
        assertEq(kit.balance, 100 ether);
    }

    function test_zeroContributionProjectWithdrawsNothingSafely() public {
        vm.prank(sponsor);
        round.fundPool{value: 5 ether}();
        _open();
        for (uint256 i = 0; i < 4; i++) _give(i, 0, 1 ether);
        _close();
        round.finalize();

        uint256 before = marathi.balance;
        round.withdraw(1);
        assertEq(marathi.balance, before);
        assertEq(round.getProject(1).matchAmount, 0);
        assertTrue(round.getProject(1).withdrawn);
    }

    function test_noEligibleBreadthLeavesPoolUnallocated() public {
        vm.prank(sponsor);
        round.fundPool{value: 5 ether}();
        _open();
        _give(0, 0, 1 ether);
        _close();
        round.finalize();
        assertEq(round.totalMatched(), 0);
        assertEq(round.unallocated(), 5 ether);
    }

    function test_noContributionsAtAllFinalizesCleanly() public {
        _close();
        round.finalize();
        assertEq(round.totalMatched(), 0);
    }

    function test_contractBalanceEqualsUnallocatedAfterAllWithdrawals() public {
        vm.prank(sponsor);
        round.fundPool{value: 84 ether + 7}();
        _open();
        for (uint256 i = 0; i < 4; i++) _give(i, 0, 1 ether);
        for (uint256 i = 0; i < 9; i++) _give(i, 1, 1 ether);
        _close();
        round.finalize();
        round.withdraw(0);
        round.withdraw(1);
        round.withdraw(2);
        assertEq(address(round).balance, round.unallocated());
    }

    function test_contributeUnknownProjectAndZeroValueRevert() public {
        _open();
        bytes32[] memory p = _proof(0);
        vm.prank(members[0]);
        vm.expectRevert(QuadraticFunding.UnknownProject.selector);
        round.contribute{value: 1 ether}(99, p);
        vm.prank(members[0]);
        vm.expectRevert(QuadraticFunding.ZeroAmount.selector);
        round.contribute{value: 0}(0, p);
    }

    function test_constructorRejectsBadRounds() public {
        vm.expectRevert(QuadraticFunding.InvalidRound.selector);
        new QuadraticFunding(address(0), root, start, end);
        vm.expectRevert(QuadraticFunding.InvalidRound.selector);
        new QuadraticFunding(operator, bytes32(0), start, end);
        vm.expectRevert(QuadraticFunding.InvalidRound.selector);
        new QuadraticFunding(operator, root, start, start);
        vm.expectRevert(QuadraticFunding.InvalidRound.selector);
        new QuadraticFunding(operator, root, block.timestamp - 1, end);
    }

    function test_maxProjectsEnforced() public {
        vm.startPrank(operator);
        for (uint256 i = round.projectCount(); i < round.MAX_PROJECTS(); i++) {
            round.registerProject(kit, "p");
        }
        vm.expectRevert(QuadraticFunding.TooManyProjects.selector);
        round.registerProject(kit, "one too many");
        vm.stopPrank();
    }
}
