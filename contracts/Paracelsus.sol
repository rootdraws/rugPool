// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Archivist.sol";
import "./ManaPool.sol";
import "./Undine.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Paracelsus {
    Archivist public archivist;
    ManaPool public manaPool;
    address public supswapRouter;

    uint256 public lastTransmuteTime;
    uint256 public constant WEEK = 1 weeks;

    event UndineDeployed(address indexed undineAddress, string tokenName, string tokenSymbol);

// CONSTRUCTOR | Deploy Archivist + ManaPool

    constructor(
        address _supswapRouter    // UniswapV2Router02 Testnet 0x5951479fE3235b689E392E9BC6E968CE10637A52
    ) {
        // Set Supswap Router
        supswapRouter = _supswapRouter;

        // Deploys Archivist & ManaPool with Paracelsus as their Owner
        archivist = new Archivist(address(this));
        manaPool = new ManaPool(address(this), _supswapRouter, address(archivist));
    
        // Setting weekly epochs for transmutePool()
        lastTransmuteTime = block.timestamp;
    }

// LAUNCH | createCampaign() requires sending .01 ETH to the ManaPool, and then launches an Undine Contract.
    
    function createCampaign(
        string memory tokenName,   // Name of Token Launched
        string memory tokenSymbol  // Symbol of Token Launched
    ) public payable {
        require(msg.value == 0.01 ether, "Must deposit 0.01 ETH to ManaPool to invoke an Undine.");
        
        // Send ETH to ManaPool - assuming ManaPool has a deposit function to receive ETH.
        manaPool.deposit{value: msg.value}();
        
        // New Undine Deployed
        Undine newUndine = new Undine(
            tokenName,
            tokenSymbol,
            supswapRouter,
            address(archivist),
            address(manaPool),
            address(this)
        );

        // Transfer ownership of the new Undine to Paracelsus
        address newUndineAddress = address(newUndine);
        newUndine.transferOwnership(address(this));

        // Initial placeholders for campaign settings
        address lpTokenAddress = address(0); // Placeholder for LP token address, to be updated after LP creation
        uint256 amountRaised = 0;            // Initial amount raised, will be updated as contributions are received

        // Campaign Duration setup
        uint256 startTime = block.timestamp;                 // Campaign starts immediately
        uint256 duration = 1 days;                           // Campaign concludes in 24 hours
        uint256 endTime = startTime + duration;
        uint256 startClaim = endTime;                        // Claim starts immediately after campaign ends
        uint256 claimDuration = 5 days;                      // Claim window lasts for 5 days
        uint256 endClaim = startClaim + claimDuration; 

        // Register the new campaign with Archivist
        archivist.registerCampaign(newUndineAddress, tokenName, tokenSymbol, lpTokenAddress, amountRaised, startTime, endTime, startClaim, endClaim);

        // Emit an event for the new campaign creation
        emit UndineDeployed(newUndineAddress, tokenName, tokenSymbol);
    }


// TRIBUTE |  Contribute ETH to Undine
    function tribute(address undineAddress, uint256 amount) public payable {
        require(msg.value == amount, "Sent ETH does not match the specified amount.");
        require(archivist.isCampaignActive(undineAddress), "The campaign is not active or has concluded.");

        // Assuming Undine has a deposit function to explicitly receive and track ETH
        Undine undineContract = Undine(undineAddress);

        // Forward the ETH to the Undine contract
        (bool sent,) = address(undineContract).call{value: msg.value}(
            abi.encodeWithSelector(Undine.deposit.selector)
        );
        require(sent, "Failed to send Ether to Undine.");

        // Archivist is updated on Individual Contribution Amount, and total Contributed for Campaign
        archivist.addContribution(undineAddress, msg.sender, amount);
    }

    
// LIQUIDITY | Create Univ2 LP to be Held by Undine
   function invokeLP(address undineAddress) external {
        require(archivist.isCampaignConcluded(undineAddress), "Campaign is still active.");
        require(archivist.isLPInvoked(undineAddress), "Campaign already has Invoked LP.");

        // Forms LP from Entire Balance of ETH and ERC20 held by Undine [50% of Supply]
        IUndine(undineAddress).invokeLiquidityPair();

        // Pull LP Address from Undine via Supswap Factory
        address lpTokenAddress = IUndine(undineAddress).archiveLP();

        // Update Archivist with the LP Address for Campaign[]
        archivist.archiveLPAddress(undineAddress, lpTokenAddress);

        // In closure, this function can only be called once per undineAddress.
    }

// CLAIM | Claim tokens held by ManaPool

    function claimMembership(address undineAddress) public {
        // Check if the claim window is active
        require(archivist.isClaimWindowActive(undineAddress), "Claim window is not active.");

        // Calculate claim amount using Archivist
        archivist.calculateClaimAmount(undineAddress, msg.sender);

        // Retrieve the claim amount from Archivist
        uint256 claimAmount = archivist.contributions[undineAddress][msg.sender].claimAmount;

        // Ensure the claim amount is greater than 0
        require(claimAmount > 0, "Claim amount must be greater than 0.");

        // Transfer the claimed tokens from ManaPool to the contributor
        manaPool.claimTokens(msg.sender, undineAddress, claimAmount);

        // Reset the claim amount in Archivist
        archivist.resetClaimAmount(undineAddress, msg.sender);

        // In closure, this function can only be called once per undineAddress.
    }

// LP REWARDS | Function can be called once per Epoch.

   function triggerTransmutePool() external {
        require(block.timestamp >= lastTransmuteTime + WEEK, "Cooldown period has not passed.");

        manaPool.transmutePool();

        // Update the lastTransmuteTime to the current timestamp
        lastTransmuteTime = block.timestamp;
    }

}
