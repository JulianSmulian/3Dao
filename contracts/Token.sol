// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title  3DAO Token (3DAO)
 * @notice ERC-20 token for the Digitrade / 3DAO ecosystem.
 *         Total supply: 100,000,000 3DAO (100M)
 *         Pool supply:  20,000,000  3DAO (20M) — sent once to ProposalPool
 *
 * KEY ADDITION vs original:
 *   burn(uint256 amount) — called exclusively by BuyAndBurn.sol after every
 *   completed Digitrade order. Permanently reduces totalSupply.
 */
contract Token {

    // ── State ───────────────────────────────────────────────────────────────
    string  public symbol   = "3DAO";
    string  public name     = "3DaoToken";
    uint8   public decimals = 18;

    uint256 public totalSupply;
    uint256 public poolSupply;
    bool    public poolSupplySent;

    address public consul;
    address public pool;

    /// @notice Address authorised to call burn() — set to BuyAndBurn.sol at deploy.
    address public burnOperator;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ── Events ──────────────────────────────────────────────────────────────
    event Transfer(address indexed from,  address indexed to,      uint256 tokens);
    event Approval(address indexed owner, address indexed spender, uint256 tokens);
    event Burn(address indexed burner, uint256 amount, uint256 newTotalSupply);
    event BurnOperatorSet(address indexed oldOperator, address indexed newOperator);

    // ── Modifiers ───────────────────────────────────────────────────────────
    modifier onlyConsul() {
        require(msg.sender == consul, "not consul");
        _;
    }

    modifier onlyPoolNotSent() {
        require(!poolSupplySent, "pool already funded");
        _;
    }

    modifier onlyBurnOperator() {
        require(msg.sender == burnOperator, "not burn operator");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────────
    constructor() {
        totalSupply   = 100_000_000e18;
        poolSupply    = 20_000_000e18;
        consul        = msg.sender;
        poolSupplySent = false;
        _balances[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /**
     * @notice Send the governance pool allocation to ProposalPool.sol.
     *         Can only be called once by the consul.
     * @param _pool Address of the deployed ProposalPool contract.
     */
    function activatePool(address _pool) external onlyConsul onlyPoolNotSent {
        require(_pool != address(0), "pool=0");
        pool = _pool;
        poolSupplySent = true;
        _transfer(msg.sender, _pool, poolSupply);
    }

    /**
     * @notice Set the address permitted to call burn().
     *         Should be set to BuyAndBurn.sol immediately after its deployment.
     *         Can be updated by consul before resignBlock, or by governance after.
     *         Emits BurnOperatorSet so the change is publicly auditable.
     * @param _burnOperator Address of BuyAndBurn.sol.
     */
    function setBurnOperator(address _burnOperator) external onlyConsul {
        require(_burnOperator != address(0), "burnOperator=0");
        emit BurnOperatorSet(burnOperator, _burnOperator);
        burnOperator = _burnOperator;
    }

    // ── Core burn function ───────────────────────────────────────────────────

    /**
     * @notice Permanently destroy tokens, reducing totalSupply.
     *         Called ONLY by BuyAndBurn.sol after swapping USDC for 3DAO.
     *         Tokens are sent here from BuyAndBurn, then destroyed.
     *
     * FLOW:
     *   BuyAndBurn receives 3DAO from DEX swap
     *   └─► calls Token.burn(tokensBought)
     *         └─► reduces BuyAndBurn's balance by amount
     *         └─► reduces totalSupply by amount
     *         └─► emits Burn event with new totalSupply
     *
     * @param amount Number of tokens (in wei, 18 decimals) to burn.
     */
    function burn(uint256 amount) external onlyBurnOperator {
        require(amount > 0, "burn amount=0");
        require(_balances[msg.sender] >= amount, "insufficient balance to burn");

        _balances[msg.sender] -= amount;
        totalSupply           -= amount;

        emit Burn(msg.sender, amount, totalSupply);
        emit Transfer(msg.sender, address(0), amount);
    }

    // ── ERC-20 standard ─────────────────────────────────────────────────────

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        require(spender != address(0), "approve to zero");
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_allowances[from][msg.sender] >= amount, "allowance exceeded");
        _allowances[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "transfer from zero");
        require(to   != address(0), "transfer to zero");
        require(_balances[from] >= amount, "insufficient balance");
        _balances[from] -= amount;
        _balances[to]   += amount;
        emit Transfer(from, to, amount);
    }
}
