#@version 0.2.5

# TODO: Add ETH Configuration
# TODO: Add Delegated Configuration
from vyper.interfaces import ERC20

implements: ERC20

interface DetailedERC20:
    def name() -> String[42]: view
    def symbol() -> String[20]: view
    def decimals() -> uint256: view

interface Strategy:
    def strategist() -> address: view
    def estimatedTotalAssets() -> uint256: view
    def migrate(_newStrategy: address): nonpayable

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256


name: public(String[64])
symbol: public(String[32])
decimals: public(uint256)

balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])
totalSupply: public(uint256)

token: public(ERC20)
governance: public(address)
guardian: public(address)
pendingGovernance: address

struct StrategyParams:
    performanceFee: uint256  # Strategist's fee (basis points)
    activation: uint256  # Activation block.number
    debtLimit: uint256  # Maximum borrow amount
    rateLimit: uint256  # Increase/decrease per block
    lastReport: uint256  # block.number of the last time a report occured
    totalDebt: uint256  # Total outstanding debt that Strategy has
    totalReturns: uint256  # Total returns that Strategy has realized for Vault

event StrategyUpdate:
    strategy: indexed(address)
    returnAdded: uint256
    debtAdded: uint256
    totalReturn: uint256
    totalDebt: uint256
    debtLimit: uint256

# NOTE: Track the total for overhead targeting purposes
strategies: public(HashMap[address, StrategyParams])
MAXIMUM_STRATEGIES: constant(uint256) = 20

emergencyShutdown: public(bool)

debtLimit: public(uint256)  # Debt limit for the Vault across all strategies
debtChangeLimit: public(decimal)  # Amount strategy debt limit can change based on return profile
totalDebt: public(uint256)  # Amount of tokens that all strategies have borrowed

rewards: public(address)
performanceFee: public(uint256)  # Fee for governance rewards
FEE_MAX: constant(uint256) = 10000  # 100%, or 10000 basis points

@external
def __init__(_token: address, _governance: address, _rewards: address):
    # TODO: Non-detailed Configuration?
    self.token = ERC20(_token)
    self.name = concat("yearn ", DetailedERC20(_token).name())
    self.symbol = concat("y", DetailedERC20(_token).symbol())
    self.decimals = DetailedERC20(_token).decimals()
    self.governance = _governance
    self.rewards = _rewards
    self.guardian = msg.sender
    self.performanceFee = 450  # 4.5% of yield (per strategy)
    self.debtLimit = ERC20(_token).totalSupply() / 1000  # 0.1% of total supply of token
    self.debtChangeLimit =  0.005  # up to +/- 0.5% change allowed for strategy debt limits


# 2-phase commit for a change in governance
@external
def setGovernance(_governance: address):
    assert msg.sender == self.governance
    self.pendingGovernance = _governance


@external
def acceptGovernance():
    assert msg.sender == self.pendingGovernance
    self.governance = msg.sender


@external
def setRewards(_rewards: address):
    assert msg.sender == self.governance
    self.rewards = _rewards


@external
def setDebtLimit(_limit: uint256):
    assert msg.sender == self.governance
    self.debtLimit = _limit


@external
def setDebtChangeLimit(_limit: decimal):
    assert msg.sender == self.governance
    self.debtChangeLimit = _limit


@external
def setPerformanceFee(_fee: uint256):
    assert msg.sender == self.governance
    self.performanceFee = _fee


@external
def setGuardian(_guardian: address):
    assert msg.sender in [self.guardian, self.governance]
    self.guardian = _guardian


@external
def setEmergencyShutdown(_active: bool):
    """
    Activates Vault mode where all Strategies go into full withdrawal
    """
    assert msg.sender in [self.guardian, self.governance]
    self.emergencyShutdown = _active


@internal
def _transfer(_from: address, _to: address, _value: uint256):
    # Protect people from accidentally sending their shares to bad places
    assert not (_to in [self, ZERO_ADDRESS])
    self.balanceOf[_from] -= _value
    self.balanceOf[_to] += _value
    log Transfer(_from, _to, _value)


@external
def transfer(_to: address, _value: uint256) -> bool:
    self._transfer(msg.sender, _to, _value)
    return True


@external
def transferFrom(_from : address, _to : address, _value : uint256) -> bool:
    if self.allowance[_from][msg.sender] < MAX_UINT256:  # Unlimited approval (saves an SSTORE)
       self.allowance[_from][msg.sender] -= _value
    self._transfer(_from, _to, _value)
    return True


@external
def approve(_spender : address, _value : uint256) -> bool:
    """
    @dev Approve the passed address to spend the specified amount of tokens on behalf of
         msg.sender. Beware that changing an allowance with this method brings the risk
         that someone may use both the old and the new allowance by unfortunate transaction
         ordering. One possible solution to mitigate this race condition is to first reduce
         the spender's allowance to 0 and set the desired value afterwards:
         https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    @param _spender The address which will spend the funds.
    @param _value The amount of tokens to be spent.
    """
    assert _value == 0 or self.allowance[msg.sender][_spender] == 0
    self.allowance[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    return True


@view
@internal
def _totalAssets() -> uint256:
    return self.token.balanceOf(self) + self.totalDebt


@view
@external
def totalAssets() -> uint256:
    return self._totalAssets()


@view
@internal
def _balanceSheetOfStrategy(_strategy: address) -> uint256:
    return Strategy(_strategy).estimatedTotalAssets()


@view
@external
def balanceSheetOfStrategy(_strategy: address) -> uint256:
    return self._balanceSheetOfStrategy(_strategy)


@view
@external
def totalBalanceSheet(_strategies: address[2 * MAXIMUM_STRATEGIES]) -> uint256:
    """
    Measure the total balance sheet of this Vault, using the list of strategies
    given above. (2x the expected maximum is used for safety's sake)
    NOTE: The safety of this function depends *entirely* on the list of strategies
          given as the function argument. Care should be taken to choose this list
          to ensure that the estimate is accurate. No additional checking is used.
    NOTE: Guardian should use this value vs. `totalAssets()` to determine
          if a condition exists where the Vault is experiencing a dangerous
          'balance sheet' attack, leading Vault shares to be worth less than
          what their price on paper is (based on their debt)
    """
    balanceSheet: uint256 = self.token.balanceOf(self)

    for strategy in _strategies:
        if strategy == ZERO_ADDRESS:
            break
        balanceSheet += self._balanceSheetOfStrategy(strategy)

    return balanceSheet


@internal
def _issueSharesForAmount(_to: address, _amount: uint256) -> uint256:
    # NOTE: shares must be issued prior to taking on new collateral,
    #       or calculation will be wrong. This means that only *trusted*
    #       tokens (with no capability for exploitive behavior) can be used
    shares: uint256 = 0
    if self.totalSupply > 0:
        # Mint amount of shares based on what the Vault is managing overall
        shares = _amount * self.totalSupply / self._totalAssets()
    else:
        # No existing shares, so mint 1:1
        shares = _amount

    # Mint new shares
    self.totalSupply += shares
    self.balanceOf[_to] += shares
    log Transfer(ZERO_ADDRESS, _to, shares)

    return shares


@external
def deposit(_amount: uint256) -> uint256:
    assert not self.emergencyShutdown  # Deposits are locked out

    # NOTE: Measuring this based on the total outstanding debt that this contract
    #       has ("expected value") instead of the total balance sheet it has
    #       ("estimated value") has important security considerations, and is
    #       done intentionally. If this value were measured against external
    #       systems, it could be purposely manipulated by an attacker to withdraw
    #       more assets than they otherwise should be able to claim by redeeming
    #       their shares.
    #
    #       On deposit, this means that shares are issued against the total amount
    #       that the deposited capital can be given in service of the debt that
    #       Strategies assume. If that number were to be lower than the "expected value"
    #       at some future point, depositing shares via this method could entitle the
    #       depositor to *less* than the deposited value once the "realized value" is
    #       updated from further reportings by the Strategies to the Vaults.
    #
    #       Care should be taken by integrators to account for this discrepency,
    #       by using the view-only methods of this contract (both off-chain and
    #       on-chain) to determine if depositing into the Vault is a "good idea"

    # Issue new shares (needs to be done before taking deposit to be accurate)
    shares: uint256 = self._issueSharesForAmount(msg.sender, _amount)

    # Get new collateral
    reserve: uint256 = self.token.balanceOf(self)
    self.token.transferFrom(msg.sender, self, _amount)
    # TODO: `Deflationary` configuration only
    assert self.token.balanceOf(self) - reserve == _amount  # Deflationary token check

    return shares  # Just in case someone wants them


@view
@internal
def _shareValue(_shares: uint256) -> uint256:
    return (_shares * (self._totalAssets())) / self.totalSupply


@view
@internal
def _maxAvailableShares() -> uint256:
    if self._totalAssets() > 0:
        return (self.token.balanceOf(self) * self.totalSupply) / self._totalAssets()
    else:
        return 0


@view
@external
def maxAvailableShares() -> uint256:
    return self._maxAvailableShares()


@external
def withdraw(_maxShares: uint256):
    # Take the lesser of _maxShares, or the "free" amount of outstanding shares
    shares: uint256 = min(_maxShares, self._maxAvailableShares())
    # NOTE: Measuring this based on the total outstanding debt that this contract
    #       has ("expected value") instead of the total balance sheet it has
    #       ("estimated value") has important security considerations, and is
    #       done intentionally. If this value were measured against external
    #       systems, it could be purposely manipulated by an attacker to withdraw
    #       more assets than they otherwise should be able to claim by redeeming
    #       their shares.
    #
    #       On withdrawal, this means that shares are redeemed against the total
    #       amount that the deposited capital had "realized" since the point it
    #       was deposited, up until the point it was withdrawn. If that number
    #       were to be higher than the "expected value" at some future point,
    #       withdrawing shares via this method could entitle the depositor to
    #       *more* than the expected value once the "realized value" is updated
    #       from further reportings by the Strategies to the Vaults.
    #
    #       Note that this risk is mitgated partially through the withdrawal fee,
    #       partially through the semi-frequent updates to the "realized value" of
    #       the Vault's assets, but is a systemic risk to users of the Vault.
    #       Under exceptional scenarios, this could cause earlier withdrawals to
    #       earn "more" of the underlying assets than Users might otherwise be
    #       entitled to, if the Vault's estimated value were otherwise measured
    #       through external means, accounting for whatever exceptional scenarios
    #       exist for the Vault (that aren't covered by the Vault's own design)
    value: uint256 = self._shareValue(shares)

    # Burn shares
    self.totalSupply -= shares
    self.balanceOf[msg.sender] -= shares
    log Transfer(msg.sender, ZERO_ADDRESS, shares)

    # Withdraw balance
    self.token.transfer(msg.sender, value)


@view
@external
def pricePerShare() -> uint256:
    return self._shareValue(10 ** self.decimals)


@external
def addStrategy(
    _strategy: address,
    _debtLimit: uint256,
    _rateLimit: uint256,
    _performanceFee: uint256,
):
    assert msg.sender == self.governance
    self.strategies[_strategy] = StrategyParams({
        performanceFee: _performanceFee,
        activation: block.number,
        debtLimit: _debtLimit,
        rateLimit: _rateLimit,
        lastReport: block.number,
        totalDebt: 0,
        totalReturns: 0,
    })
    log StrategyUpdate(_strategy, 0, 0, 0, 0, _debtLimit)


@external
def updateStrategy(
    _strategy: address,
    _debtLimit: uint256,
    _rateLimit: uint256,
    _performanceFee: uint256,
):
    assert msg.sender == self.governance
    assert self.strategies[_strategy].activation > 0
    self.strategies[_strategy].debtLimit = _debtLimit
    self.strategies[_strategy].rateLimit = _rateLimit
    self.strategies[_strategy].performanceFee = _performanceFee


@external
def migrateStrategy(_oldVersion: address, _newVersion: address):
    """
    Only Governance can migrate a strategy to a new version
    NOTE: Strategy must successfully migrate all capital and positions to
          new Strategy, or else this will upset the balance of the Vault
    NOTE: The new strategy should be "empty" e.g. have no prior commitments
          to this Vault, otherwise it could have issues
    """
    assert msg.sender == self.governance

    assert self.strategies[_oldVersion].activation > 0
    assert self.strategies[_newVersion].activation == 0

    strategy: StrategyParams = self.strategies[_oldVersion]
    self.strategies[_oldVersion] = empty(StrategyParams)
    self.strategies[_newVersion] = strategy

    Strategy(_oldVersion).migrate(_newVersion)
    # TODO: Ensure a smooth transition in terms of  strategy return


@external
def revokeStrategy(_strategy: address = msg.sender):
    """
    Governance can revoke a strategy
    OR
    A strategy can revoke itself (Emergency Exit Mode)
    """
    assert msg.sender in [_strategy, self.governance]
    self.strategies[_strategy].debtLimit = 0


@view
@internal
def _creditAvailable(_strategy: address) -> uint256:
    """
    Amount of tokens in vault a strategy has access to as a credit line
    """
    if self.emergencyShutdown:
        return 0

    strategy_debtLimit: uint256 = self.strategies[_strategy].debtLimit
    strategy_totalDebt: uint256 = self.strategies[_strategy].totalDebt
    strategy_rateLimit: uint256 = self.strategies[_strategy].rateLimit
    strategy_lastReport: uint256 = self.strategies[_strategy].lastReport

    # Exhausted credit line
    if strategy_debtLimit <= strategy_totalDebt or self.debtLimit <= self.totalDebt:
        return 0

    # Start with debt limit left for the strategy
    available: uint256 = strategy_debtLimit - strategy_totalDebt

    # Adjust by the global debt limit left
    available = min(available, self.debtLimit - self.totalDebt)

    # Adjust by the rate limit algorithm (limits the step size per reporting period)
    available = min(available, strategy_rateLimit * (block.number - strategy_lastReport))

    # Can only borrow up to what the contract has in reserve
    # NOTE: Running near 100% is discouraged
    return min(available, self.token.balanceOf(self))


@view
@external
def creditAvailable(_strategy: address = msg.sender) -> uint256:
    return self._creditAvailable(_strategy)


@view
@internal
def _expectedReturn(_strategy: address) -> uint256:
    strategy_lastReport: uint256 = self.strategies[_strategy].lastReport
    strategy_totalReturns: uint256 = self.strategies[_strategy].totalReturns
    strategy_activation: uint256 = self.strategies[_strategy].activation

    blockDelta: uint256 = (block.number - strategy_lastReport)
    if blockDelta > 0:
        return (strategy_totalReturns * blockDelta) / (block.number - strategy_activation)
    else:
        return 0  # Covers the scenario when block.number == strategy_activation


@view
@external
def expectedReturn(_strategy: address = msg.sender) -> uint256:
    return self._expectedReturn(_strategy)


@view
@internal
def _adjustedDebtLimit(
    _currDebtLimit: decimal,
    _actual: decimal,
    _expected: decimal,
) -> decimal:
    # NOTE: This works in Emergency Shutdown/Emergency Exit as well
    if _currDebtLimit == 0.0:
        return 0.0

    if _expected == 0.0:
        return _currDebtLimit

    maxRatio: decimal = 1.0 + self.debtChangeLimit
    minRatio: decimal = 1.0 - self.debtChangeLimit

    # Check if saturated first, to avoid overflow errors
    if _actual > maxRatio * _expected:
        return maxRatio * _currDebtLimit

    elif _actual < minRatio * _expected:
        return minRatio * _currDebtLimit

    else:
        return _currDebtLimit * (_actual / _expected)


@view
@external
def estimateAdjustedDebtLimit(
    _estimatedReturn: uint256,
    _strategy: address = msg.sender,
) -> uint256:
    return convert(
        self._adjustedDebtLimit(
            convert(self.strategies[_strategy].debtLimit, decimal),
            convert(_estimatedReturn, decimal),
            convert(self._expectedReturn(_strategy), decimal),
        ),
        uint256,
    )


@external
def report(_return: uint256) -> uint256:
    """
    Strategies call this.
    _return: amount Strategy has made on it's investment since its last report,
             and is free to be given back to Vault as earnings
    returns: amount of debt outstanding (iff totalDebt > debtLimit)
    """
    # NOTE: For approved strategies, this is the most efficient behavior.
    #       Strategy reports back what it has free (usually in terms of ROI)
    #       and then Vault "decides" here whether to take some back or give it more.
    #       Note that the most it can take is `_return`, and the most it can give is
    #       all of the remaining reserves. Anything outside of those bounds is abnormal
    #       behavior.
    # NOTE: All approved strategies must have increased diligience around
    #       calling this function, as abnormal behavior could become catastrophic

    # Only approved strategies can call this function
    assert self.strategies[msg.sender].activation > 0

    # Issue new shares to cover fees (if strategy is not shutting down)
    # NOTE: In effect, this reduces overall share price by the combined fee
    # NOTE: No fee is taken when a strategy is unwinding it's position
    if self.strategies[msg.sender].debtLimit > 0 and _return > 0:
        strategist_fee: uint256 = (
            _return * self.strategies[msg.sender].performanceFee
        ) / FEE_MAX
        governance_fee: uint256 = (_return * self.performanceFee) / FEE_MAX
        total_fee: uint256 = governance_fee + strategist_fee
        # NOTE: This must be called prior to taking new collateral,
        #       or the calculation will be wrong!
        # NOTE: This must be done at the same time, to ensure the relative
        #       ratio of governance_fee : strategist_fee is kept intact
        shares: uint256 = self._issueSharesForAmount(self, total_fee)

        # Send the rewards out as new shares in this Vault
        strategist_fee *= shares
        strategist_fee /= total_fee
        self._transfer(self, Strategy(msg.sender).strategist(), strategist_fee)
        # NOTE: Governance earns the dust
        self._transfer(self, self.rewards, self.balanceOf[self])

    # Adjust debt limit based on current return vs. past performance
    # NOTE: This must be called at the exact moment a return is "realized"
    self.strategies[msg.sender].debtLimit = convert(
        self._adjustedDebtLimit(
            convert(self.strategies[msg.sender].debtLimit, decimal),
            convert(_return, decimal),
            convert(self._expectedReturn(msg.sender), decimal),
        ),
        uint256,
    )

    # Compute the line of credit the Vault is able to offer the Strategy (if any)
    credit: uint256 = self._creditAvailable(msg.sender)

    # Give/take balance to Strategy, based on the difference between the return and
    # the credit increase we are offering (if any)
    # NOTE: This is just used to adjust the balance of tokens between the Strategy and
    #       the Vault based on the adjusted debt limit.
    if _return < credit:  # credit surplus, give to strategy
        self.token.transfer(msg.sender, credit - _return)
    elif _return > credit:  # credit deficit, take from strategy
        self.token.transferFrom(msg.sender, self, _return - credit)

    # else, don't do anything because it is performing well as is

    # Update the actual debt based on the full credit we are extending to the Strategy
    # or the returns if we are taking funds back
    # NOTE: credit + self.strategies[msg.sender].totalDebt is always < self.debtLimit
    if credit > 0:
        self.strategies[msg.sender].totalDebt += credit
        self.totalDebt += credit

        # Returns are always "realized gains"
        self.strategies[msg.sender].totalReturns += _return

    elif _return > 0:  # We're repaying debt now
        if _return < self.strategies[msg.sender].totalDebt:
            # Pay down our debt with profit
            # NOTE: Cannot return more than you borrowed
            self.strategies[msg.sender].totalDebt -= _return
            self.totalDebt -= _return

        else:
            # We are dealing with pure profit now
            profit: uint256 = _return - self.strategies[msg.sender].totalDebt

            # Pay off the last of our debt
            if profit < _return:  # Only happens once
                self.totalDebt -= _return - profit
                self.strategies[msg.sender].totalDebt = 0

            # Returns are always "realized gains"
            self.strategies[msg.sender].totalReturns += profit

    # else, we are perfectly in balance

    # Update reporting time
    self.strategies[msg.sender].lastReport = block.number

    log StrategyUpdate(
        msg.sender,
        _return,
        credit,
        self.strategies[msg.sender].totalReturns,
        self.strategies[msg.sender].totalDebt,
        self.strategies[msg.sender].debtLimit,
    )

    if self.strategies[msg.sender].totalDebt == 0 or self.emergencyShutdown:
        # Take every last penny the Strategy has (Emergency Exit/revokeStrategy)
        return self._balanceSheetOfStrategy(msg.sender)
    elif (
        self.strategies[msg.sender].totalDebt
        > self.strategies[msg.sender].debtLimit
    ):
        # The Strategy owes some money, so send notice
        return (
            self.strategies[msg.sender].totalDebt
            - self.strategies[msg.sender].debtLimit
        )
    else:  # Credit available, or we are running at limit
        return 0  # NOTE: Means "good to go"


@external
def sweep(_token: address):
    # Can't be used to steal what this Vault is protecting
    assert _token != self.token.address
    ERC20(_token).transfer(self.governance, ERC20(_token).balanceOf(self))


@external
def __default__():
    # No default calls
    # TODO: Vyper should automatically do this...
    raise
