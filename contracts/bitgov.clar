;; Title: BitGov Protocol

;; Summary
;; BitGov Protocol is a next-generation Bitcoin Layer 2 governance platform that empowers 
;; the Bitcoin community through intelligent consensus mechanisms and transparent decision-making. 
;; By leveraging the security of Bitcoin through Stacks Layer 2, BitGov creates a democratic 
;; ecosystem where stakeholders can influence protocol development while earning rewards for 
;; their participation and commitment to Bitcoin's future.

;; Description
;; BitGov Protocol represents the evolution of decentralized governance, specifically designed 
;; for Bitcoin's expanding ecosystem. Built on the robust foundation of Stacks Layer 2, the 
;; protocol introduces a sophisticated framework where Bitcoin enthusiasts, developers, and 
;; institutions can actively shape the future of Bitcoin-based applications and protocols.
;;
;; Key Features:
;; - Time-weighted staking system with progressive reward tiers
;; - Democratic proposal system with anti-manipulation safeguards
;; - Transparent voting mechanisms based on stake commitment
;; - Emergency governance protocols for critical network decisions
;; - Multi-tier access system promoting long-term Bitcoin alignment
;; - Automated reward distribution incentivizing genuine participation
;;
;; The protocol serves Bitcoin maximalists, DeFi builders, and institutional players seeking 
;; to participate in Bitcoin's governance layer. Through cryptoeconomic incentives and 
;; time-locked commitments, BitGov ensures that decision-making power correlates with genuine 
;; long-term investment in Bitcoin's success, maintaining the network's core values of 
;; decentralization, security, and sound monetary policy.

;; TOKEN DEFINITIONS

(define-fungible-token ANALYTICS-TOKEN u0)

;; CONSTANTS & ERROR CODES

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-INVALID-PROTOCOL (err u1001))
(define-constant ERR-INVALID-AMOUNT (err u1002))
(define-constant ERR-INSUFFICIENT-STX (err u1003))
(define-constant ERR-COOLDOWN-ACTIVE (err u1004))
(define-constant ERR-NO-STAKE (err u1005))
(define-constant ERR-BELOW-MINIMUM (err u1006))
(define-constant ERR-PAUSED (err u1007))

;; DATA VARIABLES

(define-data-var contract-paused bool false)
(define-data-var emergency-mode bool false)
(define-data-var stx-pool uint u0)
(define-data-var base-reward-rate uint u500)        ;; 5% base rate (100 = 1%)
(define-data-var bonus-rate uint u100)              ;; 1% bonus for longer staking
(define-data-var minimum-stake uint u1000000)       ;; Minimum stake amount
(define-data-var cooldown-period uint u1440)        ;; 24 hour cooldown in blocks
(define-data-var proposal-count uint u0)

;; DATA MAPS

(define-map Proposals
    { proposal-id: uint }
    {
        creator: principal,
        description: (string-utf8 256),
        start-block: uint,
        end-block: uint,
        executed: bool,
        votes-for: uint,
        votes-against: uint,
        minimum-votes: uint
    }
)

(define-map UserPositions
    principal
    {
        total-collateral: uint,
        total-debt: uint,
        health-factor: uint,
        last-updated: uint,
        stx-staked: uint,
        analytics-tokens: uint,
        voting-power: uint,
        tier-level: uint,
        rewards-multiplier: uint
    }
)

(define-map StakingPositions
    principal
    {
        amount: uint,
        start-block: uint,
        last-claim: uint,
        lock-period: uint,
        cooldown-start: (optional uint),
        accumulated-rewards: uint
    }
)

(define-map TierLevels
    uint
    {
        minimum-stake: uint,
        reward-multiplier: uint,
        features-enabled: (list 10 bool)
    }
)

;; PRIVATE FUNCTIONS

;; Determines user tier based on total staked amount
(define-private (get-tier-info (stake-amount uint))
    (if (>= stake-amount u10000000)
        {tier-level: u3, reward-multiplier: u200}    ;; Diamond tier: 10M+ STX
        (if (>= stake-amount u5000000)
            {tier-level: u2, reward-multiplier: u150} ;; Gold tier: 5M+ STX
            {tier-level: u1, reward-multiplier: u100} ;; Silver tier: 1M+ STX
        )
    )
)

;; Calculates time-lock bonus multiplier for staking rewards
(define-private (calculate-lock-multiplier (lock-period uint))
    (if (>= lock-period u8640)      ;; 2 months lock period
        u150                        ;; 1.5x multiplier bonus
        (if (>= lock-period u4320)  ;; 1 month lock period
            u125                    ;; 1.25x multiplier bonus
            u100                    ;; No lock, base multiplier
        )
    )
)

;; Computes staking rewards based on user position and block progression
(define-private (calculate-rewards (user principal) (blocks uint))
    (let
        (
            (staking-position (unwrap! (map-get? StakingPositions user) u0))
            (user-position (unwrap! (map-get? UserPositions user) u0))
            (stake-amount (get amount staking-position))
            (base-rate (var-get base-reward-rate))
            (multiplier (get rewards-multiplier user-position))
        )
        ;; Formula: (stake * rate * multiplier * blocks) / normalization_factor
        (/ (* (* (* stake-amount base-rate) multiplier) blocks) u14400000)
    )
)

;; Validates proposal description meets platform standards
(define-private (is-valid-description (desc (string-utf8 256)))
    (and 
        (>= (len desc) u10)    ;; Minimum 10 characters
        (<= (len desc) u256)   ;; Maximum 256 characters
    )
)

;; Ensures lock period matches predefined options
(define-private (is-valid-lock-period (lock-period uint))
    (or 
        (is-eq lock-period u0)      ;; No lock period
        (is-eq lock-period u4320)   ;; 1 month (30 days * 144 blocks/day)
        (is-eq lock-period u8640)   ;; 2 months (60 days * 144 blocks/day)
    )
)

;; Validates voting period duration for governance proposals
(define-private (is-valid-voting-period (period uint))
    (and 
        (>= period u100)       ;; Minimum ~16 hours
        (<= period u2880)      ;; Maximum ~20 days
    )
)

;; PUBLIC FUNCTIONS

;; Initializes contract with tier system configuration
(define-public (initialize-contract)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        
        ;; Configure Silver tier (Entry level)
        (map-set TierLevels u1 
            {
                minimum-stake: u1000000,   ;; 1M uSTX minimum
                reward-multiplier: u100,   ;; 1x base rewards
                features-enabled: (list true false false false false false false false false false)
            })
            
        ;; Configure Gold tier (Advanced features)
        (map-set TierLevels u2
            {
                minimum-stake: u5000000,   ;; 5M uSTX minimum
                reward-multiplier: u150,   ;; 1.5x rewards boost
                features-enabled: (list true true true false false false false false false false)
            })
            
        ;; Configure Diamond tier (Premium access)
        (map-set TierLevels u3
            {
                minimum-stake: u10000000,  ;; 10M uSTX minimum
                reward-multiplier: u200,   ;; 2x rewards boost
                features-enabled: (list true true true true true false false false false false)
            })
        (ok true)
    )
)

;; Stakes STX tokens with optional time-lock for enhanced rewards
(define-public (stake-stx (amount uint) (lock-period uint))
    (let
        (
            (current-position (default-to 
                {
                    total-collateral: u0,
                    total-debt: u0,
                    health-factor: u0,
                    last-updated: u0,
                    stx-staked: u0,
                    analytics-tokens: u0,
                    voting-power: u0,
                    tier-level: u0,
                    rewards-multiplier: u100
                }
                (map-get? UserPositions tx-sender)))
        )
        ;; Validation checks
        (asserts! (is-valid-lock-period lock-period) ERR-INVALID-PROTOCOL)
        (asserts! (not (var-get contract-paused)) ERR-PAUSED)
        (asserts! (>= amount (var-get minimum-stake)) ERR-BELOW-MINIMUM)
        
        ;; Execute STX transfer to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Calculate new position metrics
        (let
            (
                (new-total-stake (+ (get stx-staked current-position) amount))
                (tier-info (get-tier-info new-total-stake))
                (lock-multiplier (calculate-lock-multiplier lock-period))
            )
            
            ;; Record staking position details
            (map-set StakingPositions
                tx-sender
                {
                    amount: amount,
                    start-block: stacks-block-height,
                    last-claim: stacks-block-height,
                    lock-period: lock-period,
                    cooldown-start: none,
                    accumulated-rewards: u0
                }
            )
            
            ;; Update user profile with tier progression
            (map-set UserPositions
                tx-sender
                (merge current-position
                    {
                        stx-staked: new-total-stake,
                        tier-level: (get tier-level tier-info),
                        rewards-multiplier: (* (get reward-multiplier tier-info) lock-multiplier)
                    }
                )
            )
            
            ;; Update global STX pool tracking
            (var-set stx-pool (+ (var-get stx-pool) amount))
            (ok true)
        )
    )
)