# Functional Specification
## Auto-Creation of 301 Transfer Reservations for Open Production Orders (8P01 → 8Q01)

| | |
|---|---|
| **Document ID** | FS-MM-301RES-001 |
| **Object description** | ABAP report to mass-create movement type 301 stock-transfer reservations from plant 8P01 to plant 8Q01 against open production orders |
| **SAP solution** | S/4HANA on-premise |
| **Module** | MM / PP (Inventory Management – Reservations) |
| **RICEFW type** | Report (with background scheduling) |
| **Complexity** | Medium |
| **Author** | (to complete) |
| **Version** | 0.1 (Draft) |
| **Date** | 2026-07-15 |
| **Status** | Draft for review |

### Version history

| Version | Date | Author | Description |
|---|---|---|---|
| 0.1 | 2026-07-15 | | Initial draft |
| 0.1.1 | 2026-09-22 | Marco Casavecchia | Consistency corrections aligned with FSD+TSD v0.3 and the ABAP reference code (superseded by the merged FSD+TSD) |

### Approvals

| Role | Name | Signature | Date |
|---|---|---|---|
| Business process owner | | | |
| Functional lead (MM/PP) | | | |
| Technical lead (ABAP) | | | |

---

## 1. Purpose and business background

The transfer from plant **8P01** to plant **8Q01** is **not** driven by any upstream/downstream manufacturing or supply relationship between the two plants. It is part of the **progressive migration approach** by which operations are being moved from **8P01** (the plant being wound down) to **8Q01** (the target plant). As production orders in 8P01 close out, the finished-goods stock they produce must be relocated to 8Q01 so that inventory follows the migration. There is no ongoing process reason to move material between these plants once the migration is complete.

Today these migration transfers are created manually (transaction **MB21**, movement type **301**), which is time-consuming and error-prone given the number of open orders being drained from 8P01.

This program automates the creation of **301 (transfer posting plant to plant, one step)** reservations in support of that migration. For every **open production order** in plant 8P01, it calculates the quantity still to be transferred and creates a reservation to move the finished (header) material from 8P01 to 8Q01. This gives target plant 8Q01 forward visibility of incoming stock and standardises the migration transfer process.

**How the reservation is consumed.** The reservation is not a one-off figure that is later posted manually. As the production order produces output, each **goods receipt (101)** posted against the PO immediately triggers a **physical 301 transfer** of the received quantity from 8P01 to 8Q01, posted *against the PO's reservation*. That real-time posting is delivered by a **companion object** (see FS-MM-301MOV-001, "GR-triggered automatic 301 transfer posting"). Because every unit received is immediately transferred, the reservation's remaining (open) quantity mirrors the production order's remaining (open) quantity at all times:

```
Reservation open  =  BDMNG − ENMNG   ≡   PSMNG − WEMNG  =  PO open
   (still to transfer)                       (still to produce/receive)
```

**Role of this program.** This FS covers only the **creation and ongoing alignment** of the reservation — it does *not* post goods movements (that is the companion object). Its job is to (a) create the 301 reservation when an open order first qualifies, and (b) on each run keep the reservation's requirement quantity aligned so that *reservation remaining = PO remaining*, correcting any drift (e.g. an order quantity change, scrap, or a goods receipt that was not yet transferred by the companion object). Because it recomputes alignment every run, it also acts as the **safety net** that catches any 301 the real-time posting failed to create.

> **Migration context, not process flow.** 8P01 → 8Q01 is a one-directional relocation for the migration window only. The program is therefore expected to be a transitional/temporary tool, run periodically until 8P01 is fully drained and decommissioned, rather than a permanent part of the steady-state process.

> **Movement type 301** = transfer posting, plant to plant, in one step. The reservation records a *planned* goods movement; the physical posting is performed later against the reservation (MIGO / MB1B / MFBF depending on the process).

---

## 2. Scope

### 2.1 In scope
- Selection of open production orders in issuing plant **8P01**.
- Determination of the open (still-to-transfer) quantity per order.
- Creation of one 301 transfer reservation per qualifying production order, header material only, from the **origin plant** to the **destination plant** — both plants and both storage locations are selection-screen **parameters** (defaults 8P01 → 8Q01).
- **Re-runnable alignment**: on each run, keep every reservation's remaining quantity equal to its production order's remaining quantity (`BDMNG − ENMNG = PSMNG − WEMNG`), adjusting the reservation requirement quantity when they drift, and closing the reservation when the order is complete/TECO.
- Interactive (online) execution with a selection screen and ALV result list.
- Background (batch) execution with an application log, schedulable as a periodic job.
- Test (simulation) run that reports the action (create/realign/close) that *would* be taken without posting.
- Duplicate protection so the same order is never reserved twice across runs.

### 2.2 Out of scope
- **Posting the physical 301 goods movement** — this is delivered by the companion object **FS-MM-301MOV-001** (GR-triggered automatic 301 transfer). This program only creates/aligns reservations; it never posts stock movements.
- BOM **component** reservations (only the production order **header/finished material** is transferred).
- Cross-company or intercompany STO logic; this is a single-step 301 transfer within the same company code.
- Any Fiori/UI5 front end (classic ALV report only).

---

## 3. Assumptions and dependencies

1. Movement type **301** is configured and permitted between plants 8P01 and 8Q01, and both plants belong to the same company code.
2. The header (finished) material of each production order has a valid material master (MRP, accounting, storage views) in **both** plants 8P01 and 8Q01.
3. A default **issuing storage location** (8P01) and **receiving storage location** (8Q01) are agreed and provided as configuration / selection defaults.
4. "Open production order" and "quantity produced but not received" are defined per Section 6.3.
5. Reservation base/requirement date defaults to the run date unless overridden (Section 6.2).
6. Standard BAPI **`BAPI_RESERVATION_CREATE1`** is used for reservation creation (Section 6.5).
7. A custom log/link table (Section 7.3) is created to relate each production order to the reservation generated, enabling duplicate prevention and reporting (RESB has no native production-order link for a 301 transfer reservation).
8. The 8P01 → 8Q01 transfer is a **migration relocation**, not an upstream/downstream process step. The program is transitional and will be retired once 8P01 is fully drained and decommissioned (no permanent steady-state role).

---

## 4. Process flow

```
                ┌─────────────────────────────────────────┐
                │ Start report (online or background job)   │
                └───────────────────┬───────────────────────┘
                                    ▼
        ┌────────────────────────────────────────────────────┐
        │ Read open production orders in plant 8P01           │
        │ (AUFK/AFKO/AFPO + status check)                     │
        └───────────────────┬────────────────────────────────┘
                            ▼
        ┌────────────────────────────────────────────────────┐
        │ For each order: PO open = PSMNG − WEMNG             │
        │ Read existing reservation: BDMNG, ENMNG            │
        │ Reservation open = BDMNG − ENMNG                   │
        └───────────────────┬────────────────────────────────┘
                            ▼
        ┌────────────────────────────────────────────────────┐
        │ Existing reservation for this order? (Z-log/RESB)   │
        └───┬───────────────────────────────────────────┬─────┘
            │ none                                        │ exists
            ▼                                             ▼
   ┌────────────────┐               ┌──────────────────────────────────┐
   │ PO open > 0 ?  │               │ Target BDMNG = PO open + ENMNG    │
   │  yes → CREATE  │               │ (keeps reservation open = PO open)│
   │  no  → skip    │               │  ≠ current BDMNG → REALIGN qty    │
   └───────┬────────┘               │  = current BDMNG → Unchanged      │
           │                        │  PO complete/TECO → CLOSE reserv. │
           │                        └────────────────┬─────────────────┘
           ▼                                         ▼
              ┌───────────────────────────────┐
              │ Test run?  Yes → report only   │
              │            No  → BAPI + COMMIT  │
              │                 + write Z-log   │
              └───────────────┬────────────────┘
                              ▼
        ┌────────────────────────────────────────────────────┐
        │ Output: ALV list (online) / Application log (batch) │
        └────────────────────────────────────────────────────┘

  Note: ENMNG (qty already transferred to 8Q01) grows via the companion
  GR-triggered 301 posting — NOT this program. Movements are expected and
  never lock the reservation against realignment.
```

---

## 5. Program attributes

| Attribute | Value (proposed) |
|---|---|
| Program name | `ZMM_R_CREATE_301_RESERV` |
| Program type | Executable report (type 1) |
| Transaction code | `ZMM301R` |
| Package / dev class | `Z_MM_INVENTORY` (to confirm) |
| Authorization group | (to confirm) |
| Message class | `ZMM301` (to create) |
| Application log object/subobject | `ZMM` / `Z301RES` (to create, for batch) |
| Detail log table | `ZMM_301_RESV_LOG` (Section 7.3) |
| Execution log table | `ZMM_301_RUN_LOG` (Section 7.4) |

---

## 6. Detailed functional requirements

### 6.1 Selection screen

| Field | Parameter | Technical ref | Type | Default | Mandatory | Notes |
|---|---|---|---|---|---|---|
| **Origin plant (from)** | `P_WERK_FR` | AUFK-WERKS / RESB-WERKS | Parameter | `8P01` | Yes | Issuing plant; fully parameterised, default 8P01 |
| **Origin storage location (from)** | `P_LGOR_FR` | RESB-LGORT | Parameter | (config) | No* | Source storage location in the origin plant |
| **Destination plant (to)** | `P_WERK_TO` | RESB-UMWRK | Parameter | `8Q01` | Yes | Receiving plant of the 301; fully parameterised, default 8Q01 |
| **Destination storage location (to)** | `P_LGOR_TO` | RESB-UMLGO | Parameter | (config) | No* | Destination storage location in the destination plant |
| Production order | | AUFK-AUFNR | Select-option | | No | Range of orders |
| Order type | | AUFK-AUART | Select-option | | No | e.g. restrict to PP order types |
| Material (header) | | AFPO-MATNR | Select-option | | No | Filter on finished material |
| MRP controller | | AFKO-DISPO | Select-option | | No | Optional restriction |
| Requirement/base date | | RKPF-RSDAT | Parameter | `sy-datum` | Yes | Reservation requirement date |
| Movement allowed flag | `P_MOVE` | — | Parameter | `X` | No | Reservation relevant for goods movement |
| **Test run (simulate)** | `P_TEST` | — | Checkbox | `X` | No | If set, no reservation is posted |
| Reprocess errors only | `P_ERRON` | — | Checkbox | ` ` | No | Reruns only orders logged with error status |
| **Self-reschedule (continuous)** | `P_SCHED` | — | Checkbox | ` ` | No | If set, the program reschedules its next run automatically (Section 6.9) |
| **Frequency value** | `P_FREQ` | — | Parameter (INT) | `5` | Cond. | Interval between runs; mandatory when self-reschedule is set |
| **Frequency unit** | `P_FUNIT` | — | Parameter (listbox) | `MIN` | Cond. | MIN / HRS / DAY — combined with the value gives 1 minute … multiple days |

\* If left blank the reservation stores no storage location and it is determined at goods-movement time; confirm the desired behaviour with the business.

**Selection-screen rules**
- One origin plant and one destination plant per run (single 301 direction); both are parameters (`P_WERK_FR`, `P_WERK_TO`) defaulting to 8P01 / 8Q01.
- Origin plant `P_WERK_FR` ≠ destination plant `P_WERK_TO`; error if equal.
- `P_WERK_FR` and `P_WERK_TO` must exist (T001W) and belong to the same company code; the storage locations, if entered, must exist for their respective plants (T001L).
- Requirement date may not be in the past (warning, allow override).
- Frequency value/unit are input-enabled and mandatory **only** when *Self-reschedule* is ticked; otherwise greyed out (`MODIF ID`).
- The effective interval (value × unit) must be **≥ 1 minute**; below the floor → error. Upper bound is validated against a configurable maximum (e.g. 30 days).
- Self-reschedule and *Test run* may be combined (a continuously running simulation), but the program warns that no postings will occur.

### 6.2 Defaulting and variants
- Delivered with a background variant `ZMM301R_JOB` (issuing 8P01, receiving 8Q01, test run = blank, self-reschedule = `X`, frequency = agreed default e.g. 5 MIN) for the scheduled job.
- Online users default to test run = `X` and self-reschedule = blank (single run) to encourage a simulation before the live run.

### 6.3 Open production order determination

An order **qualifies** when **all** of the following are true:

1. `AUFK-WERKS = 8P01` (issuing plant) and matches other selection filters.
2. Order **system status** is *released* and **not** technically complete/closed/deletion-flagged:
   - Released: status **REL** set.
   - Excluded: **TECO** (technically complete), **CLSD** (closed), **DLFL/LKD** (deletion flag / locked), **DLV** where fully delivered.
   - Status read via `STATUS_READ` / status table (JEST/JCDS against order object number `AUFK-OBJNR`), or the equivalent released/completion CDS status fields.
3. **Delivery completed** indicator not set at item level: `AFPO-ELIKZ = ' '`.
   - Exception – **close candidates**: orders that are delivered (`ELIKZ` set) or TECO/CLSD/deletion-flagged but still hold an **open** 301 reservation (`BDMNG > ENMNG`) are selected as well, for the *Close* action only. Such orders with no open reservation are ignored (never a new reservation, not logged).
4. **Open quantity > 0** per Section 6.4.

### 6.4 Open (transfer) quantity calculation

Per selected requirement ("Order qty − received qty"):

```
open_qty (per order item) = AFPO-PSMNG  −  AFPO-WEMNG
```

Where:
- `AFPO-PSMNG` = order item target/production quantity.
- `AFPO-WEMNG` = quantity already delivered/received (goods receipt, 101) for the order.

Rules:
- Header material is `AFPO-MATNR`; unit of measure `AFPO-MEINS` (base UoM of order item).
- If `open_qty ≤ 0` and no reservation exists, skip the order (already fully received → nothing to transfer).
- If the order has multiple items, use the header/finished-goods item (typically item 0001); confirm handling of multi-item orders in Open Issues (Section 12).
- Round/convert to the reservation entry UoM if different (should match base UoM).

**Alignment target for the reservation requirement quantity.** The reservation's *remaining* quantity must always equal the PO's *remaining* quantity. Because the reservation is progressively consumed by physical 301 movements (`ENMNG` = quantity already transferred, posted by the companion object), the reservation's total requirement quantity must be set to:

```
target BDMNG = PO open + already transferred
             = (PSMNG − WEMNG) + ENMNG
```

so that `reservation open = BDMNG − ENMNG = PSMNG − WEMNG = PO open`. At first creation `ENMNG = 0`, so the initial requirement quantity is simply the PO open qty (`PSMNG − WEMNG`).

> **Note on wording.** "Quantity produced but not received" was mapped in requirements review to *order quantity minus received (GR) quantity* = the open balance. As goods receipts are posted and immediately transferred, both the PO open and the reservation open shrink together, staying aligned.

### 6.5 Reservation creation — BAPI mapping

One reservation (one item) is created per qualifying order using **`BAPI_RESERVATION_CREATE1`**, followed by **`BAPI_TRANSACTION_COMMIT`** (`WAIT = 'X'`).

**Header — `RESERVATIONHEADER` (BAPI2093_RES_HEAD_C1)**

| BAPI field | Source / value | Notes |
|---|---|---|
| `RES_DATE` | Selection: requirement/base date | Default `sy-datum` |
| `MOVEMENT` | Selection: movement allowed flag (`X`) | Reservation relevant for goods movement |

**Item — `RESERVATIONITEMS` (BAPI2093_RES_ITEM_C1)**

| BAPI field | Source / value | Notes |
|---|---|---|
| `MATERIAL_LONG` (`MATERIAL`) | `AFPO-MATNR` | Header/finished material (use `MATERIAL_LONG` on S/4) |
| `PLANT` | `P_WERK_FR` (default 8P01) | Origin plant (parameter) |
| `STGE_LOC` | `P_LGOR_FR` | Origin storage location (parameter, optional) |
| `MOVE_TYPE` | `301` | Transfer posting plant to plant |
| `ENTRY_QNT` | `open_qty` (Section 6.4) | Quantity to transfer |
| `ENTRY_UOM` | `AFPO-MEINS` | Base UoM |
| `REQ_DATE` | Requirement date | Item requirement date |
| `MOVE_PLANT` | `P_WERK_TO` (default 8Q01) | Destination plant (parameter) |
| `MOVE_STLOC` | `P_LGOR_TO` | Destination storage location (parameter, optional) |
| `BATCH` / `MOVE_BATCH` | (blank) | Only if material is batch-managed — see Open Issues |
| `GR_RCPT` / `UNLOAD_PT` | (optional) | If business requires recipient/unloading point |

**Reference to the source production order.** The 301 transfer reservation has no standard field linking it back to the production order. To preserve the link:
- Write the order number to the item text `SGTXT` (via the log flow / `RESB-SGTXT` where available), **and**
- Persist the mapping in the custom log table `ZMM_301_RESV_LOG` (Section 7.3), which is the authoritative link used for duplicate checks and reporting.

**Realigning / closing an existing reservation.** When the decision matrix (Section 6.6) yields *Realign* or *Close*, the existing reservation item requirement quantity (`BDMNG`) is changed to `target BDMNG = PO open + ENMNG` (Close is the special case `target = ENMNG`), rather than creating a new reservation:
- Preferred: standard reservation-change BAPI `BAPI_RESERVATION_CHANGE` (confirm availability in the target S/4HANA release), passing the reservation number/item and the new required quantity.
- If a released change BAPI is not available in the release, use the SAP reservation maintenance function module used by MB22, or a controlled MB22 transaction call, wrapped so per-order error isolation and commit behaviour are preserved.
- The reservation is realigned even when it has already been partly transferred (`ENMNG > 0`); the requirement quantity is always allowed to move so long as it is not set below `ENMNG`.

**Post-processing**
- Read `RETURN` (BAPIRET2). On any `E`/`A` message: do **not** commit; issue `BAPI_TRANSACTION_ROLLBACK`; log the order as error.
- On create success: capture the returned reservation number (`RESERVATION`, i.e. `RSNUM`); commit; write/refresh log entry with status *Created*.
- On realign/close success: commit; refresh the log entry (new qty, status *Realigned* / *Closed*).
- Test run: build the same proposed action (create/realign/close) and display it, but **do not** call any BAPI or commit.

### 6.6 Alignment logic (create / realign / close)

The program is designed to be **run repeatedly**. On every run it re-evaluates **all** open production orders and keeps each order's reservation aligned so that *reservation remaining = PO remaining*. It never creates a duplicate; for each order it decides between **create**, **realign**, **close**, or leave **unchanged**.

For each open order, read the current PO figures (`PSMNG`, `WEMNG`) and any existing reservation (`BDMNG`, `ENMNG`, `KZEAR`) via `ZMM_301_RESV_LOG` cross-checked against `RESB`. Note that `ENMNG` (quantity already transferred to 8Q01) is driven by the **companion GR-triggered 301 posting**, not by this program — a non-zero `ENMNG` is normal and does **not** lock the reservation.

Compute:
```
PO open       = PSMNG − WEMNG
target BDMNG  = PO open + ENMNG        (so reservation open = BDMNG − ENMNG = PO open)
```

**Decision matrix**

| Existing reservation? | Condition | Action | Status |
|---|---|---|---|
| No | PO open > 0 | **Create** 301 reservation, `BDMNG = PO open` | Created |
| No | PO open ≤ 0 | Skip – nothing to transfer | Fully received |
| Yes | Order **complete** (PO open = 0) and reservation fully consumed (`ENMNG = BDMNG`) | None – already complete (`KZEAR` set) | Complete |
| Yes | Order **complete / TECO / CLSD** but reservation not fully consumed | **Close** reservation: set `BDMNG = ENMNG` (final-issue) so no phantom demand remains | Closed |
| Yes | `target BDMNG ≠ current BDMNG` | **Realign**: change reservation requirement to `target BDMNG` | Realigned |
| Yes | `target BDMNG = current BDMNG` | Leave unchanged | Unchanged |

Notes:
- **Realign** covers all normal drift: the usual cause is simply that goods receipts (and their auto-transfers) have progressed since the reservation was last touched, or the order quantity/scrap changed. Setting `BDMNG = PO open + ENMNG` restores exact alignment regardless of how much has already been transferred.
- Realignment is valid **even after** movements have been posted (`ENMNG > 0`); there is no "locked" state. This is the key difference from a create-once design.
- **Drift safety net.** If the companion object failed to post a 301 for some goods receipt, then `WEMNG > ENMNG` for that order and the reservation open (`= PO open`) will still correctly reflect the outstanding quantity to transfer, flagging it for follow-up. (Optionally report orders where `WEMNG − ENMNG > 0` as a warning so the missed transfer is investigated.)

**Restart / reprocessing**
- "Reprocess errors only" reruns only orders logged with status *Error*.
- The program is fully **restartable and idempotent**: rerunning it re-converges each order's reservation to `BDMNG = PO open + ENMNG` without creating duplicates.

### 6.7 Online output (ALV)

Display a `CL_SALV_TABLE` / ALV grid with at least:

| Column | Source |
|---|---|
| Production order | AUFK-AUFNR |
| Order type | AUFK-AUART |
| Header material | AFPO-MATNR |
| Order qty | AFPO-PSMNG |
| Received qty | AFPO-WEMNG |
| Open (transfer) qty | calculated |
| UoM | AFPO-MEINS |
| Origin plant | `P_WERK_FR` (8P01) |
| Destination plant | `P_WERK_TO` (8Q01) |
| Reservation number | RSNUM (blank in test run) |
| PO open qty | PSMNG − WEMNG |
| Reserved qty (BDMNG before) | RESB-BDMNG |
| Transferred qty (ENMNG) | RESB-ENMNG |
| Target reserved qty | PO open + ENMNG |
| Action / Status | Created / Realigned / Closed / Unchanged / Complete / Fully received / Simulated / Error |
| Message | BAPI return message text |

Features: sort/filter/total on quantities, status colour coding (green/yellow/red), traffic-light status column, hotspot on reservation number to `MB23` (display reservation) and on order to `CO03`.

### 6.8 Background execution and logging
- Schedulable via SM36/`SUBMIT` with variant `ZMM301R_JOB`.
- In batch: suppress ALV; write results to the **Application Log** (object `ZMM`, subobject `Z301RES`) using `BAL_LOG_*` APIs, plus a summary write to the spool (list output) for the job log.
- Log at minimum: count selected, created, realigned, closed, unchanged, skipped, drift, errors, and per-order messages.
- Every execution (online or background) writes an **execution-log header** to `ZMM_301_RUN_LOG` (Section 7.4): a *Running* row at start, updated with the roll-up counts, end time and final status on completion. This gives an auditable "who ran what, when, and with what result" history, with drill-down to the per-order detail via `RUN_ID`.

### 6.9 Execution frequency and self-scheduling

The frequency at which the program runs in the background is **managed as a parameter** (frequency value + unit, Section 6.1), supporting a range from **1 minute** to **multiple days**. The 1-minute floor deliberately matches SAP's minimum standard periodic-job period, so two implementation options are available; the choice is confirmed with Basis (Open Issue O8):

**Option A — Self-rescheduling job (parameter-driven, recommended).**
- The program runs, and at the **end** of each run — if *Self-reschedule* is ticked — it schedules its own next execution at `end-time + interval`, submitting the same program/variant via `JOB_OPEN` → `SUBMIT … VIA JOB` → `JOB_CLOSE` (with `SDLSTRT` = next start timestamp).
- Because the next run is only scheduled **after** the current one finishes, runs **never overlap**, even if a run takes longer than the interval (a slow run simply pushes the next start out — self-throttling).
- The frequency lives entirely in the program parameter/variant, so it can be changed without touching the job definition.

**Option B — Standard SM36 periodic job.**
- A conventional periodic job with the period set to the same interval (≥ 1 minute). Simpler operationally, but the frequency is held in the job definition rather than the program parameter, and overlap protection must be handled by the "do not start if predecessor still active" job option.

**Common rules (both options)**
- **Stop switch.** Before self-rescheduling (Option A) the program checks a control flag (e.g. `ZMM_301_CTRL.ACTIVE` / a dedicated run-control entry). If inactive, it does **not** reschedule and logs *chain stopped*, so operations can halt the loop cleanly without killing a running job. (For Option B, deactivating the flag makes each run a no-op; the job is removed in SM37 to stop entirely.)
- **Overlap / lock safety.** A single-instance guard (enqueue lock on a program key) prevents two runs executing simultaneously; a second start exits immediately with a logged message.
- **Optional active window.** Confirm whether the loop should run only within a time window / on certain days (Open Issue O8); if so, add earliest/latest time and weekday parameters.
- The chosen interval and the computed next-run timestamp are written to the execution log (`ZMM_301_RUN_LOG`, Section 7.4) for traceability.

---

## 7. Data model

### 7.1 Source tables (read)

| Table | Key fields used | Purpose |
|---|---|---|
| `AUFK` | AUFNR, WERKS, AUART, OBJNR | Order master / plant / status object |
| `AFKO` | AUFNR, GAMNG, DISPO, PLNBEZ | Order header (qty, MRP controller) |
| `AFPO` | AUFNR, POSNR, MATNR, PSMNG, WEMNG, ELIKZ, MEINS | Order item qty & delivery status |
| `JEST` / status API | OBJNR, STAT, INACT | Order system status (REL/TECO/CLSD/DLV) |
| `MARC` | MATNR, WERKS | Verify material exists in 8P01 and 8Q01 |
| `RESB` / `RKPF` | RSNUM, RSPOS, BDMNG, ENMNG, KZEAR | Existing reservation lookup: requirement qty (`BDMNG`), already-transferred qty (`ENMNG`) and final-issue flag (`KZEAR`) drive the create/realign/close decision (Section 6.6). Reservation open = `BDMNG − ENMNG` must equal PO open |

> On S/4HANA these reads may equivalently use released CDS views (e.g. production-order and material CDS) to avoid direct AFPO/AFKO joins; final choice in Technical Spec.

### 7.2 Target (create)
- Reservation header/item (`RKPF` / `RESB`) via `BAPI_RESERVATION_CREATE1`.

### 7.3 Custom log table `ZMM_301_RESV_LOG`

| Field | Key | Type (proposed) | Description |
|---|---|---|---|
| MANDT | X | CLNT | Client |
| AUFNR | X | AUFNR | Production order |
| POSNR | X | CO_POSNR | Order item |
| RUN_ID | X | (GUID/timestamp) | Run identifier |
| RSNUM | | RSNUM | Reservation number created |
| WERKS_FR | | WERKS_D | Issuing plant (8P01) |
| WERKS_TO | | WERKS_D | Receiving plant (8Q01) |
| MATNR | | MATNR | Header material |
| RSPOS | | RSPOS | Reservation item |
| WERKS_FR | | WERKS_D | Issuing plant (8P01) |
| WERKS_TO | | WERKS_D | Receiving plant (8Q01) |
| MATNR | | MATNR | Header material |
| PO_OPEN | | MENGE_D | PO open qty (PSMNG − WEMNG) at the run |
| RES_BDMNG | | MENGE_D | Reservation requirement qty after the run |
| RES_ENMNG | | MENGE_D | Reservation quantity already transferred |
| MEINS | | MEINS | Unit |
| STATUS | | CHAR1 | C=Created / R=Realigned / X=Closed / N=Unchanged / F=Complete / K=Fully received / E=Error / S=Simulated |
| MESSAGE | | STRING | Return message |
| ERDAT | | DATS | Created on |
| ERZET | | TIMS | Created at |
| ERNAM | | UNAME | Created by |

`RUN_ID` links every detail row back to the execution-log header in `ZMM_301_RUN_LOG` (Section 7.4).

### 7.4 Execution log table `ZMM_301_RUN_LOG`

One row per program execution (online or background). It is the header/audit record of *when the program ran, how, and with what outcome*; the per-order detail lives in `ZMM_301_RESV_LOG` keyed by the same `RUN_ID`.

| Field | Key | Type (proposed) | Description |
|---|---|---|---|
| MANDT | X | CLNT | Client |
| RUN_ID | X | CHAR32 / SYSUUID | Unique run identifier (GUID or date-time-counter) |
| RUN_MODE | | CHAR1 | O=Online / B=Background |
| JOBNAME | | BTCJOB | Background job name (if any) |
| JOBCOUNT | | BTCJOBCNT | Background job count (if any) |
| VARIANT | | RALDB_VARI | Selection variant used |
| WERKS_FR | | WERKS_D | Issuing plant (8P01) |
| WERKS_TO | | WERKS_D | Receiving plant (8Q01) |
| SEL_TEXT | | STRING | Human-readable snapshot of key selection criteria (order range, order type, MRP controller, req. date) |
| TEST_RUN | | CHAR1 | X = simulation, no postings |
| SELF_SCHED | | CHAR1 | X = self-rescheduling run (Section 6.9) |
| FREQ_VALUE | | INT4 | Frequency value |
| FREQ_UNIT | | CHAR3 | MIN / HRS / DAY |
| NEXT_RUN_DT | | DATS | Next run scheduled date (self-reschedule) |
| NEXT_RUN_TM | | TIMS | Next run scheduled time (self-reschedule) |
| START_DATE | | DATS | Run start date |
| START_TIME | | TIMS | Run start time |
| END_DATE | | DATS | Run end date |
| END_TIME | | TIMS | Run end time |
| DURATION_S | | INT4 | Runtime in seconds |
| CNT_SELECTED | | INT4 | Orders selected |
| CNT_CREATED | | INT4 | Reservations created |
| CNT_REALIGNED | | INT4 | Reservations realigned |
| CNT_CLOSED | | INT4 | Reservations closed |
| CNT_UNCHANGED | | INT4 | Already aligned, no change |
| CNT_SKIPPED | | INT4 | Skipped (fully received / no qty) |
| CNT_DRIFT | | INT4 | Orders with `WEMNG − ENMNG > 0` (missed transfer) flagged |
| CNT_ERROR | | INT4 | Orders in error |
| STATUS | | CHAR1 | S=Success / W=Completed with errors / A=Aborted / R=Running |
| BALLOGNR | | BALOGNR | Application-log number (batch) for drill-down |
| ERNAM | | UNAME | Executed by |
| MESSAGE | | STRING | Summary / abort reason |

Behaviour:
- A header row is written with `STATUS = 'R'` (Running) at start, then updated with counts, end time, duration and final status on completion (or on error/abort).
- Counts are the roll-up of the per-order statuses written to `ZMM_301_RESV_LOG` for the same `RUN_ID`.
- The ALV list and the batch application log both reference the `RUN_ID`, so any run can be reconstructed end-to-end.
- Retention/housekeeping: a simple reorg (delete runs older than N days, keep error runs longer) — parameters in Open Issues.

---

## 8. Error handling and messages

| # | Condition | Type | Message (class `ZMM301`) | Program action |
|---|---|---|---|---|
| 1 | Issuing = receiving plant | E | "Issuing and receiving plant must differ" | Stop before selection |
| 2 | No open orders found | S/I | "No open production orders for the selection" | End with info |
| 3 | Header material not maintained in 8Q01 | E (per order) | "Material &1 not maintained in receiving plant &2" | Skip order, log error |
| 4 | Open qty ≤ 0 | I (per order) | "Order &1 fully received – skipped" | Skip, log |
| 5 | Reservation already exists (log) | I (per order) | "Order &1 already reserved (&2)" | Skip, log |
| 6 | BAPI returns E/A | E (per order) | Propagate BAPI text | Rollback, log error |
| 7 | Commit failure | E | "Commit failed for order &1" | Rollback, log error |

Global rule: **one order = one LUW**. A failure on one order must never roll back successfully-created reservations of other orders (commit per order, or controlled package commit with per-order rollback on error).

---

## 9. Authorizations

| Object | Fields | Purpose |
|---|---|---|
| `M_MRES_WWA` | ACTVT=01 (create) / 02 (change), WERKS=8P01 and 8Q01 | Reservations: plant |
| `M_MRES_BWA` | ACTVT=01 / 02, BWART=301 | Reservations: movement type |
| `C_AFKO_AWK` (or equivalent) | order type / plant | Read production orders (if enforced) |
| Program/txn auth `S_TCODE` | ZMM301R | Execute the report |

The program performs an explicit `AUTHORITY-CHECK` on movement/plant before creating reservations and fails the order (logged) if the user is not authorised.

---

## 10. Performance considerations
- Set-based reads: select orders once with joined/bulk `SELECT ... FOR ALL ENTRIES` or CDS; avoid per-order singleton reads inside loops.
- Batch status/material checks (JEST, MARC) up front into hashed internal tables.
- Commit strategy: commit per order (safest for restart) or in packages of N (e.g. 200) with per-order error isolation — confirm in Technical Spec based on volume.
- Expected volume: (to confirm — number of open orders per run) drives the package size and job frequency.

---

## 11. Test cases

| # | Scenario | Expected result |
|---|---|---|
| T1 | Open order, qty remaining > 0, test run = X | ALV shows proposed reservation, status *Simulated*, nothing posted |
| T2 | Same order, live run | Reservation created (301, 8P01→8Q01), `BDMNG = PO open`, RSNUM shown, log = *Created* |
| T3 | Rerun T2 order, nothing changed | No duplicate; `target BDMNG = current`; status *Unchanged* |
| T3b | Rerun after a GR was received **and** auto-transferred (ENMNG grew equally) | `PO open` and reservation open both dropped equally; `target BDMNG = PO open + ENMNG` = unchanged → *Unchanged* (stays aligned automatically) |
| T3c | Rerun after a GR was received but the auto-301 **failed** (WEMNG grew, ENMNG did not) | Reservation open still = PO open; drift warning raised (`WEMNG − ENMNG > 0`) so the missed transfer is followed up |
| T3d | Rerun after order quantity increased / decreased | Reservation **realigned** to `PO open + ENMNG`; status *Realigned* |
| T3e | Order set to TECO/complete with reservation not fully consumed | Reservation **closed** (`BDMNG = ENMNG`); status *Closed* |
| T4 | Fully received order (PSMNG = WEMNG), no reservation | Skipped, status *Fully received* |
| T5 | TECO / CLSD order | Not selected |
| T6 | Material not in 8Q01 | Error logged, other orders unaffected |
| T7 | Issuing = receiving plant | Hard error, program stops |
| T8 | Background job with variant | Application log written, spool summary, reservations created |
| T8a | Self-reschedule ON, frequency 1 MIN | After each run the next run is scheduled ~1 min later; runs never overlap; `NEXT_RUN` logged |
| T8b | Frequency below floor (< 1 min) | Selection-screen error; run rejected |
| T8c | Stop switch (`ZMM_301_CTRL.ACTIVE` off) during a self-reschedule chain | Current run completes, no next run scheduled, logged *chain stopped* |
| T8d | Run overruns its interval | Next run scheduled only after completion (self-throttling); no overlap |
| T9 | Multiple open orders, one fails | Others still committed; failed one logged as error |
| T10 | "Reprocess errors only" after T9 | Only previously-failed order retried |
| T11 | Requirement date override | Reservation carries the entered date |
| T12 | Unauthorised user (no 8Q01) | Order(s) failed with authorisation error, logged |

---

## 12. Open issues / decisions pending

| # | Item | Owner | Status |
|---|---|---|---|
| O1 | Confirm default issuing/receiving storage locations, and whether storage location is mandatory on the reservation | Business/MM | Open |
| O2 | Multi-item production orders — is only item 0001 transferred, or each finished item? | PP | Open |
| O3 | Batch-managed header materials — how is the batch determined for the 301 reservation? | MM/PP | Open |
| O4 | Confirm availability of a released `BAPI_RESERVATION_CHANGE` in the target release; otherwise agree the MB22 FM/BDC fallback for realign/close | ABAP/Basis | Open |
| O4b | Exact mechanism to "close" a reservation on order completion/TECO (set `BDMNG = ENMNG` / final-issue flag vs deletion indicator) | MM | Open |
| O4c | Should the alignment program also raise an alert/report when `WEMNG − ENMNG > 0` (a goods receipt not yet transferred by the companion object)? Recommended yes | Business | Open |
| O5 | Job frequency and expected volume (performance sizing) | Basis/Business | Open |
| O6 | Requirement date logic — run date vs order scheduled finish (`AFKO-GLTRP`) | PP | Open |
| O7 | Handling of co-products / alternate finished materials | PP | Open |
| O8 | Confirm scheduling approach (self-rescheduling job vs standard SM36 periodic), and whether an active time-window/weekday restriction is required | Basis/Business | Open |

---

## 13. Appendix

### 13.1 Glossary
- **301** – Movement type: transfer posting plant to plant, one step.
- **Reservation** – Planned goods movement recorded in `RKPF`/`RESB`; here movement-relevant so it can be posted later.
- **Open order** – Released production order, not TECO/CLSD/deletion-flagged, with order qty not yet fully received.
- **Open qty** – `AFPO-PSMNG − AFPO-WEMNG`.
- **LUW** – Logical Unit of Work: an all-or-nothing sequence of database updates ending in COMMIT or ROLLBACK.

### 13.2 Key objects
- BAPI: `BAPI_RESERVATION_CREATE1` (create), `BAPI_RESERVATION_CHANGE` (realign/close, subject to release check — Open Issue O4), `BAPI_RESERVATION_GETDETAIL` / `BAPI_RESERVATION_GETITEMS` (read), `BAPI_TRANSACTION_COMMIT`, `BAPI_TRANSACTION_ROLLBACK`.
- Companion object: **FS-MM-301MOV-001** — GR-triggered automatic 301 transfer posting (posts the physical stock movement that consumes these reservations).
- Transactions referenced: MB21/MB22/MB23 (reservations), CO03 (display order), MIGO/MB1B (post 301).
