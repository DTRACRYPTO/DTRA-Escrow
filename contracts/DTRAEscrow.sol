// SPDX-License-Identifier: BUSL-1.1
// ─────────────────────────────────────────────────────────────────────────────
//  DTRA Hedera Escrow – Full Suite v2
//  Network: Hedera Smart Contract Service (EVM-compatible)
//
//  Capabilities
//  • Multi-asset custody: HBAR (native) or any HTS-mapped ERC‑20 (incl. DTRA, wBTC, wETH)
//  • Deterministic per-deal escrows via CREATE2 (address announced post-deploy per Hedera rules)
//  • HTLC (Hash‑Time‑Locked) release for cross-chain atomicity with BTC/ETH
//  • Oracle release: EIP‑712 signed approvals with N‑of‑M quorum
//  • Optional incentive micro‑bonds in HBAR (seller performance / buyer dispute)
//  • Fee routing with optional referrer (treasury + affiliate), capped by MAX_FEE_BPS
//  • ERC‑20 permit (EIP‑2612) fast‑funding if the token supports it
//  • SafeERC20 wrappers + fee‑on‑transfer aware funding
//  • Pausable circuit breaker (factory‑controlled)
//  • HTS association/dissociation via 0x167 precompile
//  • Reentrancy‑safe; single‑use settlement; strict term binding
//
//  Notes (Hedera specifics)
//  • HTS tokens require association before a contract can hold them. The Factory associates the
//    newly deployed escrow to the token immediately. Dissociation is available after settlement
//    when balances are zero, to reclaim association slots.
//  • HBAR cannot be pre‑funded to a non‑deployed address on Hedera. Deploy first, then fund.
//  • "Accept BTC/ETH" is achieved either via wrapped assets on Hedera (wBTC/wETH) or via a
//    cross-chain HTLC: when the preimage is revealed on BTC/ETH, the same preimage releases here.
// ─────────────────────────────────────────────────────────────────────────────
pragma solidity ^0.8.20;

// ───────────────────────── Interfaces & Libs ─────────────────────────
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
interface IHederaTokenService {
    function associateToken(address account, address token) external returns (int64);
    function dissociateToken(address account, address token) external returns (int64);
}

library SafeERC20 {
    function safeTransfer(IERC20 t, address to, uint256 v) internal {
        require(t.transfer(to, v), "SAFE_TRANSFER");
    }
    function safeTransferFrom(IERC20 t, address f, address to, uint256 v) internal {
        require(t.transferFrom(f, to, v), "SAFE_XFER_FROM");
    }
}

library ECDSA {
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "SIG_LEN");
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "SIG_V");
        address signer = ecrecover(hash, v, r, s);
        require(signer != address(0), "SIG_BAD");
        return signer;
    }
}

abstract contract ReentrancyGuard { uint256 private _g; modifier nonReentrant(){ require(_g==0,"REENTR"); _g=1; _; _g=0; } }

// ───────────────────────────── Escrow ─────────────────────────────
contract DTRAEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Constants
    uint96  public constant MAX_FEE_BPS = 2_000; // 20%

    // Factory link (immutable after constructor)
    address public factory;

    // Asset & roles
    address public token;            // address(0) => HBAR; else HTS‑mapped ERC‑20
    address public buyer;
    address public seller;

    // Commercial terms
    uint256 public amount;           // principal (HBAR wei or token units)
    uint64  public deadline;         // unix seconds – refund available after
    uint96  public feeBps;           // fee to treasury
    uint96  public refFeeBps;        // fee to referrer (optional)
    address public feeRecipient;     // treasury
    address public refRecipient;     // affiliate/referrer

    // Hash‑time‑lock (optional)
    bytes32 public secretHash;       // keccak256(preimage)

    // Incentive micro‑bonds (HBAR)
    uint128 public sellerBondHBAR;   // goes to buyer if timeout
    uint128 public buyerBondHBAR;    // goes to seller on successful release

    // State flags
    bool    public initialized;
    bool    public funded;
    bool    public settled;
    bool    public disputed;
    bool    public paused;           // circuit breaker (factory-controlled)

    // Oracles (optional)
    address[] public oracles;        // allowed signers
    uint8    public oracleQuorum;    // N-of-M threshold

    // Caches / accounting
    uint256 public fundedAmount;     // actual tokens received (handles fee-on-transfer)

    // EIP-712 domain for oracle releases
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant ORACLE_RELEASE_TYPEHASH = keccak256("OracleRelease(address token,address buyer,address seller,uint256 amount,uint64 deadline)");
    bytes32 private immutable _DOMAIN_SEPARATOR;

    // Events
    event Initialized(address token,address buyer,address seller,uint256 amount,uint64 deadline,bytes32 secretHash);
    event Funded(address indexed from,uint256 amount,address token);
    event Settled(address indexed to,uint256 netToSeller,uint256 feeTreasury,uint256 feeRef);
    event Refunded(address indexed to,uint256 refunded);
    event Disputed(address indexed by);
    event Paused(bool on);
    event SellerBondPosted(uint128 amount);
    event BuyerBondPosted(uint128 amount);
    event SecretReleased(bytes32 preimage);

    // Errors
    error NotFactory(); error AlreadyInit(); error BadParams(); error NotBuyer(); error NotSeller();
    error NotReady(); error TooEarly(); error TooLate(); error PausedErr(); error BadTokenReceipt();

    modifier onlyBuyer(){ if(msg.sender!=buyer) revert NotBuyer(); _; }
    modifier onlySeller(){ if(msg.sender!=seller) revert NotSeller(); _; }
    modifier onlyFactory(){ if(msg.sender!=factory) revert NotFactory(); _; }
    modifier whenNotPaused(){ if(paused) revert PausedErr(); _; }

    constructor(){
        factory = msg.sender;
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("DTRA_Escrow")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function getOracles() external view returns (address[] memory) { return oracles; }
    function domainSeparator() external view returns (bytes32) { return _DOMAIN_SEPARATOR; }

    function initialize(
        address _token,
        address _buyer,
        address _seller,
        uint256 _amount,
        uint64  _deadline,
        uint96  _feeBps,
        address _feeRecipient,
        uint96  _refFeeBps,
        address _refRecipient,
        bytes32 _secretHash,
        uint128 _sellerBondHBAR,
        uint128 _buyerBondHBAR,
        address[] calldata _oracles,
        uint8 _oracleQuorum
    ) external onlyFactory {
        if (initialized) revert AlreadyInit();
        if (_feeBps + _refFeeBps > MAX_FEE_BPS) revert BadParams();
        if (_deadline <= uint64(block.timestamp + 1 hours)) revert BadParams();
        if (_oracleQuorum > _oracles.length) revert BadParams();
        token=_token; buyer=_buyer; seller=_seller; amount=_amount; deadline=_deadline;
        feeBps=_feeBps; feeRecipient=_feeRecipient; refFeeBps=_refFeeBps; refRecipient=_refRecipient;
        secretHash=_secretHash; sellerBondHBAR=_sellerBondHBAR; buyerBondHBAR=_buyerBondHBAR;
        oracles=_oracles; oracleQuorum=_oracleQuorum; initialized=true;
        emit Initialized(token,buyer,seller,amount,deadline,secretHash);
    }

    // ───────────────────────── Circuit Breaker ─────────────────────────
    function setPaused(bool on) external onlyFactory { paused = on; emit Paused(on); }

    // ───────────────────────────── Funding ─────────────────────────────
    function fundHBAR() external payable nonReentrant onlyBuyer whenNotPaused {
        require(token==address(0), "ASSET!=HBAR");
        require(!funded && !settled, "ALREADY");
        require(msg.value==amount, "AMOUNT");
        funded=true; fundedAmount = msg.value;
        emit Funded(msg.sender, msg.value, address(0));
    }

    function fundToken() public nonReentrant onlyBuyer whenNotPaused {
        require(token!=address(0), "ASSET!=TOKEN");
        require(!funded && !settled, "ALREADY");
        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBal = IERC20(token).balanceOf(address(this));
        uint256 received = afterBal - beforeBal;
        fundedAmount = received;
        require(received >= amount, "RECEIVED<amount");
        funded=true; emit Funded(msg.sender, received, token);
    }

    // Permit funding (if ERC-20 implements EIP-2612)
    function fundTokenWithPermit(
        uint256 value,
        uint256 permitDeadline,
        uint8 v, bytes32 r, bytes32 s
    ) external onlyBuyer whenNotPaused {
        require(token!=address(0), "ASSET!=TOKEN");
        IERC20Permit(token).permit(buyer, address(this), value, permitDeadline, v, r, s);
        require(value >= amount, "PERMIT<VALUE");
        fundToken();
    }

    // Optional bonds
    function postSellerBond() external payable onlySeller whenNotPaused { require(msg.value==sellerBondHBAR, "SBOND"); emit SellerBondPosted(uint128(msg.value)); }
    function postBuyerBond()  external payable onlyBuyer  whenNotPaused { require(msg.value==buyerBondHBAR,  "BBOND"); emit BuyerBondPosted(uint128(msg.value)); }

    // ───────────────────────────── Releases ─────────────────────────────
    function confirmAndRelease() external nonReentrant onlyBuyer whenNotPaused { _requireReady(); settled=true; _payout(); }

    // HTLC release via preimage (works with off-chain BTC/ETH HTLCs)
    function releaseWithSecret(bytes32 preimage) external nonReentrant whenNotPaused {
        _requireReady();
        require(secretHash!=bytes32(0), "NO_HASH");
        require(keccak256(abi.encodePacked(preimage))==secretHash, "BAD_SECRET");
        settled=true; emit SecretReleased(preimage); _payout();
    }

    // EIP-712 oracle quorum release
    function oracleRelease(bytes[] calldata sigs) external nonReentrant whenNotPaused {
        _requireReady(); require(oracleQuorum>0, "NO_ORACLES");
        bytes32 structHash = keccak256(abi.encode(
            ORACLE_RELEASE_TYPEHASH,
            token, buyer, seller, amount, deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));
        uint256 votes; address[] memory cache = oracles;
        for (uint256 i=0;i<sigs.length;i++){
            address sgn = ECDSA.recover(digest, sigs[i]);
            for (uint256 j=0;j<cache.length;j++){ if (sgn==cache[j]) { votes++; break; } }
        }
        require(votes>=oracleQuorum, "QUORUM");
        settled=true; _payout();
    }

    function openDispute() external whenNotPaused { _requireReady(); if(block.timestamp>deadline) revert TooLate(); disputed=true; emit Disputed(msg.sender); }

    // Timeout refund after deadline if not settled (buyer recovers principal; seller bond → buyer)
    function timeoutRefund() external nonReentrant whenNotPaused {
        if(block.timestamp<=deadline) revert TooEarly(); _requireReady();
        settled=true; _refund();
    }

    // ───────────────────── Internal payout/refund ─────────────────────
    function _payout() internal {
        // Fees
        uint256 feeT = feeRecipient!=address(0) && feeBps>0 ? (amount*feeBps)/10_000 : 0;
        uint256 feeR = refRecipient!=address(0) && refFeeBps>0 ? (amount*refFeeBps)/10_000 : 0;
        uint256 net  = amount - feeT - feeR;

        if (token==address(0)) {
            if (feeT>0) _safeHBAR(feeRecipient, feeT);
            if (feeR>0) _safeHBAR(refRecipient, feeR);
            _safeHBAR(seller, net);
        } else {
            IERC20 t = IERC20(token);
            if (feeT>0) t.safeTransfer(feeRecipient, feeT);
            if (feeR>0) t.safeTransfer(refRecipient, feeR);
            t.safeTransfer(seller, net);
        }
        if (buyerBondHBAR>0) { _safeHBAR(seller, buyerBondHBAR); buyerBondHBAR=0; }
        emit Settled(seller, net, feeT, feeR);
    }

    function _refund() internal {
        if (token==address(0)) { _safeHBAR(buyer, amount); }
        else { IERC20(token).safeTransfer(buyer, amount); }
        if (sellerBondHBAR>0) { _safeHBAR(buyer, sellerBondHBAR); sellerBondHBAR=0; }
        emit Refunded(buyer, amount);
    }

    function _safeHBAR(address to, uint256 v) internal { (bool ok,)=to.call{value:v}(""); require(ok, "HBAR"); }
    function _requireReady() internal view { if(!(funded && !settled)) revert NotReady(); }

    // Safety: receive HBAR (for bonds)
    receive() external payable {}
}

// ───────────────────────────── Factory ─────────────────────────────
contract DTRAEscrowFactory {
    // Hedera HTS precompile (0x167 alias)
    address public immutable htsPrecompile; // 0x0000000000000000000000000000000000000167 on Hedera

    address public owner;
    address public feeRecipient;   // treasury (default)

    event OwnerUpdated(address indexed who);
    event FeeRecipientUpdated(address indexed who);
    event EscrowDeployed(
        address indexed escrow,
        bytes32 indexed salt,
        address token,
        address buyer,
        address seller,
        uint256 amount,
        uint64  deadline
    );
    event EscrowPaused(address indexed escrow, bool on);
    event EscrowDissociated(address indexed escrow, address token, int64 rc);

    error NotOwner();

    constructor(address _htsPrecompile, address _feeRecipient){
        owner = msg.sender; htsPrecompile=_htsPrecompile; feeRecipient=_feeRecipient;
    }

    modifier onlyOwner(){ if(msg.sender!=owner) revert NotOwner(); _; }

    function setOwner(address n) external onlyOwner { owner = n; emit OwnerUpdated(n); }
    function setFeeRecipient(address f) external onlyOwner { feeRecipient = f; emit FeeRecipientUpdated(f); }

    // Bytecode and deterministic address helpers
    function escrowBytecode() public pure returns(bytes memory){ return type(DTRAEscrow).creationCode; }
    function computeEscrowAddress(bytes32 salt) public view returns(address){
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(escrowBytecode())));
        return address(uint160(uint256(hash)));
    }

    // Deploy & initialize, then associate to token if HTS‑mapped ERC-20
    function deployEscrow(
        bytes32 salt,
        address token,
        address buyer,
        address seller,
        uint256 amount,
        uint64  deadline,
        uint96  feeBps,
        uint96  refFeeBps,
        address refRecipient,
        bytes32 secretHash,
        uint128 sellerBondHBAR,
        uint128 buyerBondHBAR,
        address[] calldata oracles,
        uint8 oracleQuorum
    ) external onlyOwner returns(address esc){
        bytes memory code = escrowBytecode();
        assembly { esc := create2(0, add(code,0x20), mload(code), salt) }
        require(esc!=address(0), "CREATE2");

        DTRAEscrow(esc).initialize(
            token, buyer, seller, amount, deadline,
            feeBps, feeRecipient,
            refFeeBps, refRecipient,
            secretHash, sellerBondHBAR, buyerBondHBAR,
            oracles, oracleQuorum
        );

        if (token!=address(0)) {
            int64 rc = IHederaTokenService(htsPrecompile).associateToken(esc, token);
            require(rc == int64(22) /* SUCCESS */, "ASSOC");
            emit EscrowDissociated(address(0), address(0), rc); // marker of association success (rc==22)
        }

        emit EscrowDeployed(esc, salt, token, buyer, seller, amount, deadline);
    }

    // Pause/unpause an escrow (circuit breaker)
    function setEscrowPaused(address esc, bool on) external onlyOwner {
        DTRAEscrow(esc).setPaused(on); emit EscrowPaused(esc, on);
    }

    // After settlement and zero balances, free the association slot (optional hygiene)
    function dissociateEscrowToken(address esc, address token) external onlyOwner {
        int64 rc = IHederaTokenService(htsPrecompile).dissociateToken(esc, token);
        emit EscrowDissociated(esc, token, rc);
    }
}

/* ───────────────────────────── Usage Notes ─────────────────────────────
1) Deploy Factory on Hedera:
   new DTRAEscrowFactory(0x0000000000000000000000000000000000000167, TREASURY)

2) For each marketplace offerId, compute a salt and deploy:
   bytes32 salt = keccak256(abi.encodePacked("DTRA:", offerId));
   address escrow = factory.deployEscrow(
     salt,
     token /* address(0)=HBAR or HTS‑mapped ERC‑20 (DTRA/wBTC/wETH) */,
     buyer, seller,
     amount, deadline,
     feeBps, refFeeBps, refRecipient,
     secretHash /* keccak256(preimage) or 0x0 */,
     sellerBondHBAR, buyerBondHBAR,
     oracles, oracleQuorum
   );

3) Funding
   • HBAR: buyer calls escrow.fundHBAR() with exact value
   • Token: buyer approves + calls escrow.fundToken()
   • Token w/ PERMIT: buyer calls escrow.fundTokenWithPermit(...)
   • Optional bonds in HBAR: postSellerBond()/postBuyerBond()

4) Release paths
   A) Buyer happy‑path: confirmAndRelease()
   B) HTLC: releaseWithSecret(preimage) – pair with BTC/ETH HTLC using same hash
   C) Oracles: oracleRelease(signatures[]) – EIP‑712 signatures bind chainId/escrow/terms
   D) Timeout: timeoutRefund() after deadline – principal → buyer; sellerBond → buyer

5) HTS association
   • Factory associates escrow to the token on deployment; caller must ensure buyer & seller accounts
     themselves are associated to that HTS token, as required by Hedera.

6) Security defaults
   • Reentrancy guard across state‑changing entry points
   • Strict single‑use settlement; amount & token immutable per escrow
   • Circuit breaker to freeze an escrow if needed (owner via factory)
   • Fee cap (<=20%) across treasury+referrer

7) BTC/ETH atomic pattern (sketch)
   • Buyer funds a BTC/ETH HTLC with hash=H and timeout=T1; deploy Hedera escrow with same H, deadline>=T1
   • Seller redeems BTC/ETH by revealing the preimage S; anyone can call releaseWithSecret(S) on Hedera escrow
   • If BTC/ETH HTLC refunds instead, wait until Hedera deadline and call timeoutRefund()
*/

