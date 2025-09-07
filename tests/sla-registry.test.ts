
import { describe, expect, it, vi, beforeEach } from "vitest";

// Interfaces for type safety
interface ClarityResponse<T> {
  ok: boolean;
  value: T | number; // number for error codes
}

interface SlaDetails {
  provider: string;
  customer: string;
  resolutionTime: number;
  penaltyRate: number;
  maxPenalties: number;
  depositRequired: number;
  termsHash: string; // buff32 as hex string for mock
  description: string;
  createdAt: number;
  active: boolean;
}

interface AmendmentDetails {
  newResolutionTime?: number | null;
  newPenaltyRate?: number | null;
  newMaxPenalties?: number | null;
  newDeposit?: number | null;
  notes: string;
  approvedBy: string[];
  amendedAt: number;
}

interface EventDetails {
  eventType: string;
  details: string;
  timestamp: number;
}

// Mock contract implementation
class SlaRegistryMock {
  private slas: Map<string, SlaDetails> = new Map();
  private slaParties: Map<string, { role: string; approved: boolean }> = new Map(); // key: `${slaId}-${party}`
  private slaAmendments: Map<string, AmendmentDetails> = new Map(); // key: `${slaId}-${amendmentId}`
  private slaEvents: Map<string, EventDetails> = new Map(); // Simplified: key: `${slaId}-${eventId}`

  private MAX_DESCRIPTION_LEN = 200;
  private ERR_UNAUTHORIZED = 100;
  private ERR_SLA_EXISTS = 101;
  private ERR_INVALID_TERMS = 102;
  private ERR_AMENDMENT_FAILED = 103;
  private ERR_NOT_FOUND = 104;

  private nextEventId = 0;

  createSla(
    caller: string,
    slaId: string,
    provider: string,
    customer: string,
    resolutionTime: number,
    penaltyRate: number,
    maxPenalties: number,
    depositRequired: number,
    termsHash: string,
    description: string
  ): ClarityResponse<boolean> {
    if (this.slas.has(slaId)) {
      return { ok: false, value: this.ERR_SLA_EXISTS };
    }
    if (description.length > this.MAX_DESCRIPTION_LEN) {
      return { ok: false, value: this.ERR_INVALID_TERMS };
    }
    if (caller !== provider && caller !== customer) {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }

    const sla: SlaDetails = {
      provider,
      customer,
      resolutionTime,
      penaltyRate,
      maxPenalties,
      depositRequired,
      termsHash,
      description,
      createdAt: Date.now(),
      active: true,
    };
    this.slas.set(slaId, sla);

    this.slaParties.set(`${slaId}-${provider}`, { role: "provider", approved: true });
    this.slaParties.set(`${slaId}-${customer}`, { role: "customer", approved: true });

    this.slaEvents.set(`${slaId}-0`, { eventType: "created", details: description, timestamp: Date.now() });
    this.nextEventId = 1;

    return { ok: true, value: true };
  }

  updateSlaTerms(caller: string, slaId: string, newDescription: string): ClarityResponse<boolean> {
    const sla = this.slas.get(slaId);
    if (!sla) {
      return { ok: false, value: this.ERR_NOT_FOUND };
    }
    const partyKeyProvider = `${slaId}-${sla.provider}`;
    const partyKeyCustomer = `${slaId}-${sla.customer}`;
    const isParty = (caller === sla.provider && this.slaParties.has(partyKeyProvider)) ||
                    (caller === sla.customer && this.slaParties.has(partyKeyCustomer));
    if (!isParty) {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }
    if (newDescription.length > this.MAX_DESCRIPTION_LEN) {
      return { ok: false, value: this.ERR_INVALID_TERMS };
    }

    this.slas.set(slaId, { ...sla, description: newDescription, createdAt: Date.now() });
    this.slaEvents.set(`${slaId}-${this.nextEventId}`, {
      eventType: "updated",
      details: newDescription,
      timestamp: Date.now(),
    });
    this.nextEventId++;

    return { ok: true, value: true };
  }

  proposeAmendment(
    caller: string,
    slaId: string,
    amendmentId: number,
    newResTime: number | null,
    newPenRate: number | null,
    newMaxPen: number | null,
    newDep: number | null,
    notes: string
  ): ClarityResponse<boolean> {
    const sla = this.slas.get(slaId);
    if (!sla || !sla.active) {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }
    if (notes.length > this.MAX_DESCRIPTION_LEN) {
      return { ok: false, value: this.ERR_INVALID_TERMS };
    }
    const isParty = (caller === sla.provider || caller === sla.customer);
    if (!isParty) {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }

    const amendmentKey = `${slaId}-${amendmentId}`;
    const amendment: AmendmentDetails = {
      newResolutionTime: newResTime !== null ? newResTime : undefined,
      newPenaltyRate: newPenRate !== null ? newPenRate : undefined,
      newMaxPenalties: newMaxPen !== null ? newMaxPen : undefined,
      newDeposit: newDep !== null ? newDep : undefined,
      notes,
      approvedBy: [caller],
      amendedAt: Date.now(),
    };
    this.slaAmendments.set(amendmentKey, amendment);

    return { ok: true, value: true };
  }

  approveAmendment(caller: string, slaId: string, amendmentId: number): ClarityResponse<number> {
    const amendmentKey = `${slaId}-${amendmentId}`;
    const amendment = this.slaAmendments.get(amendmentKey);
    if (!amendment) {
      return { ok: false, value: this.ERR_NOT_FOUND };
    }
    const sla = this.slas.get(slaId);
    if (!sla) {
      return { ok: false, value: this.ERR_NOT_FOUND };
    }
    const isParty = (caller === sla.provider || caller === sla.customer);
    if (!isParty) {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }

    if (!amendment.approvedBy.includes(caller)) {
      amendment.approvedBy.push(caller);
      this.slaAmendments.set(amendmentKey, amendment);
    }

    if (amendment.approvedBy.length === 2) {
      // Apply amendment
      const updatedSla = {
        ...sla,
        resolutionTime: amendment.newResolutionTime ?? sla.resolutionTime,
        penaltyRate: amendment.newPenaltyRate ?? sla.penaltyRate,
        maxPenalties: amendment.newMaxPenalties ?? sla.maxPenalties,
        depositRequired: amendment.newDeposit ?? sla.depositRequired,
      };
      this.slas.set(slaId, updatedSla);
      return { ok: true, value: 1 }; // Amended
    }

    return { ok: true, value: 0 }; // Pending
  }

  terminateSla(caller: string, slaId: string): ClarityResponse<boolean> {
    const sla = this.slas.get(slaId);
    if (!sla) {
      return { ok: false, value: this.ERR_NOT_FOUND };
    }
    const isParty = (caller === sla.provider || caller === sla.customer);
    if (!isParty) {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }

    this.slas.set(slaId, { ...sla, active: false });
    this.slaEvents.set(`${slaId}-${this.nextEventId}`, {
      eventType: "terminated",
      details: "SLA terminated by party",
      timestamp: Date.now(),
    });
    this.nextEventId++;

    return { ok: true, value: true };
  }

  // Read-only
  getSla(slaId: string): ClarityResponse<SlaDetails | null> {
    const sla = this.slas.get(slaId);
    return { ok: true, value: sla ?? null };
  }

  getSlaParties(slaId: string): ClarityResponse<{ provider: string; customer: string }> {
    const sla = this.slas.get(slaId);
    if (!sla) return { ok: false, value: this.ERR_NOT_FOUND };
    return { ok: true, value: { provider: sla.provider, customer: sla.customer } };
  }

  getSlaAmendment(slaId: string, amendmentId: number): ClarityResponse<AmendmentDetails | null> {
    const key = `${slaId}-${amendmentId}`;
    const amendment = this.slaAmendments.get(key);
    return { ok: true, value: amendment ?? null };
  }

  getSlaEvents(slaId: string): ClarityResponse<EventDetails | null> {
    const eventKey = `${slaId}-0`; // Simplified
    const event = this.slaEvents.get(eventKey);
    return { ok: true, value: event ?? null };
  }

  isSlaActive(slaId: string): ClarityResponse<boolean> {
    const sla = this.slas.get(slaId);
    if (!sla) return { ok: false, value: this.ERR_NOT_FOUND };
    return { ok: true, value: sla.active };
  }

  verifyParty(slaId: string, party: string): ClarityResponse<boolean> {
    const sla = this.slas.get(slaId);
    if (!sla) return { ok: false, value: this.ERR_NOT_FOUND };
    if (party === sla.provider || party === sla.customer) {
      return { ok: true, value: true };
    }
    return { ok: false, value: this.ERR_UNAUTHORIZED };
  }
}

// Test setup
const accounts = {
  provider: "wallet_1",
  customer: "wallet_2",
  unauthorized: "wallet_3",
};

describe("SLARegistry Contract", () => {
  let contract: SlaRegistryMock;

  beforeEach(() => {
    contract = new SlaRegistryMock();
    vi.resetAllMocks();
  });

  it("should create a new SLA successfully", () => {
    const slaId = "sla-hash-1"; // Mock buff32 as string
    const result = contract.createSla(
      accounts.provider,
      slaId,
      accounts.provider,
      accounts.customer,
      1440, // 24 hours
      10, // 10%
      3,
      1000, // micro-SLA-TKN
      "terms-hash",
      "Test SLA for internet service"
    );
    expect(result).toEqual({ ok: true, value: true });

    const getResult = contract.getSla(slaId);
    expect(getResult.ok).toBe(true);
    expect(getResult.value).toMatchObject({
      provider: accounts.provider,
      customer: accounts.customer,
      resolutionTime: 1440,
      penaltyRate: 10,
      maxPenalties: 3,
      depositRequired: 1000,
      active: true,
      description: "Test SLA for internet service",
    });
  });

  it("should prevent creating duplicate SLA", () => {
    const slaId = "sla-hash-1";
    contract.createSla(accounts.provider, slaId, accounts.provider, accounts.customer, 1440, 10, 3, 1000, "terms", "desc");
    const result = contract.createSla(accounts.customer, slaId, accounts.provider, accounts.customer, 1440, 10, 3, 1000, "terms", "desc");
    expect(result).toEqual({ ok: false, value: 101 });
  });

  it("should allow parties to update SLA terms", () => {
    const slaId = "sla-hash-1";
    contract.createSla(accounts.provider, slaId, accounts.provider, accounts.customer, 1440, 10, 3, 1000, "terms", "old desc");
    const result = contract.updateSlaTerms(accounts.customer, slaId, "updated description");
    expect(result).toEqual({ ok: true, value: true });

    const getResult = contract.getSla(slaId);
    expect(getResult.value?.description).toBe("updated description");
  });

  it("should prevent unauthorized update", () => {
    const slaId = "sla-hash-1";
    contract.createSla(accounts.provider, slaId, accounts.provider, accounts.customer, 1440, 10, 3, 1000, "terms", "desc");
    const result = contract.updateSlaTerms(accounts.unauthorized, slaId, "hack attempt");
    expect(result).toEqual({ ok: false, value: 100 });
  });

  it("should propose and approve amendment with multi-sig", () => {
    const slaId = "sla-hash-1";
    const amendmentId = 1;
    contract.createSla(accounts.provider, slaId, accounts.provider, accounts.customer, 1440, 10, 3, 1000, "terms", "desc");

    // Propose
    const proposeResult = contract.proposeAmendment(accounts.provider, slaId, amendmentId, 2000, null, null, null, "Increase resolution time");
    expect(proposeResult).toEqual({ ok: true, value: true });

    // Approve by customer
    const approveResult = contract.approveAmendment(accounts.customer, slaId, amendmentId);
    expect(approveResult).toEqual({ ok: true, value: 1 }); // Amended

    const getSlaResult = contract.getSla(slaId);
    expect(getSlaResult.value?.resolutionTime).toBe(2000);
  });

  it("should terminate SLA by party", () => {
    const slaId = "sla-hash-1";
    contract.createSla(accounts.provider, slaId, accounts.provider, accounts.customer, 1440, 10, 3, 1000, "terms", "desc");
    const result = contract.terminateSla(accounts.customer, slaId);
    expect(result).toEqual({ ok: true, value: true });

    const isActive = contract.isSlaActive(slaId);
    expect(isActive.value).toBe(false);
  });

  it("should verify party correctly", () => {
    const slaId = "sla-hash-1";
    contract.createSla(accounts.provider, slaId, accounts.provider, accounts.customer, 1440, 10, 3, 1000, "terms", "desc");
    const verifyProvider = contract.verifyParty(slaId, accounts.provider);
    expect(verifyProvider).toEqual({ ok: true, value: true });

    const verifyUnauthorized = contract.verifyParty(slaId, accounts.unauthorized);
    expect(verifyUnauthorized).toEqual({ ok: false, value: 100 });
  });
});