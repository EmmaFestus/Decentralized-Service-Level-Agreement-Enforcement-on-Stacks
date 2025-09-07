
;; ComplaintManager Smart Contract
;; Handles filing, updating, and tracking virtual complaints linked to SLAs
;; Integrates with SLARegistry and SIP-010 for deposits

(impl-trait 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.nft-trait.nft-trait) ;; Optional for complaint as NFT

;; Constants
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-INVALID-SLA (err u201))
(define-constant ERR-INSUFFICIENT-DEPOSIT (err u202))
(define-constant ERR-COMPLAINT-EXISTS (err u203))
(define-constant ERR-INVALID-STATUS (err u204))
(define-constant ERR-EVIDENCE_TOO_LONG (err u205))
(define-constant DEPOSIT_AMOUNT u1000) ;; Fixed or from SLA

;; Data Maps
(define-map complaints
    { complaint-id: (buff 32), sla-id: (buff 32) } ;; Unique per SLA
    {
        filer: principal, ;; Customer
        description: (string-ascii 300),
        evidence-hash: (buff 32), ;; IPFS/SHA256
        status: (string-ascii 20), ;; "filed", "in-progress", "resolved", "escalated"
        filed-at: uint,
        updated-at: uint,
        deposit-locked: uint, ;; In micro-SLA-TKN
        resolution-deadline: uint ;; block-height + SLA resolution-time
    }
)

(define-map complaint-status-history
    { complaint-id: (buff 32), sla-id: (buff 32), update-id: uint }
    {
        old-status: (string-ascii 20),
        new-status: (string-ascii 20),
        updated-by: principal,
        notes: (string-ascii 100),
        timestamp: uint
    }
)

;; Private Functions
(define-private (validate-sla (sla-id (buff 32)))
    (let ((sla-opt (contract-call? .sla-registry get-sla sla-id)))
        (asserts! (and (is-some sla-opt) (get active (unwrap-panic sla-opt))) ERR-INVALID-SLA)
        (ok true)
    )
)

(define-private (lock-deposit (amount uint))
    ;; Simulate SIP-010 transfer-from (in prod: (contract-call? .sla-token transfer ...))
    (if (>= amount DEPOSIT_AMOUNT)
        (ok true)
        ERR-INSUFFICIENT-DEPOSIT
    )
)

(define-private (get-next-update-id (complaint-id (buff 32)) (sla-id (buff 32)) (current uint))
    (+ u1 current) ;; Simplified fold in prod
)

;; Public Functions
(define-public (file-complaint (complaint-id (buff 32)) (sla-id (buff 32)) (description (string-ascii 300)) (evidence-hash (buff 32)))
    (begin
        ;; Validate SLA
        (try! (validate-sla sla-id))
        ;; Check if complaint exists
        (asserts! (is-none (map-get? complaints { complaint-id: complaint-id, sla-id: sla-id })) ERR-COMPLAINT-EXISTS)
        ;; Lock deposit (mock SIP-010)
        (try! (lock-deposit DEPOSIT_AMOUNT))
        ;; Get SLA details for deadline
        (let* (
            (sla (unwrap-panic (contract-call? .sla-registry get-sla sla-id)))
            (deadline (+ block-height (get resolution-time sla)))
        )
            (map-set complaints
                { complaint-id: complaint-id, sla-id: sla-id }
                {
                    filer: tx-sender,
                    description: description,
                    evidence-hash: evidence-hash,
                    status: "filed",
                    filed-at: block-height,
                    updated-at: block-height,
                    deposit-locked: DEPOSIT_AMOUNT,
                    resolution-deadline: deadline
                }
            )
            ;; Log history
            (map-set complaint-status-history
                { complaint-id: complaint-id, sla-id: sla-id, update-id: u0 }
                {
                    old-status: "",
                    new-status: "filed",
                    updated-by: tx-sender,
                    notes: "Complaint filed",
                    timestamp: block-height
                }
            )
            (ok true)
        )
    )
)

(define-public (update-complaint-status (complaint-id (buff 32)) (sla-id (buff 32)) (new-status (string-ascii 20)) (notes (string-ascii 100)))
    (let* (
        (complaint (unwrap! (map-get? complaints { complaint-id: complaint-id, sla-id: sla-id }) ERR-INVALID-SLA))
        (sla (unwrap-panic (contract-call? .sla-registry get-sla sla-id)))
        (is-provider (is-eq tx-sender (get provider sla)))
        (is-customer (is-eq tx-sender (get customer sla)))
        (valid-status (or (is-eq new-status "in-progress") (is-eq new-status "resolved") (is-eq new-status "escalated")))
        (next-id (get-next-update-id complaint-id sla-id u0))
    )
        (asserts! (or is-provider is-customer) ERR-UNAUTHORIZED)
        (asserts! valid-status ERR-INVALID-STATUS)
        ;; Only provider updates status (customer can only file/escalate)
        (asserts! is-provider ERR-UNAUTHORIZED)
        ;; Check deadline for auto-escalate if missed
        (if (> block-height (get resolution-deadline complaint))
            ;; Trigger penalty/escalation cross-call (in prod)
            (begin
                (print "Deadline missed - trigger penalty")
                (map-set complaints
                    { complaint-id: complaint-id, sla-id: sla-id }
                    (merge complaint { status: "escalated", updated-at: block-height })
                )
            )
            (ok true)
        )
        (map-set complaints
            { complaint-id: complaint-id, sla-id: sla-id }
            (merge complaint { status: new-status, updated-at: block-height })
        )
        (map-set complaint-status-history
            { complaint-id: complaint-id, sla-id: sla-id, update-id: next-id }
            {
                old-status: (get status complaint),
                new-status: new-status,
                updated-by: tx-sender,
                notes: notes,
                timestamp: block-height
            }
        )
        (ok true)
    )
)

(define-public (add-evidence (complaint-id (buff 32)) (sla-id (buff 32)) (new-evidence-hash (buff 32)) (notes (string-ascii 100)))
    (let (
        (complaint (unwrap! (map-get? complaints { complaint-id: complaint-id, sla-id: sla-id }) ERR-INVALID-SLA))
        (sla (unwrap-panic (contract-call? .sla-registry get-sla sla-id)))
        (is-party (or (is-eq tx-sender (get filer complaint)) (is-eq tx-sender (get provider sla))))
    )
        (asserts! is-party ERR-UNAUTHORIZED)
        (asserts! (<= (length notes) u100) ERR-EVIDENCE_TOO_LONG)
        ;; Append evidence (in prod: list or separate map)
        (map-set complaints
            { complaint-id: complaint-id, sla-id: sla-id }
            (merge complaint { evidence-hash: new-evidence-hash, updated-at: block-height })
        )
        (ok true)
    )
)

(define-public (close-complaint (complaint-id (buff 32)) (sla-id (buff 32)))
    (let (
        (complaint (unwrap! (map-get? complaints { complaint-id: complaint-id, sla-id: sla-id }) ERR-INVALID-SLA))
        (sla (unwrap-panic (contract-call? .sla-registry get-sla sla-id)))
    )
        (asserts! (is-eq tx-sender (get provider sla)) ERR-UNAUTHORIZED)
        (asserts! (is-eq (get status complaint) "resolved") ERR-INVALID-STATUS)
        ;; Release deposit (mock SIP-010 transfer-back)
        (map-delete complaints { complaint-id: complaint-id, sla-id: sla-id })
        (ok true)
    )
)

;; Read-Only Functions
(define-read-only (get-complaint (complaint-id (buff 32)) (sla-id (buff 32)))
    (map-get? complaints { complaint-id: complaint-id, sla-id: sla-id })
)

(define-read-only (get-complaint-history (complaint-id (buff 32)) (sla-id (buff 32)))
    (map-get? complaint-status-history { complaint-id: complaint-id, sla-id: sla-id, update-id: u0 }) ;; Simplified
)

(define-read-only (is-deadline-missed (complaint-id (buff 32)) (sla-id (buff 32)))
    (let ((complaint-opt (map-get? complaints { complaint-id: complaint-id, sla-id: sla-id })))
        (if (is-some complaint-opt)
            (let ((complaint (unwrap-panic complaint-opt)))
                (if (> block-height (get resolution-deadline complaint))
                    (ok true)
                    (ok false)
                )
            )
            ERR-INVALID-SLA
        )
    )
)

(define-read-only (get-customer-complaints (customer principal))
    ;; In prod: fold over map filtered by filer
    (ok none) ;; Placeholder for list
)