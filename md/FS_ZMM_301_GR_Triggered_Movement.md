# Functional Specification
## GR-Triggered Automatic 301 Transfer Posting (8P01 → 8Q01)

| | |
|---|---|
| **Document ID** | FS-MM-301MOV-001 |
| **Object description** | On each goods receipt against a production order in plant 8P01, automatically post a 301 transfer of the received quantity to plant 8Q01, against the PO's reservation |
| **SAP solution** | S/4HANA on-premise |
| **Module** | MM (Inventory Management – goods movements) |
| **RICEFW type** | Enhancement (BAdI) + supporting objects |
| **Complexity** | Medium–High |
| **Companion object** | FS-MM-301RES-001 (301 reservation creation & alignment) |
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

As part of the **progressive migration** of operations from plant **8P01** (being wound down) to plant **8Q01** (target), finished-goods stock produced in 8P01 must be relocated to 8Q01 as it is produced. The companion object **FS-MM-301RES-001** creates and maintains a **301 transfer reservation** per open production order, sized to the order's open quantity.

This object delivers the **physical movement** side: whenever a **goods receipt (movement type 101)** is posted against a production order in 8P01, the received quantity is **immediately** transferred (movement type **301**) from 8P01 to 8Q01, **against the PO's reservation**. This keeps stock physically flowing to the target plant in lockstep with production, and keeps the reservation's remaining quantity aligned with the order's remaining quantity:

```
GR of X (101) on PO  →  immediately post 301 of X (8P01 → 8Q01) against the PO reservation
  ⇒ WEMNG += X  (PO received)      and      ENMNG += X  (reservation transferred)
  ⇒ PO open (PSMNG − WEMNG)  stays equal to  reservation open (BDMNG − ENMNG)
```

> **Immediate = triggered by the GR posting.** The transfer is fired by the material-document posting event, not by a periodic scan, so 8Q01 receives the stock essentially as soon as it is produced.

---

## 2. Scope

### 2.1 In scope
- Detect goods receipts (mvt **101**) posted against a production order in issuing plant **8P01** for the order's **header/finished material**.
- Automatically post a **301** transfer of the received quantity from 8P01 to 8Q01, referencing the PO's 301 reservation so the reservation is consumed (`ENMNG` updated).
- **Failure isolation**: a failed 301 must never roll back or block the goods receipt.
- **Idempotency**: each goods-receipt item triggers exactly one 301 (no double-posting on reprocessing/retries).
- **Reversal handling**: a cancelled/reversed goods receipt (102) triggers a matching reverse transfer (302).
- Carry the goods-receipt **batch** (for batch-managed materials) into the transfer.
- Post the 301 with the **destination valuation type of the current fiscal year** (origin plant is not split-valuated; only the receiving side carries a valuation type) — Section 6.7a.
- A control (configuration) table so the automation is scoped to the 8P01→8Q01 migration and can be switched off at migration end.
- An **application-log monitor** and a small **repost/catch-up** utility for transfers that failed at GR time.

### 2.2 Out of scope
- Creating or resizing the reservation (owned by **FS-MM-301RES-001**).
- Goods receipts in plants other than 8P01, or not against a production order.
- Component (non-header) materials.
- The steady-state process after migration (the automation is transitional and controlled by the config table).

---

## 3. Assumptions and dependencies

1. A suitable standard enhancement exists to run logic at material-document posting. **`MB_DOCUMENT_BADI`** (interface `IF_EX_MB_DOCUMENT_BADI`) is the intended enhancement; its availability and suitability in the target release is confirmed in build (Open Issue M1). Legacy exit `MB_CF001` is the fallback.
2. The 301 reservation for the PO already exists (created by FS-MM-301RES-001) at the time the GR is posted. Handling when it does **not** yet exist is defined in Section 6.2.
3. Movement type **301** is configured and allowed between 8P01 and 8Q01 (same company code), and the header material exists in both plants.
4. After the 101 GR, the received quantity is in a stock type/storage location in 8P01 from which a 301 can immediately be posted (Open Issue M2 covers QI/blocked stock).
5. Posting the 301 in a **separate LUW immediately after** the GR commit is acceptable as "immediate" (sub-second), in exchange for full failure isolation (Section 6.4).
6. A technical/background user context and authorizations are available to post the 301 (Section 9).
7. The material is **split-valuated only in the destination plant (8Q01)**; the origin plant (8P01) does not manage valuation types. Each destination valuation type corresponds to a fiscal year, defined in the correspondence table `ZMM_301_VALTYPE` (Section 7.5), with a valid entry for every fiscal year in which GRs may be posted. Because the origin is not split-valuated, no valuation-type mismatch can occur.

---

## 4. Process flow (event-driven)

```
   User/CO11N/MFBF posts GR (101) against production order in 8P01
                        │
                        ▼
        ┌───────────────────────────────────────────┐
        │ Material document posts (COMMIT WORK)       │
        │ MB_DOCUMENT_BADI fires                       │
        └───────────────────┬─────────────────────────┘
                            ▼
        ┌───────────────────────────────────────────┐
        │ For each doc item: is it a 101 GR,          │
        │ plant 8P01, against a production order,     │
        │ header material, in scope (config table)?   │
        └───────┬─────────────────────────┬───────────┘
             no │                          │ yes
                ▼                          ▼
        ┌──────────────┐   ┌───────────────────────────────────┐
        │ ignore item  │   │ Register follow-on 301 posting     │
        └──────────────┘   │ (queued unit / bgRFC) to run right │
                           │ AFTER the GR commit — separate LUW │
                           └───────────────┬───────────────────┘
                                           ▼ (immediately after commit)
        ┌───────────────────────────────────────────────────────┐
        │ Determine PO reservation (Z-log / RESB)                │
        │ Resolve current-FY dest. valuation type                 │
        │   (posting date → GJAHR → ZMM_301_VALTYPE)              │
        │ Build 301: origin→dest, qty = GR qty, batch = GR batch, │
        │   VAL_TYPE_MOVE = current-FY type, ref reservation item │
        │ Duplicate check (ZMM_301_MOV_LOG by source doc/item)   │
        └───────────────┬───────────────────────────┬───────────┘
                success │                            │ error
                        ▼                            ▼
        ┌───────────────────────────┐   ┌───────────────────────────┐
        │ BAPI_GOODS_MOVEMENT_CREATE │   │ Log error (App Log).       │
        │ GM_CODE 04 (301) + COMMIT  │   │ Do NOT roll back the GR.   │
        │ Write ZMM_301_MOV_LOG      │   │ Flag for repost/monitor.   │
        └───────────────────────────┘   └───────────────────────────┘
```

Reversal path: a **102** (GR cancellation) for a source document that previously produced a 301 → post the matching **302** reverse transfer (Section 6.5).

---

## 5. Object attributes

| Attribute | Value (proposed) |
|---|---|
| BAdI | `MB_DOCUMENT_BADI` (interface `IF_EX_MB_DOCUMENT_BADI`, method `MB_DOCUMENT_BEFORE_UPDATE`) |
| BAdI implementation | `ZMM_301_GR_TRIGGER` |
| Posting function (queued/bgRFC unit) | `Z_MM_301_POST_TRANSFER` |
| Repost/monitor report | `ZMM_R_301_MOV_MONITOR` / txn `ZMM301M` |
| Config table | `ZMM_301_CTRL` (Section 7.1) |
| Valuation-type mapping | `ZMM_301_VALTYPE` (Section 7.5) |
| Movement log table | `ZMM_301_MOV_LOG` (Section 7.2) |
| Execution log table | `ZMM_301_MOV_RUN_LOG` (Section 7.4) — monitor/repost/catch-up runs |
| Message class | `ZMM301` (shared with FS-MM-301RES-001) |
| Application log object/subobject | `ZMM` / `Z301MOV` |
| Package | `Z_MM_INVENTORY` |

---

## 6. Detailed functional requirements

### 6.1 Trigger and detection

- Implement `MB_DOCUMENT_BADI` → `MB_DOCUMENT_BEFORE_UPDATE` (called in the posting LUW immediately **before** the update task is triggered — not in the update task, which is `MB_DOCUMENT_UPDATE`; receives the document tables `XMKPF`/`XMSEG`).
- For each `XMSEG` item, select for processing only when **all** hold:
  - Movement type `BWART = '101'` (goods receipt).
  - Plant `WERKS = 8P01` (or the issuing plant in `ZMM_301_CTRL`).
  - Production order populated (`AUFNR ≠ ' '`), i.e. GR from a production order (covers MIGO 101, MB31, CO11N auto-GR, MFBF backflush).
  - Material = the production order's **header/finished material** (skip by-products/co-products — Open Issue M3).
  - The plant pair and material scope are **active** in `ZMM_301_CTRL`.
- Reversals (`BWART = '102'`) are collected for the reverse path (Section 6.5).
- Items not matching are ignored.

> Detection must be movement-type and order driven, not transaction driven, so that every channel that produces a 101 GR against the order is covered.

### 6.2 Reservation determination

- Determine the PO's 301 reservation via the link table `ZMM_301_RESV_LOG` (maintained by FS-MM-301RES-001): `AUFNR` → `RSNUM`/`RSPOS`.
- Validate against `RESB` that the reservation item is open (`BDMNG − ENMNG > 0`) and matches material/plant/receiving plant.
- **If no reservation exists yet** for the order (timing gap): configurable behaviour —
  - Default: still post the 301 (8P01→8Q01) **without** a reservation reference, and log a warning so FS-MM-301RES-001 aligns on its next run; **or**
  - Alternative: skip the transfer and rely on the alignment program's drift detection.
  - Decision recorded in Open Issue M4.

### 6.3 301 movement build — `BAPI_GOODS_MOVEMENT_CREATE`

Post the transfer with `GOODSMVT_CODE = '04'` (transfer posting / MB1B).

**Header — `GOODSMVT_HEADER`**

| Field | Value |
|---|---|
| `PSTNG_DATE` | GR posting date (`XMKPF-BUDAT`) |
| `DOC_DATE` | GR document date |
| `HEADER_TXT` | e.g. "Auto 301 vs GR &MBLNR" |
| `REF_DOC_NO` | Source GR material document number |

**Item — `GOODSMVT_ITEM`**

| Field | Value | Notes |
|---|---|---|
| `MOVE_TYPE` | `ZMM_301_CTRL-MOVE_TYPE` (default 301) | Transfer posting plant to plant |
| `MATERIAL_LONG` | GR item material | Header material |
| `PLANT` | `ZMM_301_CTRL-WERKS_FR` (default 8P01) | Origin plant (config) |
| `STGE_LOC` | GR storage location, else `ZMM_301_CTRL-LGORT_FR` | Origin stor. loc. |
| `MOVE_PLANT` | `ZMM_301_CTRL-WERKS_TO` (default 8Q01) | Destination plant (config) |
| `MOVE_STLOC` | `ZMM_301_CTRL-LGORT_TO` | Destination stor. loc. |
| `ENTRY_QNT` | GR quantity (`XMSEG-MENGE`) | Quantity received |
| `ENTRY_UOM` | GR UoM | |
| `BATCH` / `MOVE_BATCH` | GR batch (`MSEG-CHARG`) | For batch-managed materials, carry the same batch |
| `VAL_TYPE` | **blank** | Origin (8P01) is not split-valuated — no valuation type |
| `VAL_TYPE_MOVE` | Current-FY valuation type (Section 6.7a) | Destination (8Q01) valuation type from `ZMM_301_VALTYPE` |
| `RESERV_NO` / `RES_ITEM` | From Section 6.2 | Consume the PO reservation (updates `ENMNG`) |
| `RESERV_TYPE` | as required | Reservation record type |

- After the BAPI, read `RETURN`; on success call `BAPI_TRANSACTION_COMMIT` (`WAIT = 'X'`), capture the created 301 material document, and write `ZMM_301_MOV_LOG`.
- On error, roll back only this transfer and log (Section 6.8).

### 6.4 Decoupling and timing (failure isolation)

Posting a second goods movement **synchronously inside** the GR posting LUW (which itself runs `BAPI_GOODS_MOVEMENT_CREATE` + its own commit) risks nested-commit/locking problems and would let a 301 failure roll back the GR. Therefore:

- In `MB_DOCUMENT_BEFORE_UPDATE`, **do not post** the 301 directly. Instead, collect the qualifying items and **register a queued unit** (`CALL FUNCTION … IN BACKGROUND TASK` = tRFC, or bgRFC/qRFC) that executes `Z_MM_301_POST_TRANSFER` **immediately after** the GR's `COMMIT WORK`, in its **own LUW**.
- Use a **serialized queue** (e.g. queue name keyed by material/plant) so transfers for the same stock are processed in order and locking contention is avoided.
- Result: the transfer is effectively immediate (sub-second) but **completely isolated** — a 301 error leaves the GR intact and is picked up by the monitor / alignment program.

### 6.5 Reversal handling (102 → 302)

- When a GR is cancelled/reversed (`BWART = '102'`, or a cancellation document referencing the original GR), locate the 301 posted for the original GR item in `ZMM_301_MOV_LOG`.
- Post the reverse transfer **302** for the same quantity/batch (8P01 ← 8Q01 direction reversed), referencing the reservation so `ENMNG` is corrected, and mark the log entry reversed.
- If the original 301 had already been further processed at 8Q01, flag for manual review rather than auto-reversing (Open Issue M5).

### 6.6 Idempotency / duplicate prevention

- `ZMM_301_MOV_LOG` is keyed by the **source GR material document item** (`MBLNR`, `MJAHR`, `ZEILE`). Before posting, check the log; if a successful 301 already exists for that source item, **skip** (prevents double transfer on BAdI re-fire or bgRFC retry).
- The 301 material document number and status are written back so retries are safe and auditable. A row whose `MOV_MBLNR` is filled counts as transferred, whatever its status (covers a posting without reservation, status W).

### 6.7 Batch and storage-location determination

- Source storage location: the GR storage location; if blank, the default issuing storage location from `ZMM_301_CTRL`.
- Destination storage location: from `ZMM_301_CTRL`.
- Batch: for batch-managed header materials, transfer the **same batch** produced by the GR.

### 6.7a Valuation-type determination (fiscal year)

The material is **split-valuated only in the destination plant** (8Q01); the **origin plant (8P01) does not manage valuation types**. Consequently the 301 transfer must set the **receiving (destination) valuation type** to the valuation type of the **current fiscal year**, while the issuing side carries **no** valuation type. Because the origin has no valuation type, there is no possibility of an origin/batch mismatch.

1. **Determine the current fiscal year.** Derive it from the GR **posting date** (`XMKPF-BUDAT`) using the company-code **fiscal-year variant** (`T001-PERIV`), e.g. via `FI_PERIOD_DETERMINE` / `DATE_TO_PERIOD_CONVERT` → fiscal year `GJAHR`. The fiscal year is taken from the posting date, not the system date, so back-dated GRs get the correct year.
2. **Map fiscal year → valuation type.** Look up the destination valuation type for that fiscal year in the correspondence table `ZMM_301_VALTYPE` (Section 7.5).
3. **Post the 301** with:
   - `VAL_TYPE` (issuing / 8P01) = **blank** — origin plant is not split-valuated.
   - `VAL_TYPE_MOVE` (receiving / 8Q01) = **current-FY valuation type** from step 2.

> **Year rollover.** Because the valuation type follows the posting-date fiscal year, GRs posted on either side of the fiscal-year boundary automatically resolve to the right destination valuation type. The correspondence table must contain an entry for every fiscal year in which GRs may be posted; a missing entry is a hard error (no guessed valuation type).

### 6.8 Error handling and monitoring

- All outcomes (success, warning, error) are written to the **Application Log** (`ZMM` / `Z301MOV`) and to `ZMM_301_MOV_LOG`.
- Failures never affect the GR.
- `ZMM_R_301_MOV_MONITOR` (txn `ZMM301M`) lists source GRs (filtered on the GR posting date, window mandatory, default current month) and their transfer status, and offers a **repost** action for failed/missing transfers (idempotent via the log).
- The optional **scheduled catch-up** sweep (RUN_TYPE C) reposts any failed/missing transfers in the background. Its **frequency is managed as a parameter** (value + unit, **1 minute … multiple days**), using the same self-rescheduling pattern described in FS-MM-301RES-001 §6.9 (self-throttling, stop switch, no overlap). This is a safety net only — the real-time BAdI remains the primary path.
- The FS-MM-301RES-001 alignment program independently detects drift (`WEMNG − ENMNG > 0`) as a second safety net.

---

## 7. Data model

### 7.1 Control table `ZMM_301_CTRL`

| Field | Key | Description |
|---|---|---|
| MANDT | X | Client |
| WERKS_FR | X | Issuing plant (8P01) |
| WERKS_TO | X | Receiving plant (8Q01) |
| LGORT_FR | | Default source storage location |
| LGORT_TO | | Destination storage location |
| MOVE_TYPE | | Transfer movement type (default 301) |
| NO_RESV_ACTION | | Behaviour when no reservation exists (post w/o ref / skip) |
| ACTIVE | | Automation on/off (migration switch) |
| VALID_FROM / VALID_TO | | Optional activation window |

### 7.2 Movement log table `ZMM_301_MOV_LOG`

| Field | Key | Description |
|---|---|---|
| MANDT | X | Client |
| SRC_MBLNR | X | Source GR material document |
| SRC_MJAHR | X | Source GR document year |
| SRC_ZEILE | X | Source GR item |
| AUFNR | | Production order |
| MATNR | | Header material |
| MENGE / MEINS | | Transferred quantity / UoM |
| CHARG | | Batch |
| BWTAR | | Destination valuation type used on the 301 (current-FY valuation type) |
| GJAHR | | Fiscal year resolved from the GR posting date |
| RSNUM / RSPOS | | Reservation referenced |
| MOV_MBLNR / MOV_MJAHR | | Created 301 material document |
| STATUS | | S=Success / E=Error / R=Reversed / W=Warning (no reservation: posted without reference if MOV_MBLNR filled, else skipped) |
| MESSAGE | | Return message |
| ERDAT / ERZET / ERNAM | | Created on/at/by |

### 7.3 Standard tables read

| Table | Fields | Purpose |
|---|---|---|
| `XMKPF` / `XMSEG` (BAdI) | BUDAT, BWART, WERKS, AUFNR, MATNR, MENGE, MEINS, CHARG, LGORT, MBLNR, MJAHR, ZEILE | GR document items being posted (incl. posting date) |
| `ZMM_301_RESV_LOG` | AUFNR, RSNUM, RSPOS | PO → reservation link (from FS-MM-301RES-001) |
| `RESB` | RSNUM, RSPOS, BDMNG, ENMNG | Validate reservation is open |
| `AFPO` | AUFNR, MATNR | Confirm header material of the order |
| `T001` | BUKRS, PERIV | Company-code fiscal-year variant (to resolve fiscal year from posting date) |
| `ZMM_301_VALTYPE` | GJAHR, BWTAR | Fiscal-year → destination valuation-type mapping (Section 7.5) |

### 7.4 Execution log table `ZMM_301_MOV_RUN_LOG`

The real-time BAdI records each transfer at document level in `ZMM_301_MOV_LOG`. This execution-log table records each **batch run** of the monitor / repost / catch-up utility (`ZMM301M`), and each scheduled catch-up sweep — one row per run — so operations has an audit trail of automated reprocessing.

| Field | Key | Type (proposed) | Description |
|---|---|---|---|
| MANDT | X | CLNT | Client |
| RUN_ID | X | CHAR32 / SYSUUID | Unique run identifier |
| RUN_TYPE | | CHAR1 | M=Monitor display / P=Repost / C=Scheduled catch-up |
| RUN_MODE | | CHAR1 | O=Online / B=Background |
| JOBNAME / JOBCOUNT | | BTCJOB / BTCJOBCNT | Background job reference |
| START_DATE / START_TIME | | DATS / TIMS | Run start |
| END_DATE / END_TIME | | DATS / TIMS | Run end |
| DURATION_S | | INT4 | Runtime in seconds |
| CNT_SCANNED | | INT4 | Source GRs examined |
| CNT_POSTED | | INT4 | 301 transfers posted (reposts) |
| CNT_REVERSED | | INT4 | 302 reversals posted |
| CNT_SKIPPED | | INT4 | Already transferred (idempotent skip) |
| CNT_WARNING | | INT4 | No reservation / other warnings |
| CNT_ERROR | | INT4 | Failed transfers |
| STATUS | | CHAR1 | S=Success / W=Completed with errors / A=Aborted / R=Running |
| BALLOGNR | | BALOGNR | Application-log number for drill-down |
| ERNAM | | UNAME | Executed by |
| MESSAGE | | STRING | Summary / abort reason |

Notes:
- `RUN_ID` is stamped onto the `ZMM_301_MOV_LOG` rows touched by a repost/catch-up run, linking header to detail.
- The **real-time BAdI postings are not runs** and are not written here; they are audited per document in `ZMM_301_MOV_LOG` (and the application log `Z301MOV`). This table covers only the batch/monitor executions.

### 7.5 Fiscal-year valuation-type mapping `ZMM_301_VALTYPE`

Maps each fiscal year to the valuation type to be used on the 301 posting (Section 6.7a). Maintained by the business ahead of each new fiscal year. Not required if a naming convention (valuation type = fiscal year) is adopted (Open Issue M9).

| Field | Key | Type (proposed) | Description |
|---|---|---|---|
| MANDT | X | CLNT | Client |
| BUKRS | X | BUKRS | Company code (fiscal-year variant owner); optional if global |
| GJAHR | X | GJAHR | Fiscal year |
| BWTAR | | BWTAR | Valuation type valid for that fiscal year |
| DESCR | | TEXT40 | Description |
| ACTIVE | | CHAR1 | Entry active |

Read into a hashed table at run start; a missing entry for the resolved fiscal year is a hard error (do not post with a guessed valuation type).

---

## 8. Error handling and messages

| # | Condition | Type | Action |
|---|---|---|---|
| 1 | No reservation for the order | W | Post 301 without reference (per config) or skip; log warning |
| 2 | 301 BAPI returns E/A | E | Roll back the transfer only; log; GR untouched; flag for repost |
| 3 | Insufficient/blocked stock in 8P01 | E | Log; monitor repost after stock available (Open Issue M2) |
| 4 | Duplicate source GR item already transferred | I | Skip (idempotency) |
| 5 | GR reversal with no prior 301 found | W | Log; no action |
| 6 | Movement type/plant not configured / inactive | I | Ignore (automation off) |
| 7 | No valuation type mapped for the resolved fiscal year (`ZMM_301_VALTYPE`) | E | Do not post (no guessed valuation type); log; flag for monitor |

Guiding rule: **the goods receipt is sacred** — nothing in this object may cause the GR to fail or roll back.

---

## 9. Authorizations
- The transfer posts in a background/queued LUW; confirm the executing user context (GR user vs technical user) — Open Issue M7.
- Object `M_MSEG_WMB` (plant): ACTVT 01, WERKS 8P01 & 8Q01.
- Object `M_MSEG_BWA` (movement type): ACTVT 01, BWART 301/302.
- Checked explicitly in `Z_MM_301_POST_TRANSFER` before the BAPI call.
- Access to the reservation and material master in both plants.

---

## 10. Performance considerations
- The BAdI logic must be lightweight: only classify items and enqueue a unit; no heavy selects in the GR posting path (the BAdI runs in the posting LUW, just before the update task).
- Serialized queue per material/plant avoids lock contention while preserving order.
- High GR volume (e.g. MFBF backflush) → ensure the queue/bgRFC scheduler is sized; monitor `SMQ1`/`SBGRFCMON`.

---

## 11. Test cases

| # | Scenario | Expected result |
|---|---|---|
| T1 | 101 GR (10 EA) on PO in 8P01 with open reservation | 301 of 10 EA posted 8P01→8Q01 against reservation; `ENMNG += 10`; log Success |
| T2 | GR is sacred: force 301 to fail (e.g. no dest config) | GR still posts/commits; 301 logged as Error; flagged for repost |
| T3 | Repost via `ZMM301M` after fixing config | Missing 301 posted once; no duplicate |
| T4 | Re-fire BAdI / bgRFC retry for same GR item | Second attempt skipped (idempotent, log check) |
| T5 | Batch-managed material | 301 carries the GR batch |
| T5a | Split-valuated in destination only | 301 posts with `VAL_TYPE` blank (origin) and `VAL_TYPE_MOVE` = current-FY valuation type (destination) |
| T5b | GR posted with a back-dated posting date in the prior fiscal year | Destination valuation type resolves to the **prior** year's type (from posting-date fiscal year, not system date) |
| T5d | No `ZMM_301_VALTYPE` entry for the resolved fiscal year | Error; no posting; flagged for monitor |
| T6 | GR reversal (102) after a successful 301 | Matching 302 posted; reservation `ENMNG` corrected; log Reversed |
| T7 | GR on PO with **no** reservation yet | Behaviour per config: post w/o ref + warning, or skip + warning |
| T8 | GR in a plant other than 8P01 | Ignored |
| T9 | GR of a component (non-header) material | Ignored |
| T10 | Automation switched off (`ZMM_301_CTRL.ACTIVE = ' '`) | No transfer posted |
| T11 | MFBF backflush auto-GR | 301 triggered same as MIGO GR |
| T12 | Alignment cross-check | After T1, FS-MM-301RES-001 shows reservation open = PO open (Unchanged) |

---

## 12. Open issues / decisions pending

| # | Item | Owner | Status |
|---|---|---|---|
| M1 | Confirm `MB_DOCUMENT_BADI` (or the correct enhancement) fires for all GR channels in the target release; else agree alternative | ABAP/Basis | Open |
| M2 | Behaviour when GR stock lands in QI/blocked and cannot be immediately transferred | MM | Open |
| M3 | Co-products / by-products handling (only header material transferred?) | PP | Open |
| M4 | Action when no reservation exists yet at GR time (post w/o ref vs skip) | Business | Open |
| M5 | Reversal when the 301 stock has already moved on at 8Q01 | Business | Open |
| M6 | Batch valuation/split specifics for the transfer | MM | Open |
| M7 | Executing user context and authorizations for the queued posting | Basis/Security | Open |
| M8 | Confirm "immediate" tolerance — sub-second queued LUW vs strictly same-LUW | Business | Open |
| M9 | Fiscal-year ↔ valuation-type correspondence held in table `ZMM_301_VALTYPE`; origin plant not split-valuated so no mismatch handling required | MM/FI | **Decided** |

---

## 13. Appendix

### 13.1 Glossary
- **101 / 102** – Goods receipt for production order / its reversal.
- **301 / 302** – Transfer posting plant to plant (one step) / its reversal.
- **ENMNG** – Reservation quantity already withdrawn/transferred.
- **bgRFC/qRFC** – Background/queued RFC used to run the transfer in an isolated LUW immediately after the GR.
- **LUW** – Logical Unit of Work: an all-or-nothing sequence of database updates ending in COMMIT or ROLLBACK.
- **Valuation type (BWTAR)** – Split-valuation category value; managed only in the destination plant here, where each valuation type corresponds to a fiscal year.
- **Fiscal-year variant (PERIV)** – Company-code setting that maps a posting date to a fiscal year/period.

### 13.2 Key objects
- Enhancement: `MB_DOCUMENT_BADI` (`IF_EX_MB_DOCUMENT_BADI`).
- BAPI: `BAPI_GOODS_MOVEMENT_CREATE` (GM_CODE 04, mvt 301/302), `BAPI_TRANSACTION_COMMIT` / `_ROLLBACK`.
- Companion object: **FS-MM-301RES-001** (reservation creation & alignment).
- Transactions referenced: MIGO / MB31 / CO11N / MFBF (GR), MB1B (301), MB03 (display).
