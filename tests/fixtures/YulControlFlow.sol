// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * Test contract for Yul/Assembly control flow constructs.
 * Used to validate the CFG implementation for inline assembly.
 */
contract YulControlFlow {

    // Simple assembly block
    function simpleAssembly() public pure returns (uint256 result) {
        assembly {
            result := 42
        }
    }

    // Yul if statement
    function yulIf(uint256 x) public pure returns (uint256 result) {
        assembly {
            // Yul if has no else branch
            if gt(x, 10) {
                result := 1
            }
            // Falls through if condition is false
            if iszero(result) {
                result := 0
            }
        }
    }

    // Yul for loop
    function yulForLoop(uint256 n) public pure returns (uint256 sum) {
        assembly {
            // for { init } condition { post } { body }
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                sum := add(sum, i)
            }
        }
    }

    // Yul for loop with break
    function yulForBreak(uint256 n) public pure returns (uint256 result) {
        assembly {
            for { let i := 0 } lt(i, 100) { i := add(i, 1) } {
                if gt(i, n) {
                    break
                }
                result := add(result, 1)
            }
        }
    }

    // Yul for loop with continue
    function yulForContinue(uint256 n) public pure returns (uint256 evenSum) {
        assembly {
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                // Skip odd numbers
                if mod(i, 2) {
                    continue
                }
                evenSum := add(evenSum, i)
            }
        }
    }

    // Yul switch statement
    function yulSwitch(uint256 x) public pure returns (uint256 result) {
        assembly {
            switch x
            case 0 {
                result := 100
            }
            case 1 {
                result := 200
            }
            case 2 {
                result := 300
            }
            default {
                result := 999
            }
        }
    }

    // Yul function definition and call
    function yulFunctions(uint256 a, uint256 b) public pure returns (uint256 result) {
        assembly {
            // Define a function
            function safeAdd(x, y) -> sum {
                sum := add(x, y)
                if lt(sum, x) {
                    // Overflow detected
                    sum := 0
                }
            }

            // Call the function
            result := safeAdd(a, b)
        }
    }

    // Yul leave statement (exits function early)
    function yulLeave(uint256 x) public pure returns (uint256 result) {
        assembly {
            function checkedValue(v) -> r {
                if iszero(v) {
                    r := 0
                    leave  // Exit the Yul function early
                }
                r := mul(v, 2)
            }

            result := checkedValue(x)
        }
    }

    // Complex nested control flow
    function complexYul(uint256 n) public pure returns (uint256 result) {
        assembly {
            result := 0

            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                // Nested switch
                switch mod(i, 3)
                case 0 {
                    result := add(result, 1)
                }
                case 1 {
                    // Nested if
                    if gt(i, 5) {
                        result := add(result, 10)
                    }
                }
                default {
                    // Nested for loop
                    for { let j := 0 } lt(j, 2) { j := add(j, 1) } {
                        result := add(result, 100)
                    }
                }
            }
        }
    }

    // Memory operations
    function memoryOps() public pure returns (bytes32 result) {
        assembly {
            // Store to memory
            mstore(0x00, 0x1234567890)

            // Load from memory
            result := mload(0x00)
        }
    }

    // Variable declarations
    function yulVariables() public pure returns (uint256 result) {
        assembly {
            let a := 1
            let b := 2
            let c := add(a, b)
            function twoVals() -> x, y {
                x := 10
                y := 20
            }
            let d, e := twoVals()  // Multiple assignment
            result := add(c, add(d, e))
        }
    }
}
