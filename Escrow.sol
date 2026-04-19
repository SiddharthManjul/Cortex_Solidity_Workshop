// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Escrow
/// @notice Vault with conditional release. Two parties, no arbiter.
///         The state machine + deadline replaces the trusted third party.
///
///         Vault said: "I trust code to hold my money."
///         Escrow says: "I trust code to hold my money AND decide when
///                       to release it."
///
///         The buyer deploys. The buyer funds. The buyer confirms.
///         If the buyer goes silent, the deadline refunds automatically.
///         The contract IS the arbiter.

contract Escrow {

    // ---------------------------------------------------------------
    // STATE MACHINE
    // ---------------------------------------------------------------

    // This enum defines every possible state the contract can be in.
    // This is a finite state machine (FSM) — the most important
    // pattern in this contract. In the Vault, state was implicit
    // (either the contract has a balance or it doesn't). Here, state
    // is EXPLICIT and NAMED.
    //
    // AWAITING_DEPOSIT      → contract just deployed, waiting for buyer to fund
    // AWAITING_CONFIRMATION → buyer funded, waiting for buyer to confirm receipt
    // COMPLETE              → buyer confirmed, seller got paid (terminal)
    // REFUNDED              → deadline passed, buyer got refund (terminal)
    //
    // COMPLETE and REFUNDED are terminal states. Once you're there,
    // no function can transition out. The contract is done forever.

    enum State {
        AWAITING_DEPOSIT,
        AWAITING_CONFIRMATION,
        COMPLETE,
        REFUNDED
    }

    // ---------------------------------------------------------------
    // STATE VARIABLES
    // ---------------------------------------------------------------

    // Five slots instead of the vault's one.
    // buyer   → the party putting up the money (deployer)
    // seller  → the party providing the goods/service
    // amount  → how much wei was deposited
    // state   → current position in the FSM
    // deadline → unix timestamp after which refund becomes available

    address public buyer;
    address public seller;
    uint256 public amount;
    State   public currentState;
    uint256 public deadline;

    // ---------------------------------------------------------------
    // EVENTS
    // ---------------------------------------------------------------

    event Funded(address indexed buyer, uint256 amount);
    event Confirmed(address indexed buyer);
    event Released(address indexed seller, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);

    // ---------------------------------------------------------------
    // ERRORS
    // ---------------------------------------------------------------

    error NotBuyer();
    error InvalidState(State current, State expected);
    error InvalidSeller();
    error DeadlineInPast();
    error ZeroDeposit();
    error DeadlineNotReached(uint256 current, uint256 deadline);
    error TransferFailed();

    // ---------------------------------------------------------------
    // MODIFIERS
    // ---------------------------------------------------------------

    // Same pattern as the vault's onlyOwner, but scoped to the buyer.
    // The seller has no modifier because the seller never needs to
    // call any function in this contract — they only RECEIVE funds.

    modifier onlyBuyer() {
        if (msg.sender != buyer) revert NotBuyer();
        _;
    }

    // This is the FSM enforcer. It takes a State parameter and checks
    // that the contract is CURRENTLY in that state. If someone tries
    // to call confirmReceived() while we're still in AWAITING_DEPOSIT,
    // this modifier reverts. You literally cannot call functions out
    // of order. This is what makes the contract predictable.

    modifier inState(State _expected) {
        if (currentState != _expected) {
            revert InvalidState(currentState, _expected);
        }
        _;
    }

    // ---------------------------------------------------------------
    // CONSTRUCTOR
    // ---------------------------------------------------------------

    // The BUYER deploys this contract. This is a design choice:
    // the buyer creates the escrow, defines the terms (who the seller
    // is, what the deadline is). The seller then looks at the deployed
    // contract, reads the code, reads the deadline, and decides
    // whether to participate. The seller's protection is CHOOSING
    // NOT TO ENGAGE if they don't like the terms.
    //
    // _seller   → the address that will receive funds on confirmation
    // _deadline → unix timestamp (seconds since epoch). After this
    //             time, the refund path opens. Use block.timestamp
    //             as a reference: e.g., block.timestamp + 7 days
    //             for a one-week escrow.

    constructor(address _seller, uint256 _deadline) {
        if (_seller == address(0)) revert InvalidSeller();
        if (_deadline <= block.timestamp) revert DeadlineInPast();

        buyer    = msg.sender;       // deployer is the buyer
        seller   = _seller;
        deadline = _deadline;
        currentState = State.AWAITING_DEPOSIT; // start at the beginning
    }

    // ---------------------------------------------------------------
    // DEPOSIT
    // ---------------------------------------------------------------

    // Two guards stacked: onlyBuyer AND inState(AWAITING_DEPOSIT).
    // Both must pass for the function to execute.
    //
    // After this function runs, deposit() can NEVER be called again —
    // the state has moved to AWAITING_CONFIRMATION, and the inState
    // modifier will reject any future attempts. This is the power
    // of the FSM: state transitions are one-way and enforced by code.

    function deposit() external payable onlyBuyer inState(State.AWAITING_DEPOSIT) {
        if (msg.value == 0) revert ZeroDeposit();

        amount = msg.value;
        currentState = State.AWAITING_CONFIRMATION;

        emit Funded(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------
    // CONFIRM RECEIVED — THE HAPPY PATH
    // ---------------------------------------------------------------

    // The buyer received the goods/service off-chain and calls this
    // to release payment to the seller.
    //
    // *** CHECKS-EFFECTS-INTERACTIONS PATTERN ***
    //
    // Notice the order:
    //   1. currentState = State.COMPLETE     ← EFFECT (state change)
    //   2. seller.call{value: amount}("")    ← INTERACTION (external call)
    //
    // We update state BEFORE sending ETH. Why?
    //
    // If the seller is a contract (not an EOA), the call{value}
    // triggers the seller's receive() or fallback() function.
    // A malicious seller contract could use that execution to call
    // BACK into our escrow (reentrancy attack).
    //
    // If we hadn't updated currentState first, the reentrant call
    // would see currentState == AWAITING_CONFIRMATION and could
    // potentially call confirmReceived() again.
    //
    // By setting COMPLETE first, any reentrant call hits the
    // inState(AWAITING_CONFIRMATION) modifier and reverts.
    //
    // This is the single most common smart contract vulnerability.
    // The fix is always the same: update your state BEFORE making
    // external calls.

    function confirmReceived() external onlyBuyer inState(State.AWAITING_CONFIRMATION) {
        // EFFECT first
        currentState = State.COMPLETE;

        // INTERACTION second
        (bool success, ) = seller.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit Confirmed(msg.sender);
        emit Released(seller, amount);
    }

    // ---------------------------------------------------------------
    // REFUND — THE PROTECTION PATH (THE ARBITER REPLACEMENT)
    // ---------------------------------------------------------------

    // This is the most important function for understanding why
    // we don't need a third-party arbiter.
    //
    // KEY OBSERVATIONS:
    //
    // 1. There is NO onlyBuyer modifier. ANYONE can call this.
    //    The buyer, the seller, a random stranger — doesn't matter.
    //    The require is the gatekeeper, not the caller's identity.
    //
    // 2. The ONLY condition is: has the deadline passed?
    //    block.timestamp >= deadline → yes → refund goes through
    //    block.timestamp <  deadline → no  → transaction reverts
    //
    // 3. This is the deadline REPLACING the arbiter:
    //
    //    Traditional escrow:
    //      Buyer goes silent → arbiter intervenes → decision
    //      Seller never delivers → arbiter intervenes → refund
    //      Problem: arbiter can be bribed, collude, delay, charge fees
    //
    //    This escrow:
    //      Buyer goes silent → deadline passes → anyone calls refund()
    //      Seller never delivers → deadline passes → anyone calls refund()
    //      The passage of time IS the intervention.
    //
    //    block.timestamp is:
    //      - Deterministic (math, not judgment)
    //      - Incorruptible (can't be bribed or socially engineered)
    //      - Permissionless (anyone can trigger it)
    //      - Always available (never sleeps, never goes on vacation)
    //
    // Same checks-effects-interactions pattern: update state before
    // sending ETH.

    function refund() external inState(State.AWAITING_CONFIRMATION) {
        if (block.timestamp < deadline) {
            revert DeadlineNotReached(block.timestamp, deadline);
        }

        // EFFECT first
        currentState = State.REFUNDED;

        // INTERACTION second
        (bool success, ) = buyer.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit Refunded(buyer, amount);
    }

    // ---------------------------------------------------------------
    // VIEW
    // ---------------------------------------------------------------

    // Convenience function to read all escrow details in one call
    // instead of five separate getter calls. Saves RPC round trips
    // for frontends.

    function getDetails()
        external
        view
        returns (
            address _buyer,
            address _seller,
            uint256 _amount,
            State   _state,
            uint256 _deadline
        )
    {
        return (buyer, seller, amount, currentState, deadline);
    }
}