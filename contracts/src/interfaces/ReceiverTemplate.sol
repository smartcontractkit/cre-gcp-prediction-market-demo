// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "./IERC165.sol";
import {IReceiver} from "./IReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ReceiverTemplate - Abstract receiver with optional permission controls
/// @notice Provides flexible, updatable security checks for receiving workflow reports
/// @dev All permission fields default to zero (disabled). Use setter functions to enable checks.
abstract contract ReceiverTemplate is IReceiver, Ownable {
    // Optional permission fields (all default to zero = disabled)
    address private s_forwarderAddress; // If set, only this address can call onReport
    address private s_expectedAuthor; // If set, only reports from this workflow owner are accepted
    bytes10 private s_expectedWorkflowName; // If set, only reports with this workflow name are accepted
    bytes32 private s_expectedWorkflowId; // If set, only reports from this specific workflow ID are accepted

    // Hex character lookup table for bytes-to-hex conversion
    bytes private constant HEX_CHARS = "0123456789abcdef";

    // Custom errors
    error InvalidSender(address sender, address expected);
    error InvalidAuthor(address received, address expected);
    error InvalidWorkflowName(bytes10 received, bytes10 expected);
    error InvalidWorkflowId(bytes32 received, bytes32 expected);

    // Events
    event ForwarderAddressUpdated(address indexed previousForwarder, address indexed newForwarder);
    event ExpectedAuthorUpdated(address indexed previousAuthor, address indexed newAuthor);
    event ExpectedWorkflowNameUpdated(bytes10 indexed previousName, bytes10 indexed newName);
    event ExpectedWorkflowIdUpdated(bytes32 indexed previousId, bytes32 indexed newId);

    /// @notice Constructor sets msg.sender as the owner
    /// @dev All permission fields are initialized to zero (disabled by default)
    constructor() Ownable(msg.sender) {}

    /// @notice Returns the configured forwarder address
    /// @return The forwarder address (address(0) if not set)
    function getForwarderAddress() external view returns (address) {
        return s_forwarderAddress;
    }

    /// @notice Returns the expected workflow author address
    /// @return The expected author address (address(0) if not set)
    function getExpectedAuthor() external view returns (address) {
        return s_expectedAuthor;
    }

    /// @notice Returns the expected workflow name
    /// @return The expected workflow name (bytes10(0) if not set)
    function getExpectedWorkflowName() external view returns (bytes10) {
        return s_expectedWorkflowName;
    }

    /// @notice Returns the expected workflow ID
    /// @return The expected workflow ID (bytes32(0) if not set)
    function getExpectedWorkflowId() external view returns (bytes32) {
        return s_expectedWorkflowId;
    }

    /// @inheritdoc IReceiver
    /// @dev Performs optional validation checks based on which permission fields are set
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        // Security Check 1: Verify caller is the trusted Chainlink Forwarder (if configured)
        if (s_forwarderAddress != address(0) && msg.sender != s_forwarderAddress) {
            revert InvalidSender(msg.sender, s_forwarderAddress);
        }

        // Security Checks 2-4: Verify workflow identity - ID, owner, and/or name (if any are configured)
        if (s_expectedWorkflowId != bytes32(0) || s_expectedAuthor != address(0) || s_expectedWorkflowName != bytes10(0)) {
            (bytes32 workflowId, bytes10 workflowName, address workflowOwner) = _decodeMetadata(metadata);

            if (s_expectedWorkflowId != bytes32(0) && workflowId != s_expectedWorkflowId) {
                revert InvalidWorkflowId(workflowId, s_expectedWorkflowId);
            }
            if (s_expectedAuthor != address(0) && workflowOwner != s_expectedAuthor) {
                revert InvalidAuthor(workflowOwner, s_expectedAuthor);
            }
            if (s_expectedWorkflowName != bytes10(0) && workflowName != s_expectedWorkflowName) {
                revert InvalidWorkflowName(workflowName, s_expectedWorkflowName);
            }
        }

        _processReport(report);
    }

    /// @notice Updates the forwarder address that is allowed to call onReport
    /// @param _forwarder The new forwarder address (use address(0) to disable this check)
    function setForwarderAddress(address _forwarder) external onlyOwner {
        address previousForwarder = s_forwarderAddress;
        s_forwarderAddress = _forwarder;
        emit ForwarderAddressUpdated(previousForwarder, _forwarder);
    }

    /// @notice Updates the expected workflow owner address
    /// @param _author The new expected author address (use address(0) to disable this check)
    function setExpectedAuthor(address _author) external onlyOwner {
        address previousAuthor = s_expectedAuthor;
        s_expectedAuthor = _author;
        emit ExpectedAuthorUpdated(previousAuthor, _author);
    }

    /// @notice Updates the expected workflow name from a plaintext string
    /// @param _name The workflow name as a string (use empty string "" to disable this check)
    /// @dev The name is hashed using SHA256 and truncated
    function setExpectedWorkflowName(string calldata _name) external onlyOwner {
        bytes10 previousName = s_expectedWorkflowName;

        if (bytes(_name).length == 0) {
            s_expectedWorkflowName = bytes10(0);
            emit ExpectedWorkflowNameUpdated(previousName, bytes10(0));
            return;
        }

        // Convert workflow name to bytes10:
        // SHA256 hash → hex encode → take first 10 chars → hex encode those chars
        bytes32 hash = sha256(bytes(_name));
        bytes memory hexString = _bytesToHexString(abi.encodePacked(hash));
        bytes memory first10 = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            first10[i] = hexString[i];
        }
        s_expectedWorkflowName = bytes10(first10);
        emit ExpectedWorkflowNameUpdated(previousName, s_expectedWorkflowName);
    }

    /// @notice Updates the expected workflow ID
    /// @param _id The new expected workflow ID (use bytes32(0) to disable this check)
    function setExpectedWorkflowId(bytes32 _id) external onlyOwner {
        bytes32 previousId = s_expectedWorkflowId;
        s_expectedWorkflowId = _id;
        emit ExpectedWorkflowIdUpdated(previousId, _id);
    }

    /// @notice Helper function to convert bytes to hex string
    /// @param data The bytes to convert
    /// @return The hex string representation
    function _bytesToHexString(bytes memory data) private pure returns (bytes memory) {
        bytes memory hexString = new bytes(data.length * 2);

        for (uint256 i = 0; i < data.length; i++) {
            hexString[i * 2] = HEX_CHARS[uint8(data[i] >> 4)];
            hexString[i * 2 + 1] = HEX_CHARS[uint8(data[i] & 0x0f)];
        }

        return hexString;
    }

    /// @notice Extracts all metadata fields from the onReport metadata parameter
    /// @param metadata The metadata bytes encoded using abi.encodePacked(workflowId, workflowName, workflowOwner)
    /// @return workflowId The unique identifier of the workflow (bytes32)
    /// @return workflowName The name of the workflow (bytes10)
    /// @return workflowOwner The owner address of the workflow
    function _decodeMetadata(bytes memory metadata)
        internal
        pure
        returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    {
        // Metadata structure (encoded using abi.encodePacked by the Forwarder):
        // - First 32 bytes: length of the byte array (standard for dynamic bytes)
        // - Offset 32, size 32: workflow_id (bytes32)
        // - Offset 64, size 10: workflow_name (bytes10)
        // - Offset 74, size 20: workflow_owner (address)
        assembly {
            workflowId := mload(add(metadata, 32))
            workflowName := mload(add(metadata, 64))
            workflowOwner := shr(mul(12, 8), mload(add(metadata, 74)))
        }
        return (workflowId, workflowName, workflowOwner);
    }

    /// @notice Abstract function to process the report data
    /// @param report The report calldata containing your workflow's encoded data
    /// @dev Implement this function with your contract's business logic
    function _processReport(bytes calldata report) internal virtual;

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}