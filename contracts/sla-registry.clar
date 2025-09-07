;; SLARegistry Smart Contract
;; Manages creation, updates, and queries for Service Level Agreements (SLAs)
;; Uses SIP-010 for token integration (penalties in SLA-TKN)

(impl-trait .trait-sip-010-token-trait.sip-010-token-trait) ;; Optional: If extending token traits, but here for reference

;; Constants
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-SLA-EXISTS (err u101))
(define-constant ERR-INVALID-TERMS (err u102))
(define-constant ERR-AMENDMENT-FAILED (err u103))
(define-constant ERR-NOT-FOUND (err u104))
(define-constant MAX-TERMS-LEN u500)
(define-constant MAX-DESCRIPTION-LEN u200)

;; Data Maps
(define-map slas
    { sla-id: (buff 32) } ;; Unique hash of SLA (e.g., SHA256 of terms + parties)
    {
        provider: principal,
        customer: principal,
        resolution-time: uint, ;; In blocks (e.g., 1440 for ~24 hours)
        penalty-rate: uint, ;; Percentage (e.g., 10 for 10%)
        max-penalties: uint, ;; Max penalty cycles before escalation
        deposit-required: uint, ;; Initial deposit in micro-SLA-TKN (SIP-010)
        terms-hash: (buff 32), ;; IPFS/SHA256 of detailed terms
        description: (string-ascii MAX-DESCRIPTION-LEN),
        created-at: uint,
        active: bool
    }
)

(define-map sla-parties
    { sla-id: (buff 32), party: principal }
    {
        role: (string-ascii 20), ;; "provider" or "customer"
        approved: bool
    }
)

(define-map sla-amendments
    { sla-id: (buff 32), amendment-id: uint }
    {
        new-resolution-time: (option uint),
        new-penalty-rate: (option uint),
        new-max-penalties: (option uint),
        new-deposit: (option uint),
        notes: (string-ascii MAX-TERMS-LEN),
        approved-by: (list 2 principal), ;; Multi-sig: both parties
        amended-at: uint
    }
)

(define-map sla-events
    { sla-id: (buff 32), event-id: uint }
    {
        event-type: (string-ascii 20), ;; "created", "updated", "terminated"
        details: (string-ascii MAX-TERMS-LEN),
        timestamp: uint
    }
)

;; Private Functions
(define-private (check-terms-length (terms (string-ascii MAX-TERMS-LEN)))
    (if (> (length terms) MAX-TERMS-LEN)
        ERR-INVALID-TERMS
        (ok true)
    )
)

(define-private (is-party (sla-id (buff 32)) (party principal))
    (let (
        (provider-party (map-get? sla-parties { sla-id: sla-id, party: (get provider (unwrap! (map-get? slas { sla-id: sla-id }) ERR-NOT-FOUND)) }))
        (customer-party (map-get? sla-parties { sla-id: sla-id, party: (get customer (unwrap! (map-get? slas { sla-id: sla-id }) ERR-NOT-FOUND)) }))
    )
        (or
            (and (is-some provider-party) (is-eq party (get provider (unwrap! (map-get? slas { sla-id: sla-id }) ERR-NOT-FOUND))))
            (and (is-some customer-party) (is-eq party (get customer (unwrap! (map-get? slas { sla-id: sla-id }) ERR-NOT-FOUND))))
        )
    )
)

;; Public Functions
(define-public (create-sla (sla-id (buff 32)) (provider principal) (customer principal) (resolution-time uint) (penalty-rate uint) (max-penalties uint) (deposit-required uint) (terms-hash (buff 32)) (description (string-ascii MAX-DESCRIPTION-LEN)))
    (begin
        ;; Check if SLA exists
        (asserts! (is-none (map-get? slas { sla-id: sla-id })) ERR-SLA-EXISTS)
        ;; Validate terms
        (try! (check-terms-length description))
        ;; Assert sender is provider or customer
        (asserts! (or (is-eq tx-sender provider) (is-eq tx-sender customer)) ERR-UNAUTHORIZED)
        ;; Set SLA
        (map-set slas
            { sla-id: sla-id }
            {
                provider: provider,
                customer: customer,
                resolution-time: resolution-time,
                penalty-rate: penalty-rate,
                max-penalties: max-penalties,
                deposit-required: deposit-required,
                terms-hash: terms-hash,
                description: description,
                created-at: block-height,
                active: true
            }
        )
        ;; Set parties
        (map-set sla-parties { sla-id: sla-id, party: provider } { role: "provider", approved: true })
        (map-set sla-parties { sla-id: sla-id, party: customer } { role: "customer", approved: true })
        ;; Log event
        (as-max-semver (map-insert sla-events { sla-id: sla-id, event-id: u0 } { event-type: "created", details: description, timestamp: block-height }))
        (ok true)
    )
)

(define-public (update-sla-terms (sla-id (buff 32)) (new-description (string-ascii MAX-DESCRIPTION-LEN)))
    (let (
        (sla (unwrap! (map-get? slas { sla-id: sla-id }) ERR-NOT-FOUND))
        (party-ok (try! (is-party sla-id tx-sender)))
    )
        (asserts! party-ok ERR-UNAUTHORIZED)
        (try! (check-terms-length new-description))
        (map-set slas
            { sla-id: sla-id }
            (merge sla { description: new-description, created-at: block-height })
        )
        (as-max-semver (map-insert sla-events { sla-id: sla-id, event-id: (+ u1 (fold get-next-event-id (map-keys sla-events) u0)) } { event-type: "updated", details: new-description, timestamp: block-height }))
        (ok true)
    )
)

(define-public (propose-amendment (sla-id (buff 32)) (amendment-id uint) (new-res-time (option uint)) (new-pen-rate (option uint)) (new-max-pen (option uint)) (new-dep (option uint)) (notes (string-ascii MAX-TERMS-LEN)))
    (let (
        (sla (unwrap! (map-get? slas { sla-id: sla-id }) ERR-NOT-FOUND))
        (party-ok (try! (is-party sla-id tx-sender)))
    )
        (asserts! (get active sla) ERR-UNAUTHORIZED)
        (try! (check-terms-length notes))
        (map-set sla-amendments
            { sla-id: sla-id, amendment-id: amendment-id }
            {
                new-resolution-time: new-res-time,
                new-penalty-rate: new-pen-rate,
                new-max-penalties: new-max-pen,
                new-deposit: new-dep,
                notes: notes,
                approved-by: (list tx-sender tx-sender), ;; Placeholder, approve later
                amended-at: block-height
            }
        )
        (ok true)
    )
)

(define-public (approve-amendment (sla-id (buff 32)) (amendment-id uint))
    (let* (
        (amendment (unwrap! (map-get? sla-amendments { sla-id: sla-id, amendment-id: amendment-id }) ERR-NOT-FOUND))
        (current-approvals (get approved-by amendment))
        (sla (unwrap! (map-get? slas { sla-id: sla-id }) ERR-NOT-FOUND))
        (party-ok (try! (is-party sla-id tx-sender)))
        (updated-approvals (if (is-in-list? tx-sender current-approvals) current-approvals (as-max-len? (append current-approvals tx-sender) u2)))
        (final-amendment (merge amendment { approved-by: updated-approvals }))
    )
        (asserts! party-ok ERR-UNAUTHORIZED)
        (map-set sla-amendments { sla-id: sla-id, amendment-id: amendment-id } final-amendment)
        ;; If both approved, apply
        (if (is-eq (length updated-approvals) u2)
            (let (
                (updated-sla (merge sla {
                    resolution-time: (or (get new-resolution-time final-amendment) (get resolution-time sla)),
                    penalty-rate: (or (get new-penalty-rate final-amendment) (get penalty-rate sla)),
                    max-penalties: (or (get new-max-penalties final-amendment) (get max-penalties sla)),
                    deposit-required: (or (get new-deposit final-amendment) (get deposit-required sla))
                }))
            )
                (map-set slas { sla-id: sla-id } updated-sla)
                (ok u1) ;; Amended
            )
            (ok u0) ;; Pending
        )
    )
)

(define-public (terminate-sla (sla-id (buff 32)))
    (let (
        (sla (unwrap! (map-get? slas { sla-id: sla-id }) ERR-NOT-FOUND))
        (party-ok (try! (is-party sla-id tx-sender)))
    )
        (asserts! party-ok ERR-UNAUTHORIZED)
        (map-set slas { sla-id: sla-id } (merge sla { active: false }))
        (as-max-semver (map-insert sla-events { sla-id: sla-id, event-id: (+ u1 (fold get-next-event-id (map-keys sla-events) u0)) } { event-type: "terminated", details: "SLA terminated by party", timestamp: block-height }))
        (ok true)
    )
)

;; Helper for next event ID (private)
(define-private (get-next-event-id (key (tuple (sla-id buff32) (event-id uint))) (current uint))
    (if (> (get event-id key) current) (get event-id key) current)
)

;; Read-Only Functions
(define-read-only (get-sla (sla-id (buff 32)))
    (map-get? slas { sla-id: sla-id })
)

(define-read-only (get-sla-parties (sla-id (buff 32)))
    {
        provider: (get provider (unwrap-panic (map-get? slas { sla-id: sla-id }))),
        customer: (get customer (unwrap-panic (map-get? slas { sla-id: sla-id })))
    }
)

(define-read-only (get-sla-amendment (sla-id (buff 32)) (amendment-id uint))
    (map-get? sla-amendments { sla-id: sla-id, amendment-id: amendment-id })
)

(define-read-only (get-sla-events (sla-id (buff 32)))
    (map-get? sla-events { sla-id: sla-id, event-id: u0 }) ;; Simplified; in prod, fold over map
)

(define-read-only (is-sla-active (sla-id (buff 32)))
    (let ((sla-opt (map-get? slas { sla-id: sla-id })))
        (if (is-some sla-opt)
            (ok (get active (unwrap-panic sla-opt)))
            ERR-NOT-FOUND
        )
    )
)

(define-read-only (verify-party (sla-id (buff 32)) (party principal))
    (let ((sla (unwrap! (map-get? slas { sla-id: sla-id }) ERR-NOT-FOUND)))
        (if (or (is-eq party (get provider sla)) (is-eq party (get customer sla)))
            (ok true)
            ERR-UNAUTHORIZED
        )
    )
)

