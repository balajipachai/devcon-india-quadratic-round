// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {QuadraticFunding} from "../src/QuadraticFunding.sol";

/// @notice Deploys a round, registers its projects and funds the matching pool, all in one broadcast.
///         Inputs come from the environment (see `.env.example`); the signer comes from the CLI
///         (`--account <keystore> --sender <address>`), so no key is read from any file.
///         The operator is DEPLOYER, which must be the same address as `--sender`.
contract Deploy is Script {
    function run() external returns (QuadraticFunding round) {
        address operator = vm.envAddress("DEPLOYER");
        bytes32 root = vm.envBytes32("ELIGIBILITY_ROOT");
        uint256 start = block.timestamp + vm.envUint("REGISTRATION_SECONDS");
        uint256 end = start + vm.envUint("ROUND_SECONDS");
        uint256 poolWei = vm.envOr("POOL_WEI", uint256(0));

        address[] memory recipients = vm.envAddress("PROJECT_RECIPIENTS", ",");
        string[] memory names = vm.envString("PROJECT_NAMES", ",");
        require(recipients.length == names.length, "PROJECT_RECIPIENTS and PROJECT_NAMES differ in length");

        vm.startBroadcast(operator);
        round = new QuadraticFunding(operator, root, start, end);
        for (uint256 i = 0; i < recipients.length; i++) {
            round.registerProject(recipients[i], names[i]);
        }
        if (poolWei > 0) round.fundPool{value: poolWei}();
        vm.stopBroadcast();

        console.log("QuadraticFunding deployed at", address(round));
        console.log("round start", start);
        console.log("round end  ", end);
    }
}
