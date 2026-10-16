// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of Foundry's cheatcode interface these tests use. Declared locally so the
/// project has no third-party dependency; every selector and mutability matches forge's `Vm`.
interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function assume(bool condition) external pure;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function label(address account, string calldata newLabel) external;
    function expectRevert() external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function assertTrue(bool condition, string calldata error) external pure;
    function assertFalse(bool condition, string calldata error) external pure;
    function assertEq(uint256 left, uint256 right, string calldata error) external pure;
    function assertEq(address left, address right, string calldata error) external pure;
    function assertEq(bytes32 left, bytes32 right, string calldata error) external pure;
    function assertEq(string calldata left, string calldata right, string calldata error) external pure;
    function assertGt(uint256 left, uint256 right, string calldata error) external pure;
    function assertLe(uint256 left, uint256 right, string calldata error) external pure;
}
