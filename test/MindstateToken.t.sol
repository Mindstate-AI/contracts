// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MindstateToken} from "../src/MindstateToken.sol";
import {MindstateFactory} from "../src/MindstateFactory.sol";
import {IMindstate} from "../src/interfaces/IMindstate.sol";

contract MindstateTokenTest is Test {
    MindstateToken public implementation;
    MindstateFactory public factory;
    MindstateToken public token;

    address public publisher = address(0x1);
    address public consumer = address(0x2);
    address public outsider = address(0x3);

    uint256 public constant TOTAL_SUPPLY = 1_000_000e18;
    uint256 public constant REDEEM_COST = 100e18;

    function setUp() public {
        implementation = new MindstateToken();
        factory = new MindstateFactory(address(implementation));

        vm.prank(publisher);
        address tokenAddr = factory.create(
            "Test Agent",
            "TAGENT",
            TOTAL_SUPPLY,
            REDEEM_COST,
            IMindstate.RedeemMode.PerCheckpoint
        );
        token = MindstateToken(tokenAddr);

        // Give consumer some tokens
        vm.prank(publisher);
        token.transfer(consumer, 10_000e18);
    }

    // -----------------------------------------------------------------------
    //  Initialization
    // -----------------------------------------------------------------------

    function test_initialization() public view {
        assertEq(token.publisher(), publisher);
        assertEq(token.name(), "Test Agent");
        assertEq(token.symbol(), "TAGENT");
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.redeemCost(), REDEEM_COST);
        assertEq(uint8(token.redeemMode()), uint8(IMindstate.RedeemMode.PerCheckpoint));
        assertEq(token.balanceOf(publisher), TOTAL_SUPPLY - 10_000e18);
        assertEq(token.balanceOf(consumer), 10_000e18);
        assertEq(token.head(), bytes32(0));
        assertEq(token.checkpointCount(), 0);
    }

    function test_cannotReinitialize() public {
        vm.expectRevert();
        token.initialize(outsider, "Hack", "HACK", 999e18, 1e18, IMindstate.RedeemMode.Universal);
    }

    // -----------------------------------------------------------------------
    //  Publishing
    // -----------------------------------------------------------------------

    function _publish(string memory label) internal returns (bytes32) {
        vm.prank(publisher);
        return token.publish(
            keccak256("state1"),
            keccak256("cipher1"),
            "ipfs://QmTest1",
            keccak256("manifest1"),
            label
        );
    }

    function test_publishCreatesCheckpoint() public {
        bytes32 cpId = _publish("");

        assertEq(token.checkpointCount(), 1);
        assertEq(token.head(), cpId);
        assertEq(token.getCheckpointIdAtIndex(0), cpId);

        IMindstate.Checkpoint memory cp = token.getCheckpoint(cpId);
        assertEq(cp.predecessorId, bytes32(0));
        assertEq(cp.stateCommitment, keccak256("state1"));
        assertEq(cp.ciphertextHash, keccak256("cipher1"));
        assertEq(keccak256(bytes(cp.ciphertextUri)), keccak256("ipfs://QmTest1"));
        assertEq(cp.manifestHash, keccak256("manifest1"));
        assertGt(cp.publishedAt, 0);
        assertGt(cp.blockNumber, 0);
    }

    function test_publishChainsPredecessors() public {
        bytes32 cp1 = _publish("");

        vm.prank(publisher);
        bytes32 cp2 = token.publish(
            keccak256("state2"),
            keccak256("cipher2"),
            "ipfs://QmTest2",
            keccak256("manifest2"),
            ""
        );

        assertEq(token.checkpointCount(), 2);
        assertEq(token.head(), cp2);

        IMindstate.Checkpoint memory checkpoint2 = token.getCheckpoint(cp2);
        assertEq(checkpoint2.predecessorId, cp1);
    }

    function test_publishEmitsEvent() public {
        vm.prank(publisher);
        vm.expectEmit(false, false, false, false);
        emit IMindstate.CheckpointPublished(
            bytes32(0), bytes32(0), 0, bytes32(0), bytes32(0), "", bytes32(0), 0, 0
        );
        token.publish(keccak256("s"), keccak256("c"), "uri", keccak256("m"), "");
    }

    function test_nonPublisherCannotPublish() public {
        vm.prank(outsider);
        vm.expectRevert("Mindstate: caller is not the publisher");
        token.publish(keccak256("s"), keccak256("c"), "uri", keccak256("m"), "");
    }

    // -----------------------------------------------------------------------
    //  Publishing with Label
    // -----------------------------------------------------------------------

    function test_publishWithLabel() public {
        bytes32 cpId = _publish("v1.0");

        assertEq(token.resolveTag("v1.0"), cpId);
        assertEq(keccak256(bytes(token.getCheckpointTag(cpId))), keccak256("v1.0"));
    }

    function test_publishWithEmptyLabelSkipsTag() public {
        bytes32 cpId = _publish("");

        assertEq(token.resolveTag(""), bytes32(0));
        assertEq(bytes(token.getCheckpointTag(cpId)).length, 0);
    }

    // -----------------------------------------------------------------------
    //  Tagging
    // -----------------------------------------------------------------------

    function test_tagCheckpoint() public {
        bytes32 cpId = _publish("");

        vm.prank(publisher);
        token.tagCheckpoint(cpId, "stable");

        assertEq(token.resolveTag("stable"), cpId);
        assertEq(keccak256(bytes(token.getCheckpointTag(cpId))), keccak256("stable"));
    }

    function test_tagCanBeMovedToNewCheckpoint() public {
        bytes32 cp1 = _publish("");

        vm.prank(publisher);
        bytes32 cp2 = token.publish(keccak256("s2"), keccak256("c2"), "uri2", keccak256("m2"), "");

        vm.prank(publisher);
        token.tagCheckpoint(cp1, "stable");
        assertEq(token.resolveTag("stable"), cp1);

        // Move the tag
        vm.prank(publisher);
        token.tagCheckpoint(cp2, "stable");
        assertEq(token.resolveTag("stable"), cp2);

        // Old checkpoint's tag should be cleared
        assertEq(bytes(token.getCheckpointTag(cp1)).length, 0);
    }

    function test_retagClearsOldTag() public {
        bytes32 cpId = _publish("");

        vm.prank(publisher);
        token.tagCheckpoint(cpId, "alpha");
        assertEq(token.resolveTag("alpha"), cpId);

        // Assign new tag to same checkpoint
        vm.prank(publisher);
        token.tagCheckpoint(cpId, "beta");
        assertEq(token.resolveTag("beta"), cpId);
        assertEq(token.resolveTag("alpha"), bytes32(0)); // old tag cleared
    }

    function test_nonPublisherCannotTag() public {
        bytes32 cpId = _publish("");

        vm.prank(outsider);
        vm.expectRevert("Mindstate: caller is not the publisher");
        token.tagCheckpoint(cpId, "stable");
    }

    function test_cannotTagNonexistentCheckpoint() public {
        vm.prank(publisher);
        vm.expectRevert("Mindstate: checkpoint does not exist");
        token.tagCheckpoint(keccak256("fake"), "stable");
    }

    function test_cannotTagWithEmptyString() public {
        bytes32 cpId = _publish("");

        vm.prank(publisher);
        vm.expectRevert("Mindstate: tag must not be empty");
        token.tagCheckpoint(cpId, "");
    }

    function test_tagEmitsEvent() public {
        bytes32 cpId = _publish("");

        vm.prank(publisher);
        vm.expectEmit(true, false, false, true);
        emit IMindstate.CheckpointTagged(cpId, "stable");
        token.tagCheckpoint(cpId, "stable");
    }

    // -----------------------------------------------------------------------
    //  Burn-to-Redeem (PerCheckpoint)
    // -----------------------------------------------------------------------

    function test_redeemBurnsTokens() public {
        bytes32 cpId = _publish("");
        uint256 balanceBefore = token.balanceOf(consumer);

        vm.prank(consumer);
        token.redeem(cpId);

        assertEq(token.balanceOf(consumer), balanceBefore - REDEEM_COST);
        assertTrue(token.hasRedeemed(consumer, cpId));
    }

    function test_redeemEmitsEvent() public {
        bytes32 cpId = _publish("");

        vm.prank(consumer);
        vm.expectEmit(true, true, false, true);
        emit IMindstate.Redeemed(consumer, cpId, REDEEM_COST);
        token.redeem(cpId);
    }

    function test_cannotDoubleRedeem() public {
        bytes32 cpId = _publish("");

        vm.prank(consumer);
        token.redeem(cpId);

        vm.prank(consumer);
        vm.expectRevert("Mindstate: already redeemed for this checkpoint");
        token.redeem(cpId);
    }

    function test_cannotRedeemNonexistentCheckpoint() public {
        vm.prank(consumer);
        vm.expectRevert("Mindstate: checkpoint does not exist");
        token.redeem(keccak256("fake"));
    }

    function test_redeemDifferentCheckpointsIndependently() public {
        bytes32 cp1 = _publish("");
        vm.prank(publisher);
        bytes32 cp2 = token.publish(keccak256("s2"), keccak256("c2"), "uri2", keccak256("m2"), "");

        vm.prank(consumer);
        token.redeem(cp1);

        assertTrue(token.hasRedeemed(consumer, cp1));
        assertFalse(token.hasRedeemed(consumer, cp2));

        vm.prank(consumer);
        token.redeem(cp2);

        assertTrue(token.hasRedeemed(consumer, cp2));
    }

    function test_cannotRedeemWithInsufficientBalance() public {
        bytes32 cpId = _publish("");

        // Outsider has no tokens
        vm.prank(outsider);
        vm.expectRevert();
        token.redeem(cpId);
    }

    // -----------------------------------------------------------------------
    //  Burn-to-Redeem (Universal)
    // -----------------------------------------------------------------------

    function test_universalRedeem() public {
        // Deploy a Universal-mode token
        vm.prank(publisher);
        address uniAddr = factory.create(
            "Universal Agent",
            "UAGENT",
            TOTAL_SUPPLY,
            REDEEM_COST,
            IMindstate.RedeemMode.Universal
        );
        MindstateToken uni = MindstateToken(uniAddr);

        vm.prank(publisher);
        uni.transfer(consumer, 10_000e18);

        // Publish a checkpoint
        vm.prank(publisher);
        bytes32 cpId = uni.publish(keccak256("s"), keccak256("c"), "uri", keccak256("m"), "");

        // Redeem universally (checkpointId is ignored)
        vm.prank(consumer);
        uni.redeem(bytes32(0));

        assertTrue(uni.hasRedeemed(consumer, cpId));
        assertTrue(uni.hasRedeemed(consumer, keccak256("any-random-id")));
    }

    function test_universalCannotDoubleRedeem() public {
        vm.prank(publisher);
        address uniAddr = factory.create("U", "U", TOTAL_SUPPLY, REDEEM_COST, IMindstate.RedeemMode.Universal);
        MindstateToken uni = MindstateToken(uniAddr);

        vm.prank(publisher);
        uni.transfer(consumer, 10_000e18);

        vm.prank(consumer);
        uni.redeem(bytes32(0));

        vm.prank(consumer);
        vm.expectRevert("Mindstate: already redeemed");
        uni.redeem(bytes32(0));
    }

    function test_universalRedeemEmitsZeroCheckpointId() public {
        vm.prank(publisher);
        address uniAddr = factory.create("U", "U", TOTAL_SUPPLY, REDEEM_COST, IMindstate.RedeemMode.Universal);
        MindstateToken uni = MindstateToken(uniAddr);

        vm.prank(publisher);
        uni.transfer(consumer, 10_000e18);

        vm.prank(consumer);
        vm.expectEmit(true, true, false, true);
        emit IMindstate.Redeemed(consumer, bytes32(0), REDEEM_COST);
        uni.redeem(bytes32(0));
    }

    // -----------------------------------------------------------------------
    //  Publisher Transfer
    // -----------------------------------------------------------------------

    function test_transferPublisher() public {
        vm.prank(publisher);
        token.transferPublisher(outsider);

        assertEq(token.publisher(), outsider);

        // Old publisher can no longer publish
        vm.prank(publisher);
        vm.expectRevert("Mindstate: caller is not the publisher");
        token.publish(keccak256("s"), keccak256("c"), "uri", keccak256("m"), "");

        // New publisher can publish
        vm.prank(outsider);
        token.publish(keccak256("s"), keccak256("c"), "uri", keccak256("m"), "");
    }

    function test_cannotTransferToZero() public {
        vm.prank(publisher);
        vm.expectRevert("Mindstate: new publisher is zero address");
        token.transferPublisher(address(0));
    }

    function test_transferEmitsEvent() public {
        vm.prank(publisher);
        vm.expectEmit(true, true, false, false);
        emit IMindstate.PublisherTransferred(publisher, outsider);
        token.transferPublisher(outsider);
    }

    // -----------------------------------------------------------------------
    //  Encryption Key Registry
    // -----------------------------------------------------------------------

    function test_registerEncryptionKey() public {
        bytes32 key = keccak256("my-x25519-key");

        vm.prank(consumer);
        token.registerEncryptionKey(key);

        assertEq(token.getEncryptionKey(consumer), key);
    }

    function test_rotateEncryptionKey() public {
        bytes32 key1 = keccak256("key1");
        bytes32 key2 = keccak256("key2");

        vm.prank(consumer);
        token.registerEncryptionKey(key1);
        assertEq(token.getEncryptionKey(consumer), key1);

        vm.prank(consumer);
        token.registerEncryptionKey(key2);
        assertEq(token.getEncryptionKey(consumer), key2);
    }

    function test_cannotRegisterZeroKey() public {
        vm.prank(consumer);
        vm.expectRevert("Mindstate: empty encryption key");
        token.registerEncryptionKey(bytes32(0));
    }

    function test_unregisteredKeyIsZero() public view {
        assertEq(token.getEncryptionKey(outsider), bytes32(0));
    }

    // -----------------------------------------------------------------------
    //  Factory
    // -----------------------------------------------------------------------

    function test_factoryDeploymentCount() public view {
        assertEq(factory.deploymentCount(), 1);
        assertEq(factory.getDeployment(0), address(token));
    }

    function test_factoryPublisherTokens() public view {
        address[] memory tokens = factory.getPublisherTokens(publisher);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(token));
    }

    function test_factoryCreateDeterministic() public {
        bytes32 salt = keccak256("test-salt");
        address predicted = factory.predictDeterministicAddress(salt, publisher);

        vm.prank(publisher);
        address actual = factory.createDeterministic(
            "Det Agent", "DET", TOTAL_SUPPLY, REDEEM_COST, IMindstate.RedeemMode.PerCheckpoint, salt
        );

        assertEq(actual, predicted);
        assertEq(factory.deploymentCount(), 2);
    }

    function test_factoryMultipleDeployments() public {
        vm.prank(publisher);
        factory.create("A2", "A2", 100e18, 10e18, IMindstate.RedeemMode.Universal);

        vm.prank(outsider);
        factory.create("A3", "A3", 200e18, 20e18, IMindstate.RedeemMode.PerCheckpoint);

        assertEq(factory.deploymentCount(), 3);
        assertEq(factory.getPublisherTokens(outsider).length, 1);
    }

    // -----------------------------------------------------------------------
    //  Checkpoint Index Bounds
    // -----------------------------------------------------------------------

    function test_getCheckpointIdOutOfBounds() public {
        vm.expectRevert("Mindstate: index out of bounds");
        token.getCheckpointIdAtIndex(0);
    }
}
