# Master Registry Contract

## Overview

The Master Registry is the central contract of the ms2.fun launchpad ecosystem. It manages factory applications, instance registration, and featured promotions.

## Key Features

### Factory Application System

1. **Application Submission**: Factory creators submit applications with ETH fee
2. **Voting**: EXEC token holders vote on applications (weighted by balance)
3. **Finalization**: Admin finalizes approved applications
4. **Registration**: Approved factories are registered with unique IDs

### Instance Tracking

- Register instances deployed by factories
- Track creator, metadata, and registration time
- Prevent name collisions

### Dynamic Pricing

- Supply and demand-based pricing
- Multiple tiers (top 20 featured spots)
- Automatic price discovery

## Functions

### applyForFactory

Submit a factory application with required metadata and features.

### voteOnApplication

Cast a vote on a pending application (EXEC holders only).

### finalizeApplication

Finalize an application after voting period (admin only).

### registerInstance

Register a new instance (called by registered factories).

### purchaseFeaturedPromotion

Purchase a featured promotion slot for an instance.

