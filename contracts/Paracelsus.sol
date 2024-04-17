// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Archivist.sol";
import "./ManaPool.sol";
import "./Undine.sol";
import "./Salamander.sol";
import "./EpochManager.sol";

contract Paracelsus {
    Archivist public archivist;
    ManaPool public manaPool;
    Salamander public salamander;
    EpochManager public epochManager;
    address public supswapRouter;

// EVENTS
    event UndineDeployed(address indexed undineAddress, string tokenName, string tokenSymbol);
    event TributeMade(address indexed undineAddress, address indexed contributor, uint256 amount);
    event LPPairInvoked(address indexed undineAddress, address lpTokenAddress);
    event MembershipClaimed(address indexed claimant, address indexed undineAddress, uint256 claimAmount);

// CONSTRUCTOR
    constructor(
        address _supswapRouter
    ) {
        // Set Supswap Router
        supswapRouter = _supswapRouter;

        // Deploys Archivist | ManaPool | Salamander | EpochManager with Paracelsus as their Owner
        epochManager = new EpochManager(address(this));
        archivist = new Archivist(address(this), address(epochManager));
        manaPool = new ManaPool(address(this), _supswapRouter, address(epochManager), address(archivist));
        salamander = new Salamander(address(this), address(epochManager), address(archivist), address(manaPool));
        
        // Sets Addresses for Archivist | ManaPool & Salamander
        Archivist(address(archivist)).setManaPool(address(manaPool));
        Archivist(address(archivist)).setSalamander(address(salamander));
        
        // Sets Address for ManaPool | Salamander
        ManaPool(address(manaPool)).setSalamander(address(salamander));
    
    }

// LAUNCH | createCampaign() requires sending .01 ETH to the ManaPool, and then launches an Undine Contract.
    
    function createCampaign(
        string memory tokenName,   // Name of Token Launched
        string memory tokenSymbol  // Symbol of Token Launched
    ) public payable {
        require(msg.value == 0.01 ether, "Must deposit 0.01 ETH to ManaPool to invoke an Undine.");
        
        // Send ETH to ManaPool for Launch Fee
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

        // Event
        emit UndineDeployed(newUndineAddress, tokenName, tokenSymbol);
    }


// TRIBUTE |  Contribute ETH to Undine
    function tribute(address undineAddress, uint256 amount) public payable {
        require(msg.value == amount, "Sent ETH does not match the specified amount.");
        require(archivist.isCampaignActive(undineAddress), "The campaign is not active or has concluded.");

        // Assuming Undine has a deposit function to explicitly receive and track ETH
        Undine undineContract = Undine(undineAddress);

        // Send ETH to Undine
        undineContract.deposit{value: msg.value}();

        // Archivist is updated on Contribution amount for [Individual | Campaign | Total]
        archivist.addContribution(undineAddress, msg.sender, amount);
    
        // Event
        emit TributeMade(undineAddress, msg.sender, amount);
    }

    
// LIQUIDITY | Create Univ2 LP to be Held by Undine || Call invokeLP() once per Undine.
   function invokeLP(address undineAddress) external {
        require(archivist.isCampaignConcluded(undineAddress), "Campaign is still active.");
        require(archivist.isLPInvoked(undineAddress), "Campaign already has Invoked LP.");

        // Forms LP from Entire Balance of ETH and ERC20 held by Undine [50% of Supply]
        Undine(undineAddress).invokeLiquidityPair();

        // Pull LP Address from Undine via Supswap Factory
        address lpTokenAddress = Undine(undineAddress).archiveLP();

        // Update Archivist with the LP Address for Campaign[]
        archivist.archiveLPAddress(undineAddress, lpTokenAddress);

         // Event
        emit LPPairInvoked(undineAddress, lpTokenAddress);
    }

// CLAIM | Claim tokens held by ManaPool
    // Tokens Forfeit to ManaPool after Claim Period.
    // Call claimMembership() once per Campaign | per Member.
    
  
    function claimMembership(address undineAddress) public {
        // Check if the claim window is active
        require(archivist.isClaimWindowActive(undineAddress), "Claim window is not active.");

        // Calculate claim amount using Archivist
        archivist.calculateClaimAmount(undineAddress, msg.sender);

        // Retrieve the claim amount using the new getter function
        uint256 claimAmount = archivist.getClaimAmount(undineAddress, msg.sender);

        // Ensure the claim amount is greater than 0
        require(claimAmount > 0, "Claim amount must be greater than 0.");

        // Transfer the claimed tokens from ManaPool to the contributor
        manaPool.claimTokens(msg.sender, undineAddress, claimAmount);

        // Reset the claim amount in Archivist
        archivist.resetClaimAmount(undineAddress, msg.sender);

        // Emit event
        emit MembershipClaimed(msg.sender, undineAddress, claimAmount);
    }

// LP REWARDS | Function can be called once per Epoch | Epoch is defined as one week.

   function triggerTransmutePool() external {
        // First check if it's allowed to trigger a new epoch
        require(epochManager.isTransmuteAllowed(), "Cooldown period has not passed.");

        // Sells 1% of ManaPool into ETH to be Distributed to Undines
        manaPool.transmutePool();

        // Calculate the Vote Impact Per Salamander
        // Calculates the Distribution Amounts per Undine || To Be Edited to Include Voting Escrow
        manaPool.updateRewardsBasedOnBalance();

        // Update the epoch in the EpochManager
        epochManager.updateEpoch();
    }
// veNFT

    // LOCK Tokens from any UNDINE for 1 Year, and gain Curation Rights
    function lockVeNFT(ERC20 token, uint256 amount) external {
        salamander.lockTokens(token, amount);
    }

    // UNLOCK Tokens and Burn your veNFT after 1 Year
    function unlockVeNFT(uint256 tokenId) external {
        salamander.unlockTokens(tokenId);
    }

    // TODO: VOTE FUNCTION 
}
