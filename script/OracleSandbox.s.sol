// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/console2.sol";
import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uma/core/contracts/common/implementation/AddressWhitelist.sol";
import "@uma/core/contracts/common/implementation/TestnetERC20.sol";
import "@uma/core/contracts/data-verification-mechanism/implementation/Constants.sol";
import "@uma/core/contracts/data-verification-mechanism/implementation/Finder.sol";
import "@uma/core/contracts/data-verification-mechanism/implementation/IdentifierWhitelist.sol";
import "@uma/core/contracts/data-verification-mechanism/implementation/Store.sol";
import "@uma/core/contracts/data-verification-mechanism/test/MockOracleAncillary.sol";
import "@uma/core/contracts/optimistic-oracle-v3/implementation/OptimisticOracleV3.sol";

contract OracleSandboxScript is Script {
    // Deployment parameters are set as state variables to avoid stack too deep errors.
    bytes32 defaultIdentifier; // Defaults to ASSERT_TRUTH.
    uint256 minimumBond; // Defaults to 100e18 (finalFee will be set to half of this value).
    uint64 defaultLiveness; // Defaults to 2h.
    address defaultCurrency; // If not set, a new TestnetERC20 will be deployed.
    string defaultCurrencyName; // Defaults to "Default Bond Token", only used if DEFAULT_CURRENCY is not set.
    string defaultCurrencySymbol; // Defaults to "DBT", only used if DEFAULT_CURRENCY is not set.
    uint8 defaultCurrencyDecimals; // Defaults to 18, only used if DEFAULT_CURRENCY is not set.

    function run() external {
        // Get deployment parameters from environment variables or use defaults.
        defaultIdentifier = vm.envOr("DEFAULT_IDENTIFIER", bytes32("ASSERT_TRUTH"));
        minimumBond = vm.envOr("MINIMUM_BOND", uint256(100e18));
        defaultLiveness = uint64(vm.envOr("DEFAULT_LIVENESS", uint64(7200)));
        defaultCurrency = vm.envOr("DEFAULT_CURRENCY", address(0));
        defaultCurrencyName = vm.envOr("DEFAULT_CURRENCY_NAME", string("Default Bond Token"));
        defaultCurrencySymbol = vm.envOr("DEFAULT_CURRENCY_SYMBOL", string("DBT"));
        defaultCurrencyDecimals = uint8(vm.envOr("DEFAULT_CURRENCY_DECIMALS", uint8(18)));

        vm.startBroadcast();

        // Deploy UMA ecosystem contracts with mocked oracle and selected currency.
        Finder finder = new Finder();
        console.log("Deployed Finder at %s", address(finder));
        Store store = new Store(FixedPoint.fromUnscaledUint(0), FixedPoint.fromUnscaledUint(0), address(0));
        console.log("Deployed Store at %s", address(store));
        AddressWhitelist addressWhitelist = new AddressWhitelist();
        console.log("Deployed AddressWhitelist at %s", address(addressWhitelist));
        IdentifierWhitelist identifierWhitelist = new IdentifierWhitelist();
        console.log("Deployed IdentifierWhitelist at %s", address(identifierWhitelist));
        MockOracleAncillary mockOracle = new MockOracleAncillary(address(finder), address(0));
        console.log("Deployed MockOracleAncillary at %s", address(mockOracle));
        if (defaultCurrency == address(0)) {
            defaultCurrency = address(
                new TestnetERC20(defaultCurrencyName, defaultCurrencySymbol, defaultCurrencyDecimals)
            );
            console.log("Deployed TestnetERC20 at %s", defaultCurrency);
        }

        // Register UMA ecosystem contracts, whitelist currency and identifier.
        finder.changeImplementationAddress(OracleInterfaces.Store, address(store));
        finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(addressWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.IdentifierWhitelist, address(identifierWhitelist));
        finder.changeImplementationAddress(OracleInterfaces.Oracle, address(mockOracle));
        addressWhitelist.addToWhitelist(defaultCurrency);
        identifierWhitelist.addSupportedIdentifier(defaultIdentifier);
        store.setFinalFee(defaultCurrency, FixedPoint.Unsigned(minimumBond / 2));

        // Deploy Optimistic Oracle V3 and register it in the Finder.
        OptimisticOracleV3 oo = new OptimisticOracleV3(finder, IERC20(defaultCurrency), defaultLiveness);
        console.log("Deployed Optimistic Oracle V3 at %s", address(oo));
        finder.changeImplementationAddress(OracleInterfaces.OptimisticOracleV3, address(oo));

        vm.stopBroadcast();
    }
}
