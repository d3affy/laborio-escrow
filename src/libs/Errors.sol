// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Group errors under a namespace-like library to avoid global collisions
library Errors {
    error NotClient();
    error NotArbitrator();
    error WrongState();
    error ZeroAddress();
    error AmountMismatch();
    error Paused();
    error TokenNotAllowed();
    // Milestone-specific errors
    error InvalidMilestoneId();
    error InvalidMilestoneCount();
    error BudgetMismatch();
    error InsufficientFunding();
    error AmountTooSmall();
    error ExceedsRemaining();
    error NotInReview();
    error AlreadySubmitted();
    error TooManyPartials();
}
