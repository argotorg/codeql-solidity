// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * Test cases for Reentrancy.ql detector
 */

// VULNERABLE: Classic reentrancy - external call before state update
contract ReentrancyVulnerable {
    mapping(address => uint256) public balances;

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");

        // VULNERABLE: External call BEFORE state update
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        // State update AFTER external call - reentrancy possible!
        balances[msg.sender] -= amount;
    }

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }
}

// VULNERABLE: Reentrancy with transfer
contract ReentrancyTransfer {
    mapping(address => uint256) public balances;

    function withdraw() external {
        uint256 amount = balances[msg.sender];

        // VULNERABLE: transfer before state update
        payable(msg.sender).transfer(amount);

        balances[msg.sender] = 0;
    }
}

// VULNERABLE: Reentrancy with send
contract ReentrancySend {
    mapping(address => uint256) public balances;

    function withdraw() external {
        uint256 amount = balances[msg.sender];

        // VULNERABLE: send before state update
        bool sent = payable(msg.sender).send(amount);
        require(sent, "Failed to send");

        balances[msg.sender] = 0;
    }
}

// SAFE: Checks-Effects-Interactions pattern
contract ReentrancySafe {
    mapping(address => uint256) public balances;

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");

        // SAFE: State update BEFORE external call
        balances[msg.sender] -= amount;

        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }
}

// SAFE: Has nonReentrant modifier
contract ReentrancyGuarded {
    mapping(address => uint256) public balances;
    bool private locked;

    modifier nonReentrant() {
        require(!locked, "Reentrant call");
        locked = true;
        _;
        locked = false;
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(balances[msg.sender] >= amount, "Insufficient balance");

        // Would be vulnerable without the modifier
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        balances[msg.sender] -= amount;
    }
}

// VULNERABLE: Cross-function reentrancy
contract CrossFunctionReentrancy {
    mapping(address => uint256) public balances;

    function transfer(address to, uint256 amount) public {
        require(balances[msg.sender] >= amount);
        balances[msg.sender] -= amount;
        balances[to] += amount;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];

        // VULNERABLE: Attacker can call transfer() during this call
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success);

        balances[msg.sender] = 0;
    }
}

// ============================================
// EDGE CASES - FALSE POSITIVE PREVENTION
// ============================================

// Edge case: External call to trusted contract (still vulnerable in general)
contract TrustedContractCall {
    address public trustedOracle;
    mapping(address => uint256) public balances;

    // VULNERABLE: Even trusted contracts can be compromised
    function updateAndPay() external {
        (bool success,) = trustedOracle.call(abi.encodeWithSignature("getPrice()"));
        require(success);
        balances[msg.sender] = 0; // State update after call
    }
}

// Edge case: View function call (should NOT flag - staticcall can't reenter)
interface IOracle {
    function getPrice() external view returns (uint256);
}

contract ViewFunctionCall {
    address public oracle;
    mapping(address => uint256) public balances;

    // This might be flagged but view calls are safer
    function updateWithPrice() external {
        uint256 price = IOracle(oracle).getPrice(); // This is a staticcall
        balances[msg.sender] = price;
    }
}

// Edge case: Call in a loop (more severe)
contract ReentrancyInLoop {
    mapping(address => uint256) public balances;
    address[] public recipients;

    // VULNERABLE: Multiple external calls before state update
    function batchWithdraw() external {
        for (uint i = 0; i < recipients.length; i++) {
            (bool success,) = recipients[i].call{value: 100}("");
            require(success);
        }
        balances[msg.sender] = 0; // State update after loop
    }
}

// Edge case: State update in a different branch
contract ConditionalReentrancy {
    mapping(address => uint256) public balances;
    bool public useNewLogic;

    // VULNERABLE: State update only happens in one branch
    function withdraw() external {
        uint256 amount = balances[msg.sender];

        if (useNewLogic) {
            balances[msg.sender] = 0;
            (bool success,) = msg.sender.call{value: amount}("");
            require(success);
        } else {
            // VULNERABLE: This branch has call before update
            (bool success,) = msg.sender.call{value: amount}("");
            require(success);
            balances[msg.sender] = 0;
        }
    }
}

// Edge case: Custom reentrancy guard with different name
contract CustomGuard {
    mapping(address => uint256) public balances;
    uint256 private _locked = 1;

    modifier guardedEntry() {
        require(_locked == 1, "No reentry");
        _locked = 2;
        _;
        _locked = 1;
    }

    // SAFE: Has custom reentrancy guard
    function withdraw() external guardedEntry {
        uint256 amount = balances[msg.sender];
        (bool success,) = msg.sender.call{value: amount}("");
        require(success);
        balances[msg.sender] = 0;
    }
}

// Edge case: Read-only reentrancy (no state update, still problematic)
contract ReadOnlyReentrancy {
    mapping(address => uint256) public balances;
    uint256 public totalSupply;

    // This pattern allows reading stale totalSupply during callback
    function withdraw() external {
        uint256 amount = balances[msg.sender];
        balances[msg.sender] = 0;

        // External call after state update (CEI pattern followed)
        (bool success,) = msg.sender.call{value: amount}("");
        require(success);

        // But totalSupply update is after - read-only reentrancy possible
        totalSupply -= amount;
    }
}

// Edge case: Multiple state updates
contract MultipleStateUpdates {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public pending;

    // VULNERABLE: First state update before call, second after
    function withdraw() external {
        uint256 amount = balances[msg.sender];
        pending[msg.sender] = amount; // First update before call

        (bool success,) = msg.sender.call{value: amount}("");
        require(success);

        balances[msg.sender] = 0; // Second update after call - vulnerable
    }
}

// Edge case: ERC20 transfer (external call via transfer)
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

contract ERC20Reentrancy {
    IERC20 public token;
    mapping(address => uint256) public deposits;

    // VULNERABLE: ERC20 transfer is an external call
    function withdrawToken() external {
        uint256 amount = deposits[msg.sender];
        token.transfer(msg.sender, amount); // External call
        deposits[msg.sender] = 0; // State update after
    }
}

// Edge case: Safe ERC20 usage
contract SafeERC20Usage {
    IERC20 public token;
    mapping(address => uint256) public deposits;

    // SAFE: State update before external call
    function withdrawToken() external {
        uint256 amount = deposits[msg.sender];
        deposits[msg.sender] = 0; // State update first
        token.transfer(msg.sender, amount); // External call after
    }
}

// Edge case: Nested function call containing external call
contract NestedCallReentrancy {
    mapping(address => uint256) public balances;

    function _sendEther(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success);
    }

    // VULNERABLE: External call hidden in internal function
    function withdraw() external {
        uint256 amount = balances[msg.sender];
        _sendEther(msg.sender, amount);
        balances[msg.sender] = 0;
    }
}

// Edge case: OpenZeppelin ReentrancyGuard
contract OZReentrancyGuard {
    mapping(address => uint256) public balances;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // SAFE: Protected by OZ-style nonReentrant
    function withdraw() external nonReentrant {
        uint256 amount = balances[msg.sender];
        (bool success,) = msg.sender.call{value: amount}("");
        require(success);
        balances[msg.sender] = 0;
    }
}

// Edge case: Callback function reentrancy
contract CallbackReentrancy {
    mapping(address => uint256) public balances;

    // VULNERABLE: Callback can be reentered
    function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        // State update during callback
        balances[from] += 1;
        return this.onERC721Received.selector;
    }
}

// ============================================
// INTERPROCEDURAL CEI VIOLATIONS
// ============================================

// VULNERABLE: Helper function writes to mapping after external call
contract InterproceduralCEI1 {
    mapping(address => uint256) public balances;

    function _updateBalance(address user) internal {
        balances[user] = 0;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success);
        _updateBalance(msg.sender); // State mod hidden in callee
    }
}

// VULNERABLE: Two-level call chain — A calls B, B modifies state
contract InterproceduralCEI2 {
    mapping(address => uint256) public balances;

    function _clearBalance(address user) internal {
        balances[user] = 0;
    }

    function _processWithdrawal(address user) internal {
        _clearBalance(user);
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success);
        _processWithdrawal(msg.sender); // 2-hop state mod
    }
}

// VULNERABLE: Array mutation via .pop() in helper
contract InterproceduralCEI3 {
    address[] public recipients;

    function _removeLastRecipient() internal {
        recipients.pop();
    }

    function withdrawAndCleanup() external {
        (bool success, ) = msg.sender.call{value: 1 ether}("");
        require(success);
        _removeLastRecipient(); // Array pop in callee
    }
}

// VULNERABLE: counter++ in helper
contract InterproceduralCEI4 {
    uint256 public withdrawCount;

    function _incrementCounter() internal {
        withdrawCount++;
    }

    function withdraw() external {
        (bool success, ) = msg.sender.call{value: 1 ether}("");
        require(success);
        _incrementCounter(); // Update expression in callee
    }
}

// SAFE: State mod BEFORE external call via helper (CEI order preserved)
contract InterproceduralSafe {
    mapping(address => uint256) public balances;

    function _clearBalance(address user) internal {
        balances[user] = 0;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        _clearBalance(msg.sender); // State mod first
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success);
    }
}
