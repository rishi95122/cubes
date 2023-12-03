// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {DeployCube} from "../../script/DeployCube.s.sol";
import {DeployProxy} from "../../script/DeployProxy.s.sol";
import {Test, console, Vm} from "forge-std/Test.sol";
import {DemoCube2} from "../../src/CUBE.sol";
import {CubeV1} from "../../src/CubeV1.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessagehashUtils.sol";
import {SigUtils} from "../utils/Signature.t.sol";
import {EIP712Upgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract CubeTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /* EVENTS */
    event QuestMetadata(
        uint256 indexed questId,
        CubeV1.QuestType questType,
        CubeV1.Difficulty difficulty,
        string title
    );
    event QuestCommunity(uint256 indexed questId, string communityName);
    event CubeClaim(
        uint256 indexed questId,
        uint256 indexed tokenId,
        uint256 issueNumber,
        uint256 userId,
        uint256 completedAt,
        string walletName,
        string embedOrigin
    );
    event CubeTransaction(uint256 indexed tokenId, bytes32 indexed txHash, uint256 indexed chainId);

    DeployProxy public deployer;
    CubeV1 public demoCube;

    DemoCube2 public cube;

    string constant SIGNATURE_DOMAIN = "LAYER3";
    string constant SIGNING_VERSION = "1";

    SigUtils internal sigUtils;

    uint256 internal ownerPrivateKey;
    address internal ownerPubKey;

    address internal realAccount;
    uint256 internal realPrivateKey;

    // Test Users
    address public adminAddress;
    address public constant ADMIN = address(1);
    uint256 internal adminPrivateKey;
    address public constant ALICE = address(2);
    address public constant BOB = address(3);

    address public proxyAddress;

    function getDomainSeparator() internal view virtual returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(SIGNATURE_DOMAIN)),
                keccak256(bytes(SIGNING_VERSION)),
                block.chainid,
                proxyAddress
            )
        );
    }

    function setUp() public {
        ownerPrivateKey = 0xA11CE;
        ownerPubKey = vm.addr(ownerPrivateKey);

        adminPrivateKey = 0x01;
        adminAddress = vm.addr(adminPrivateKey);

        deployer = new DeployProxy();
        proxyAddress = deployer.deployProxy(ownerPubKey);
        demoCube = CubeV1(payable(proxyAddress));

        vm.startBroadcast();
        //testCubeContract = new TestCubeContract();
        DeployCube deployCube = new DeployCube();

        cube = deployCube.run();
        vm.stopBroadcast();

        sigUtils = new SigUtils();
    }

    function testInitializeQuest() public {
        uint256 questId = 1;
        string[] memory communities = new string[](2);
        communities[0] = "Community1";
        communities[1] = "Community2";
        string memory title = "Quest Title";
        CubeV1.Difficulty difficulty = CubeV1.Difficulty.BEGINNER;
        CubeV1.QuestType questType = CubeV1.QuestType.QUEST;

        // Expecting QuestCommunity and QuestMetadata events to be emitted
        vm.expectEmit(true, true, false, true);
        emit QuestCommunity(questId, communities[0]);
        emit QuestCommunity(questId, communities[1]);
        vm.expectEmit(true, true, false, true);
        emit QuestMetadata(questId, questType, difficulty, title);

        vm.prank(ownerPubKey);
        demoCube.initializeQuest(questId, communities, title, difficulty, questType);
    }

    function testInitializeQuestNotAsSigner() public {
        uint256 questId = 1;
        string[] memory communities = new string[](2);
        communities[0] = "Community1";
        communities[1] = "Community2";
        string memory title = "Quest Title";
        CubeV1.Difficulty difficulty = CubeV1.Difficulty.BEGINNER;
        CubeV1.QuestType questType = CubeV1.QuestType.QUEST;

        bytes4 selector = bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)"));
        bytes memory expectedError =
            abi.encodeWithSelector(selector, ALICE, keccak256("SIGNER_ROLE"));
        vm.expectRevert(expectedError);
        vm.prank(ALICE);
        demoCube.initializeQuest(questId, communities, title, difficulty, questType);
    }

    function testMintMultipleCubes() public {
        CubeV1.CubeData memory _data = sigUtils.getTestCubeData(ALICE, BOB);

        bytes32 structHash = sigUtils.getStructHash(_data);
        bytes32 digest = sigUtils.getDigest(getDomainSeparator(), structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        address signer = sigUtils.getSigner(_data, signature);
        console.log("signer is %", signer);
        assertEq(signer, ownerPubKey);

        CubeV1.CubeData[] memory cubeData = new CubeV1.CubeData[](1);
        bytes[] memory signatures = new bytes[](1);
        cubeData[0] = _data;
        signatures[0] = signature;

        bool isSigner = sigUtils.hasRole(keccak256("SIGNER"), ownerPubKey);
        console.logBool(isSigner);

        hoax(adminAddress, 3 ether);
        demoCube.mintMultipleCubes{value: 3 ether}(cubeData, signatures);

        assertEq(demoCube.tokenURI(0), "ipfs://abc");
    }

    function testInitalizeQuestLogs() public {
        uint256 questId = 777;
        string[] memory communities = new string[](1);
        communities[0] = "Community1";
        string memory title = "Quest Title";
        CubeV1.Difficulty difficulty = CubeV1.Difficulty.BEGINNER;
        CubeV1.QuestType questType = CubeV1.QuestType.QUEST;
        vm.recordLogs();
        vm.prank(ownerPubKey);
        demoCube.initializeQuest(questId, communities, title, difficulty, questType);

        Vm.Log[] memory entries = vm.getRecordedLogs();

        // the emitted questId value
        assert(uint256(entries[1].topics[1]) == questId);
    }

    function testReceiveFallback() public {
        uint256 sendAmount = 1 ether;
        vm.deal(address(demoCube), sendAmount);
        (bool success,) = address(demoCube).call{value: 2 ether}("");
        assert(success == true);

        uint256 balance = address(demoCube).balance;
        console.log("contract balance: %s", balance);

        assertEq(balance, sendAmount + 2 ether, "Contract should receive Ether");

        // Record initial balance of ADMIN_USER
        uint256 initialAdminBalance = ownerPubKey.balance;

        // Call withdraw function
        vm.prank(ownerPubKey); // Ensure the call is made by an address with the DEFAULT_ADMIN_ROLE
        demoCube.withdraw();

        console.log("contract balance after withdrawal: %s", address(demoCube).balance);

        // Check the contract's balance after withdrawal
        assertEq(address(demoCube).balance, 0, "Contract balance should be 0 after withdrawal");

        // Check the balance of the ADMIN
        uint256 finalAdminBalance = ownerPubKey.balance;
        console.log("admin balance: %s", finalAdminBalance);
        assert(finalAdminBalance > initialAdminBalance);
    }

    function testTurnOffMinting() public {
        bool isActive = demoCube.isMintingActive();

        console.logBool(isActive);
        vm.prank(ownerPubKey);
        demoCube.setIsMintingActive(false);

        bool isActiveUpdated = demoCube.isMintingActive();
        console.logBool(isActiveUpdated);

        assert(isActiveUpdated != isActive);
    }

    function test721Interface() public view {
        bool supportsInterface = demoCube.supportsInterface(type(IERC721).interfaceId);
        assert(supportsInterface == true);
    }

    function testInitializeUUPS() public {
        demoCube.initialize(
            deployer.NAME(),
            deployer.SYMBOL(),
            deployer.SIGNATURE_DOMAIN(),
            deployer.SIGNING_VERSION(),
            ownerPubKey
        );
    }

    function testSetTokenURI() public {
        vm.prank(ownerPubKey);
        demoCube.setTokenURI(0, "hey");
    }

    function testRevokeAdminRole() public {
        vm.prank(ownerPubKey);
        bytes32 signerRole = keccak256("UPGRADER_ROLE");
        bool isSigner = demoCube.hasRole(signerRole, ownerPubKey);

        console.logBool(isSigner);
        demoCube.revokeRole(signerRole, ownerPubKey);
        console.log(demoCube.hasRole(signerRole, ownerPubKey));
    }
}
