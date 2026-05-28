// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {LionLedger} from "../src/LionLedger.sol";
import {LionEvolutionOracle} from "../src/LionEvolutionOracle.sol";
import {LionRenderer} from "../src/LionRenderer.sol";
import {LionArt} from "../src/LionArt.sol";
import {LionSubscription} from "../src/LionSubscription.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Full deployment script for Base. Run with:
///   forge script script/Deploy.s.sol --rpc-url base --broadcast --verify
///
/// Env vars expected:
///   DEPLOYER_PRIVATE_KEY
///   OPERATOR_ADDRESS         — LazyLionAgents backend wallet
///   ORACLE_SIGNER_ADDRESS    — wallet whose sig adapter8004 trusts
///   PLATFORM_RECIPIENT       — platform fee recipient (5%)
///   TREASURY_RECIPIENT       — treasury fee recipient (5%)
///   USDC_ADDRESS             — Base USDC (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)
contract Deploy is Script {
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address oracleSigner = vm.envAddress("ORACLE_SIGNER_ADDRESS");
        address platformRecipient = vm.envAddress("PLATFORM_RECIPIENT");
        address treasuryRecipient = vm.envAddress("TREASURY_RECIPIENT");
        address usdc = vm.envOr("USDC_ADDRESS", USDC_BASE);
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        LionLedger ledger = new LionLedger(deployer, operator);
        console2.log("LionLedger:", address(ledger));

        LionEvolutionOracle oracle = new LionEvolutionOracle(
            deployer, ledger, oracleSigner
        );
        console2.log("LionEvolutionOracle:", address(oracle));

        LionRenderer renderer = new LionRenderer();
        console2.log("LionRenderer:", address(renderer));

        LionArt art = new LionArt(deployer, renderer, ledger, operator);
        console2.log("LionArt:", address(art));

        LionSubscription subs = new LionSubscription(
            deployer,
            IERC20(usdc),
            platformRecipient,
            treasuryRecipient,
            operator,
            ledger
        );
        console2.log("LionSubscription:", address(subs));

        // Authorize LionArt + LionSubscription to write to the ledger
        ledger.setOperator(address(art), true);
        ledger.setOperator(address(subs), true);

        vm.stopBroadcast();
    }
}
