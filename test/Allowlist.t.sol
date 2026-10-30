// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {QuadraticFunding} from "../src/QuadraticFunding.sol";

/// @notice Proves `tools/merkle.mjs` and the contract agree on the leaf format and tree shape, using
///         the tool's real output (tools/fixtures/allowlist.json, built for the contract address below).
contract AllowlistTest is Test {
    function test_toolOutputVerifiesOnChain() public {
        string memory json = vm.readFile("tools/fixtures/allowlist.json");
        address contractAddr = vm.parseJsonAddress(json, ".contract");
        bytes32 root = vm.parseJsonBytes32(json, ".root");

        deployCodeTo(
            "QuadraticFunding.sol:QuadraticFunding",
            abi.encode(makeAddr("operator"), root, block.timestamp + 1 days, block.timestamp + 8 days),
            contractAddr
        );
        QuadraticFunding round = QuadraticFunding(contractAddr);

        string[] memory keys = vm.parseJsonKeys(json, ".proofs");
        assertEq(keys.length, vm.parseJsonUint(json, ".members"));
        for (uint256 i = 0; i < keys.length; i++) {
            bytes32[] memory proof = vm.parseJsonBytes32Array(json, string.concat('.proofs["', keys[i], '"]'));
            assertTrue(round.isEligible(vm.parseAddress(keys[i]), proof), keys[i]);
        }
    }

    function test_toolProofDoesNotWorkForOutsiderOrOtherMember() public {
        string memory json = vm.readFile("tools/fixtures/allowlist.json");
        address contractAddr = vm.parseJsonAddress(json, ".contract");
        deployCodeTo(
            "QuadraticFunding.sol:QuadraticFunding",
            abi.encode(makeAddr("operator"), vm.parseJsonBytes32(json, ".root"), block.timestamp + 1 days, block.timestamp + 8 days),
            contractAddr
        );
        QuadraticFunding round = QuadraticFunding(contractAddr);

        string[] memory keys = vm.parseJsonKeys(json, ".proofs");
        bytes32[] memory first = vm.parseJsonBytes32Array(json, string.concat('.proofs["', keys[0], '"]'));
        assertFalse(round.isEligible(makeAddr("outsider"), first));
        assertFalse(round.isEligible(vm.parseAddress(keys[1]), first));
    }
}
