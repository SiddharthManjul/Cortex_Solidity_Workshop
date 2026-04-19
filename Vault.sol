// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Vault
/// @notice The simplest on-chain custody pattern.
///         One owner, anyone can deposit, only owner can withdraw.
///         The contract itself IS the trust layer — no server, no database.

contract Vault {

    // ---------------------------------------------------------------
    // STATE
    // ---------------------------------------------------------------

    // The single address that controls withdrawals.
    // Set once in the constructor, never changes.
    // `public` auto-generates a getter: vault.owner() → address
    address public owner;

    // ---------------------------------------------------------------
    // EVENTS
    // ---------------------------------------------------------------

    // Events write to the transaction log — a cheap, append-only
    // data structure that off-chain systems (frontends, indexers,
    // block explorers) can read. You CANNOT read events from
    // within Solidity. They exist purely for the outside world.
    //
    // `indexed` parameters become topics in the log, which lets
    // off-chain filters efficiently query "show me all deposits
    // from address X" without scanning every log entry.

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    // ---------------------------------------------------------------
    // ERRORS
    // ---------------------------------------------------------------

    // Custom errors are cheaper than require strings (no string
    // encoding at runtime). They also give you typed revert data
    // that tooling (ethers.js, foundry) can decode automatically.

    error NotOwner();
    error ZeroDeposit();
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed();

    // ---------------------------------------------------------------
    // MODIFIERS
    // ---------------------------------------------------------------

    // A modifier is a reusable guard that wraps a function.
    // The `_;` placeholder means "now execute the function body."
    // Think of it as middleware — the check runs BEFORE the
    // function logic. If it reverts, the function never runs
    // and all state changes are rolled back.
    //
    // This is the access control pattern you'll reuse everywhere:
    // OpenZeppelin's Ownable, role-based access, timelocks —
    // they all start from this same idea.

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _; // ← function body executes here if check passes
    }

    // ---------------------------------------------------------------
    // CONSTRUCTOR
    // ---------------------------------------------------------------

    // Runs exactly ONCE — at deployment time. Never again.
    // msg.sender here is the wallet/contract that deploys this.
    // After this executes, `owner` is permanently set.
    // There is no setOwner() function, so ownership is immutable.

    constructor() {
        owner = msg.sender;
    }

    // ---------------------------------------------------------------
    // DEPOSIT
    // ---------------------------------------------------------------

    // `external` → can only be called from outside the contract,
    //               not by other internal functions. Slightly cheaper
    //               than `public` for external calls because it reads
    //               calldata directly instead of copying to memory.
    //
    // `payable`  → THIS is the keyword that lets the function receive
    //               ETH. Without it, any transaction sending ETH to
    //               this function would revert. Solidity defaults to
    //               rejecting ETH — you must explicitly opt in.
    //
    // Anyone can call this. There is no access control modifier.
    // The vault accepts deposits from any address.

    function deposit() external payable {
        if (msg.value == 0) revert ZeroDeposit();

        // msg.value is the amount of wei sent with this transaction.
        // 1 ETH = 1e18 wei. The ETH is already inside the contract
        // by the time this line executes — Solidity transfers it
        // before your function body runs. So this function doesn't
        // "move" the ETH, it just validates and logs.

        emit Deposited(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------
    // WITHDRAW
    // ---------------------------------------------------------------

    // Only the owner can call this (onlyOwner modifier).
    // The owner specifies how much to withdraw — they don't have
    // to drain the full balance.

    function withdraw(uint256 _amount) external onlyOwner {
        // address(this).balance gives the contract's current ETH
        // balance in wei. This is a built-in Solidity property.
        if (_amount > address(this).balance) {
            revert InsufficientBalance(_amount, address(this).balance);
        }

        // WHY call{value} INSTEAD OF transfer OR send?
        //
        // transfer(amount)  → forwards exactly 2300 gas
        // send(amount)      → forwards exactly 2300 gas, returns bool
        // call{value}("")   → forwards ALL remaining gas
        //
        // After the Istanbul hard fork (EIP-2200), gas costs for
        // SSTORE changed. 2300 gas is no longer enough for contracts
        // with non-trivial receive/fallback functions. Using transfer
        // to send ETH to a Gnosis Safe or any proxy contract will FAIL.
        //
        // call{value} is the modern standard. The tradeoff is
        // reentrancy risk — the receiver gets enough gas to call
        // back into your contract. In this vault, reentrancy isn't
        // dangerous because we're only sending to the owner and we
        // don't have complex state. But be AWARE of the pattern.
        //
        // The ("") is empty calldata — we're not calling any function
        // on the receiver, just sending ETH.
        //
        // Returns (bool success, bytes memory returnData).
        // We destructure but ignore returnData with the empty `, )`.

        (bool success, ) = msg.sender.call{value: _amount}("");
        if (!success) revert TransferFailed();

        emit Withdrawn(msg.sender, _amount);
    }

    // ---------------------------------------------------------------
    // VIEW
    // ---------------------------------------------------------------

    // `view` means this function reads state but doesn't modify it.
    // No gas cost when called off-chain (e.g., from a frontend).
    // Only costs gas if called from another contract during a tx.

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}