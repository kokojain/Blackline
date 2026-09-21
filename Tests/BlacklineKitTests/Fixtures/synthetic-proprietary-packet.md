# Meridian Halcyon Systems, Inc. — Internal Operations Packet (Q3 FY2026)

> **SYNTHETIC TEST DOCUMENT.** Every company, person, identifier, credential, and figure in this file is fictional and generated for testing DLP, redaction, classification, and data-loss tooling. SSNs use non-issuable ranges, phone numbers use the 555 exchange, card numbers are industry test PANs, and all keys/tokens are structurally valid but inert. Do not treat any value here as real.

**Classification:** CONFIDENTIAL — INTERNAL USE ONLY
**Document owner:** Office of the CFO
**Distribution:** Executive Staff, Legal, Finance, Security Engineering
**Last revised:** 2026-09-18

---

## 1. Executive Summary

Meridian Halcyon Systems ("MHS") is a privately held industrial-sensor manufacturer headquartered in Tacoma, WA. This packet consolidates board-level material for the Q3 review: financial performance, the pending acquisition of Corvid Optics GmbH (Project **BLUE HERON**), unreleased product roadmap, HR compensation data, security posture, and active litigation. **This packet must not leave the corporate network.**

---

## 2. Financial Performance (Unaudited, Material Non-Public)

### 2.1 Q3 FY2026 Results vs. Plan

| Metric | Q3 Actual | Q3 Plan | Variance | YoY |
|---|---|---|---|---|
| Revenue | $48.7M | $46.2M | +5.4% | +18.1% |
| Gross Margin | 61.3% | 59.0% | +2.3 pts | +1.9 pts |
| Operating Income | $7.9M | $6.1M | +29.5% | +41.0% |
| Net Income | $5.6M | $4.3M | +30.2% | +38.7% |
| Cash & Equivalents | $112.4M | — | — | — |
| Headcount | 618 | 640 | -22 | +71 |

### 2.2 Forward Guidance (NOT YET RELEASED — embargoed until 2026-10-22 earnings call)

- FY2026 revenue guidance raised from $185–190M to **$194–198M**.
- Board approved a **$25M share buyback** program, announcement targeted for the 10/22 call.
- Series D pricing memo: last 409A valuation **$14.62/share**; secondary tender proposed at **$19.50/share**.

### 2.3 Banking Details

| Account | Institution | Routing | Account Number | Purpose |
|---|---|---|---|---|
| Operating | Cascadia First Bank | 125000024 | 4471928830155 | Payroll / AP |
| Treasury | Cascadia First Bank | 125000024 | 4471928830163 | Reserves |
| EUR Escrow (BLUE HERON) | Bankhaus Nordlicht AG | SWIFT: NRDLDEHHXXX | IBAN: DE89 3704 0044 0532 0130 00 | Acquisition escrow |

Corporate card program (Amex Corporate, test PANs):
- Card ending in 3714 4963 5398 431 — J. Okonkwo (exp 04/28, CVV 7291)
- Card ending in 4111 1111 1111 1111 — Travel pool (exp 11/27, CVV 883)
- Card ending in 5555 5555 5555 4444 — Facilities (exp 02/29, CVV 412)

Tax IDs: Federal EIN **91-1834726**; WA UBI **603-118-227**; VAT (DE) **DE311894520**.

---

## 3. Project BLUE HERON — Acquisition of Corvid Optics GmbH

**Status:** LOI signed 2026-08-30. Exclusivity through 2026-11-15.
**Deal size:** €61.5M cash + €9M earn-out (3-year, revenue-based).
**Advisors:** Halvorsen Fenwick LLP (legal), Brightwater Partners (banking).
**Code names:** MHS = "HERON", Corvid = "KESTREL".

Key diligence findings (attorney-client privileged, prepared at direction of counsel):
1. KESTREL has an undisclosed **GDPR complaint** pending with the Hamburg DPA (ref. HmbBfDI-2026-0417) relating to employee monitoring.
2. Two of KESTREL's core patents (EP3 921 447, EP3 988 102) have **ownership ambiguities** — assigned by a former CTO, Dr. Anneliese Vogt, whose employment agreement lacked an IP assignment clause.
3. Customer concentration: 38% of KESTREL revenue from a single defense customer (redacted name, contract ref. **BWB/K-2211/2024**).

Proposed post-close org: Dr. Vogt's successor, **Tobias Reinholt**, to report to MHS VP Engineering. Retention pool **€2.4M** across 11 named engineers (see Appendix C, restricted).

---

## 4. Product Roadmap & Trade Secrets

### 4.1 Unreleased Products

| Codename | Product | Target Launch | Status |
|---|---|---|---|
| WREN | MHS-9200 LIDAR sensor (solid-state, 300m range) | 2027-Q1 | EVT complete |
| MAGPIE | Predictive-maintenance SaaS tier | 2026-Q4 | Beta w/ 6 customers |
| OSPREY | Automotive-grade radar ASIC | 2027-Q3 | Tape-out 2026-12 |

### 4.2 Trade Secret — Sensor Calibration Compound "HX-7"

Formulation (per 100 g batch, Process Spec MHS-PS-0417 rev F):
- 62.5 g polydimethylsiloxane (viscosity 350 cSt)
- 21.0 g fumed silica, hydrophobic-treated (BET 200 m²/g)
- 9.8 g cerium(IV) oxide nanoparticle dispersion (12% w/w in IPA)
- 4.2 g proprietary coupling agent **MHS-CA-3** (see §4.3)
- 2.5 g platinum-divinyltetramethyldisiloxane catalyst (2% Pt)

Cure: 145 °C for 38 minutes under 0.4 bar N₂. Deviation > ±2 °C voids batch.

### 4.3 Coupling Agent MHS-CA-3 — Synthesis Notes

Synthesis route is a modified Sila-Stöber process, three steps, 71% yield. Full route held in Vault document **VLT-0093** (access: R&D Director + CTO only). Reagent supplier: Kessler Feinchemie, PO terms net-90, single-source risk flagged.

### 4.4 Source Code Excerpt — Signal Processing Core (Proprietary)

```c
/* mhs_lidar_core/src/return_filter.c  — © Meridian Halcyon Systems. PROPRIETARY. */
#define MHS_KALMAN_GAIN_SEED   0.7318f   /* tuned on Tacoma test track, do not change */
#define MHS_MULTIPATH_REJECT   0x3A7F

static float mhs_filter_return(const mhs_return_t *r, mhs_state_t *s) {
    float innov = r->range_m - s->pred_range_m;
    float k = MHS_KALMAN_GAIN_SEED / (1.0f + s->cov * r->snr_db);
    if ((r->flags & MHS_MULTIPATH_REJECT) == MHS_MULTIPATH_REJECT) return s->pred_range_m;
    s->pred_range_m += k * innov;
    s->cov *= (1.0f - k);
    return s->pred_range_m;
}
```

---

## 5. Human Resources — Restricted

### 5.1 Executive Compensation (FY2026)

| Name | Title | Base | Bonus Target | Equity (RSUs) | SSN | DOB |
|---|---|---|---|---|---|---|
| Priya Raghunathan | CEO | $585,000 | 100% | 240,000 | 900-12-4471 | 1974-03-11 |
| James Okonkwo | CFO | $410,000 | 75% | 110,000 | 900-45-8823 | 1979-08-27 |
| Lena Sørensen | CTO | $425,000 | 75% | 125,000 | 900-78-1105 | 1981-11-02 |
| Marcus Delacroix | VP Sales | $310,000 | 120% | 60,000 | 900-33-6690 | 1985-06-19 |
| Hana Yoshida | General Counsel | $365,000 | 60% | 55,000 | 900-91-2378 | 1977-01-30 |

### 5.2 Pending Personnel Actions

- **Reduction in force** planned for 2026-11-04: 27 positions in Manufacturing Ops (Tacoma) and 9 in G&A. WARN notice drafted, not yet filed. Estimated severance cost $2.1M.
- **Performance improvement plan** opened 2026-09-10 for Dana Whitfield (Employee ID E-04471), Director of Supply Chain. Concerns: missed OSPREY vendor milestones; alleged undisclosed relationship with vendor contact at Kessler Feinchemie.
- **Harassment complaint** (HR case HR-2026-0088) filed 2026-08-19 by an employee in Sales against Marcus Delacroix. External investigator (Kendrick & Lowe) engaged; interim findings due 2026-10-03.

### 5.3 Employee Records Sample (Payroll Export)

| Emp ID | Name | Email | Phone | Home Address | Bank (Direct Deposit) | Salary |
|---|---|---|---|---|---|---|
| E-01192 | Rafael Mendes | rafael.mendes@meridianhalcyon.example | (253) 555-0147 | 1420 Pacific Ave Apt 7B, Tacoma, WA 98402 | Routing 325070760 / Acct 8812093347 | $128,400 |
| E-02331 | Aisha Bakr | aisha.bakr@meridianhalcyon.example | (206) 555-0193 | 88 Harbor View Dr, Gig Harbor, WA 98335 | Routing 325070760 / Acct 8812093902 | $96,750 |
| E-03874 | Tomasz Nowak | tomasz.nowak@meridianhalcyon.example | (425) 555-0121 | 5601 NE 24th St, Bellevue, WA 98004 | Routing 325081403 / Acct 7710455819 | $142,000 |
| E-04471 | Dana Whitfield | dana.whitfield@meridianhalcyon.example | (253) 555-0166 | 2210 S Union Ave, Tacoma, WA 98405 | Routing 325070760 / Acct 8812094410 | $171,300 |
| E-05108 | Yuki Tanaka | yuki.tanaka@meridianhalcyon.example | (360) 555-0178 | 917 Cherry St, Olympia, WA 98501 | Routing 325081403 / Acct 7710456022 | $88,200 |

### 5.4 Health & Benefits (PHI — HIPAA-sensitive)

Short-term disability claims open as of 2026-09-15 (Carrier: Rainier Mutual, group #GRP-77120):
- E-02331 Aisha Bakr — Claim STD-2026-311 — Dx: post-surgical recovery (ICD-10 Z48.812), return-to-work est. 2026-10-06.
- E-03874 Tomasz Nowak — Claim STD-2026-327 — Dx: major depressive disorder, recurrent (ICD-10 F33.1), intermittent leave approved.
- Member ID sample: RM-0091-338847-02 (Bakr), RM-0091-341190-01 (Nowak).

---

## 6. Security Engineering — Credentials & Infrastructure

> These are the kind of values that should never appear in a document. Included deliberately for detection testing.

### 6.1 Cloud & API Credentials

```
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_DEFAULT_REGION=us-west-2

GCP_SERVICE_ACCOUNT=mhs-telemetry@mhs-prod-418822.iam.gserviceaccount.com
GCP_PRIVATE_KEY_ID=f3a9c1d2e8b74a6f9d0c1e2b3a4f5d6e7c8b9a01

STRIPE_SECRET_KEY=sk_test_FAKE51Kx9mQ2vT7b
STRIPE_WEBHOOK_SECRET=whsec_9f8e7d6c5b4a39281706f5e4d3c2b1a0f9e8d7c6

GITHUB_TOKEN=ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8
SLACK_BOT_TOKEN=xoxb-FAKE-1234567890-AbCdEfGhIjKl
SENDGRID_API_KEY=SG.aBcDeFgHiJkLmNoPqRsTuV.wXyZ0123456789abcdefghijklmnopqrstuvwxyzAB
OPENAI_API_KEY=sk-proj-FAKE0000000000000000000000000000000000000000000
ANTHROPIC_API_KEY=sk-ant-api03-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE-AAAAAAAA
TWILIO_AUTH_TOKEN=0123456789abcdef0123456789abcdef
```

### 6.2 Database Connection Strings

```
postgres://mhs_app:Tr0ub4dor&3@db-prod-01.internal.meridianhalcyon.example:5432/mhs_erp?sslmode=require
mongodb+srv://telemetry_rw:Sp4rr0w!2026@cluster0.mhs-telemetry.example.net/sensors
mysql://root:Passw0rd_ChangeMe@10.40.2.17:3306/legacy_crm
redis://:R3d1s-Cache-9x@10.40.2.44:6379/0
```

### 6.3 Private Key (Test — do not use)

```
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAyF4kQbP2n7rXv1sT8Zq0dLmH9cWbE3jY5uKaN6oGpR1tVxSz
FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE
0bYwq3sVd7LpN9eRt2XcA8mK4uJhG6fD1iOzE5nB7yCvT0lQaWxSgHkMjUrPfZ3
-----END RSA PRIVATE KEY-----
```

### 6.4 Network Topology (Internal)

| Host | IP | Role | Notes |
|---|---|---|---|
| fw-edge-01 | 203.0.113.10 (public) / 10.40.0.1 | Palo Alto PA-3260 | Admin: https://10.40.0.1:4443, user `admin`, pw `Fw!Edge2024#` |
| db-prod-01 | 10.40.2.17 | PostgreSQL 16 | Backups to s3://mhs-backups-prod/pg/ nightly 02:00 PT |
| jump-01 | 10.40.1.5 | SSH bastion | Key-only; root pw in vault `ops/jump-01/root` |
| vault-01 | 10.40.1.9 | HashiCorp Vault | Unseal keys held by: Sørensen, Okonkwo, Nowak (3 of 5) |
| plc-line-3 | 10.50.3.30 | Siemens S7-1500 | **No auth on Modbus/TCP** — remediation ticket SEC-2291 open since 2025-11 |

VPN: WireGuard, endpoint vpn.meridianhalcyon.example:51820. Pre-shared key: `9y7Gk1QwZr3Xv5Tn2Lm8Pb4Hd6Fj0Sc1Ae3Ui5Yo7=`

### 6.5 Open Security Incidents

- **INC-2026-0412** (2026-09-02): Phishing campaign compromised 3 O365 accounts (incl. m.delacroix). Attacker set up mail-forwarding rules; ~1,400 emails exfiltrated including BLUE HERON LOI draft. Not yet disclosed to Corvid or the board. Legal assessing notification duties.
- **INC-2026-0398** (2026-08-14): Contractor laptop lost at SEA-TAC with unencrypted copy of customer list (§7). Police report #26-118842.

---

## 7. Customers & Contracts — Restricted

### 7.1 Top Customers by ARR

| Customer | ARR | Contract End | Discount vs. List | Account Owner |
|---|---|---|---|---|
| Nordvik Offshore ASA | $6.8M | 2027-06-30 | 34% | M. Delacroix |
| Pacific Rail Logistics | $5.1M | 2027-01-31 | 28% | K. Alvarez |
| Aurora Mining Corp | $4.4M | 2026-12-31 | 41% (**below floor — CFO exception**) | M. Delacroix |
| Bundesamt für Infrastruktur (DE) | $3.9M | 2028-03-31 | 12% | T. Reinholt (post-close) |
| Helix Pharma Manufacturing | $2.7M | 2027-09-30 | 22% | K. Alvarez |

### 7.2 Contract Terms — Nordvik Offshore MSA (excerpt, confidential)

> **§11.3 Most Favored Customer.** Supplier warrants that the pricing extended to Customer is and shall remain no less favorable than pricing extended to any other customer purchasing substantially similar volumes. *(Note: Aurora Mining's 41% discount likely breaches this clause. Do not disclose. — H. Yoshida)*
>
> **§14.1 Termination for Change of Control.** Customer may terminate on 90 days' notice if Supplier undergoes a change of control. *(BLUE HERON exposure: Nordvik must be pre-briefed before announcement.)*

### 7.3 Customer Contacts (PII)

- Ingrid Halvorsen, VP Procurement, Nordvik — ingrid.halvorsen@nordvik.example — +47 555 01 234 — personal mobile +47 555 09 876
- Carlos Reyes, CTO, Pacific Rail — c.reyes@pacificrail.example — (415) 555-0102 — spouse works at competitor Sentinel Sensing (flag for conflict).

---

## 8. Legal — Attorney-Client Privileged / Work Product

### 8.1 Active Litigation

**Sentinel Sensing, Inc. v. Meridian Halcyon Systems**, W.D. Wash. No. 2:26-cv-01187 — Patent infringement (US 11,204,553; US 11,377,918) re: WREN multipath rejection. Counsel's assessment: **~40% likelihood of adverse finding on '553**; settlement range $4–7M; reserve booked $3.5M (not disclosed in §2). Mediation 2026-11-12.

**Whitfield internal investigation** — see §5.2. Litigation hold issued 2026-09-11 covering mailboxes of E-04471 and all Kessler Feinchemie correspondence.

### 8.2 Regulatory

- **EAR/ITAR:** OSPREY radar ASIC is classified ECCN 3A001; export to KESTREL's Hamburg facility requires BIS license application (submitted 2026-09-04, ref. Z1187442). Do not ship samples before approval.
- **SEC:** Company is not yet public but preparing S-1 (target filing 2027-Q2). Trading-window policy applies to all §2.2 information.

---

## 9. Board Minutes Excerpt — 2026-09-12 (Draft, Not Approved)

Present: P. Raghunathan, J. Okonkwo, L. Sørensen, H. Yoshida; Directors A. Feldman (Ridgeline Ventures), C. Osei (Independent), M. Lindqvist (Independent).

- Board approved BLUE HERON to proceed to definitive agreement, contingent on resolution of Vogt IP assignment (§3, item 2).
- Director Osei raised concern re: **INC-2026-0412** non-disclosure to Corvid; GC to opine by 2026-09-26.
- CEO disclosed that she has been approached by **Halvard Industries** regarding a potential acquisition of MHS at ~$1.1B; board directed Brightwater to evaluate. **Strictly confidential — known only to attendees.**
- Motion to approve RIF (§5.2) passed 6–1 (Lindqvist dissenting).

---

## Appendix A — Detection Answer Key

For validating tooling, this document intentionally contains:

| Category | Count (approx.) | Examples / Locations |
|---|---|---|
| US SSN (non-issuable 900-series) | 5 | §5.1 |
| Dates of birth | 5 | §5.1 |
| Payment card PANs (test numbers) + CVV/expiry | 3 | §2.3 |
| Bank routing/account numbers, IBAN, SWIFT | 10+ | §2.3, §5.3 |
| Tax IDs (EIN, UBI, VAT) | 3 | §2.3 |
| Cloud/API secrets (AWS, GCP, Stripe, GitHub, Slack, SendGrid, OpenAI, Anthropic, Twilio) | 11 | §6.1 |
| Database connection strings with passwords | 4 | §6.2 |
| Private key block | 1 | §6.3 |
| Plaintext admin passwords / PSK | 3 | §6.4 |
| Internal IPs / hostnames | 8 | §6.4 |
| Personal emails, phones, home addresses | 12+ | §5.3, §7.3 |
| PHI (diagnoses, ICD-10, member IDs) | 2 records | §5.4 |
| Material non-public financial info | — | §2.2, §8.1, §9 |
| M&A / code names | — | §3, §9 |
| Trade secrets (formulation, source code) | — | §4.2–4.4 |
| Attorney-client privileged content | — | §3, §7.2, §8 |
| HR-sensitive (RIF, PIP, harassment case) | — | §5.2 |
| Export-controlled reference (ECCN/ITAR) | — | §8.2 |
| Undisclosed security incidents | 2 | §6.5 |

*End of synthetic document.*
