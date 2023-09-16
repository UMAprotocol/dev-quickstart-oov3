// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@uma/core/contracts/optimistic-oracle-v3/implementation/ClaimData.sol";
import "@uma/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract InsuranceTutorial is Ownable{
    using SafeERC20 for IERC20;
    IERC20 public immutable defaultCurrency;
    OptimisticOracleV3Interface public immutable oo;
    uint64 public constant assertionLiveness = 7200;
    bytes32 public immutable defaultIdentifier;

    enum Status {
        UNINIITIALIZED,
        OPEN,
        REQUESTED,
        SETTLED
    }

    struct Policy {
        uint256 insuranceAmount;
        address payoutAddress;
        bytes insuredEvent;
        Status status;
        bytes32 assertionId;
    }

    mapping(bytes32 => bytes32) public assertedPolicies;

    mapping(bytes32 => Policy) public policies;
    // insuredEvent => BPS price per policy amount
    mapping(bytes32 => uint256) public insuredEventPrice;

    uint256 public totalLiabilities;

    event InsuranceIssued(
        bytes32 indexed policyId,
        bytes insuredEvent,
        uint256 insuranceAmount,
        address indexed payoutAddress
    );

    event InsurancePayoutRequested(bytes32 indexed policyId, bytes32 indexed assertionId);

    event InsurancePayoutSettled(bytes32 indexed policyId, bytes32 indexed assertionId);

    event InsuredEventSet(bytes32 indexed insuredEvent, uint256 price);

    constructor(address _defaultCurrency, address _optimisticOracleV3) {
        defaultCurrency = IERC20(_defaultCurrency);
        oo = OptimisticOracleV3Interface(_optimisticOracleV3);
        defaultIdentifier = oo.defaultIdentifier();
    }

    function createPolicy(
        uint256 insuranceAmount,
        address payoutAddress,
        bytes memory insuredEvent
    ) public returns (bytes32 policyId) {
        require(insuredEventPrice[insuredEvent] > 0, "insuredEvent invalid");
        require(insuranceAmount <= defaultCurrency.balanceOf(address(this)) - totalLiabilities, "insuranceAmount not available");
        policyId = keccak256(abi.encode(insuredEvent, payoutAddress));
        require(policies[policyId].payoutAddress == address(0), "Policy already exists");
        policies[policyId] = Policy({
            insuranceAmount: insuranceAmount,
            payoutAddress: payoutAddress,
            insuredEvent: insuredEvent,
            status: Status.OPEN,
            assertionId : ''
        });
        defaultCurrency.safeTransferFrom(msg.sender, address(this), insuranceAmount * insuredEventPrice[insuredEvent] / 10000 );
        emit InsuranceIssued(policyId, insuredEvent, insuranceAmount, payoutAddress);
    }

    function requestPayout(bytes32 policyId) public returns (bytes32 assertionId) {
        Policy storage policy = policies[policyId];
        require(policy.payoutAddress != address(0), "Policy does not exist");
        require(policy.status == Status.OPEN, "Policy is not currently OPEN");
        uint256 bond = oo.getMinimumBond(address(defaultCurrency));
        defaultCurrency.safeTransferFrom(msg.sender, address(this), bond);
        defaultCurrency.safeApprove(address(oo), bond);
        assertionId = oo.assertTruth(
            abi.encodePacked(
                "Insurance contract is claiming that insurance event ",
                policy.insuredEvent,
                " had occurred as of ",
                ClaimData.toUtf8BytesUint(block.timestamp),
                "."
            ),
            msg.sender,
            address(this),
            address(0), // No sovereign security.
            assertionLiveness,
            defaultCurrency,
            bond,
            defaultIdentifier,
            bytes32(0) // No domain.
        );
        assertedPolicies[assertionId] = policyId;

        policy.status = Status.REQUESTED;
        policy.assertionId = assertionId;
        emit InsurancePayoutRequested(policyId, assertionId);
    }
    // note: price in BPS, insuredEvents with price = 0 are invalid
    function setInsuredEvent(bytes32 insuredEvent, uint256 price) external onlyOwner {
        insuredEventPrice[insuredEvent] = price;
        emit InsuredEventSet(insuredEvent, price);
    }

    function withdrawFunds(address receiver, uint256 withdrawAmount) external onlyOwner {
        require(withdrawAmount <= defaultCurrency.balanceOf(address(this)) - totalLiabilities, "withdrawAmount not available");
        defaultCurrency.safeTransfer(receiver, withdrawAmount);
    }

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) public {
        require(msg.sender == address(oo));
        
        if (assertedTruthfully) {
            // If the assertion was true, then the policy is settled.
            _settlePayout(assertionId);
        } else {
            // If the assertion was false, then the policy is set back to OPEN.
            bytes32 policyId = assertedPolicies[assertionId];
            Policy storage policy = policies[policyId];
            policy.status = Status.OPEN;
            policy.assertionId = '';
        }
    }

    function assertionDisputedCallback(bytes32 assertionId) public {}

    function _settlePayout(bytes32 assertionId) internal {
        // If already settled, do nothing. We don't revert because this function is called by the
        // OptimisticOracleV3, which may block the assertion resolution.
        bytes32 policyId = assertedPolicies[assertionId];
        Policy storage policy = policies[policyId];
        if (policy.status == Status.SETTLED) return;
        policy.status = Status.SETTLED;
        defaultCurrency.safeTransfer(policy.payoutAddress, policy.insuranceAmount);
        emit InsurancePayoutSettled(policyId, assertionId);
    }
}