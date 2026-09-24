# Technical Specification
## ZMM_R_CREATE_301_RESERV — 301 Reservation Create/Align Program

| | |
|---|---|
| **Document ID** | TS-MM-301RES-001 |
| **Functional spec** | FS-MM-301RES-001 |
| **SAP solution** | S/4HANA on-premise |
| **Module** | MM / PP (Inventory Management – Reservations) |
| **Object** | Executable report `ZMM_R_CREATE_301_RESERV` (txn `ZMM301R`) |
| **Package** | `Z_MM_INVENTORY` |
| **Author / Version / Date** | (to complete) / 0.1 / 2026-07-15 |
| **Status** | Draft |

### Version history

| Version | Date | Author | Description |
|---|---|---|---|
| 0.1 | 2026-07-15 | | Initial draft |
| 0.1.1 | 2026-09-22 | Marco Casavecchia | Consistency corrections aligned with FSD+TSD v0.3 and the ABAP reference code (superseded by the merged FSD+TSD) |

---

## 1. Purpose and scope

Technical design for the program that creates and keeps aligned the 301 transfer reservations for open production orders during the 8P01 → 8Q01 migration. The program does **not** post goods movements; it only creates/realigns/closes reservations so that *reservation remaining = PO remaining*. See FS-MM-301RES-001 for business requirements. The companion posting object is specified in TS-MM-301MOV-001.

---

## 2. Object inventory

| # | Object | Type | Name | Notes |
|---|---|---|---|---|
| 1 | Report | PROG | `ZMM_R_CREATE_301_RESERV` | Main program |
| 2 | Transaction | TRAN | `ZMM301R` | Start transaction |
| 3 | Local class | (in report) | `LCL_APP` | Engine |
| 4 | Table | TABL | `ZMM_301_RESV_LOG` | Per-order detail log |
| 5 | Table | TABL | `ZMM_301_RUN_LOG` | Execution log |
| 6 | Table (read) | TABL | `ZMM_301_CTRL` | Control (active flag, plant pair) |
| 7 | Message class | MSAG | `ZMM301` | Messages (shared) |
| 8 | Application log | SLG0 | `ZMM` / `Z301RES` | Background logging |
| 9 | Variant | VARI | `ZMM301R_JOB` | Background job variant |

Data elements referenced use standard types (see DDIC document); no new domains beyond `SYSUUID_C32` reuse.

---

## 3. Solution architecture

```
 START-OF-SELECTION
        │
        ▼
   LCL_APP->run( )
        ├─ validate_selection( )        (AT SELECTION-SCREEN is the entry gate)
        ├─ start_run_log( )             → ZMM_301_RUN_LOG (status 'R')
        ├─ select_open_orders( )        → AUFK/AFKO/AFPO + JEST
        ├─ LOOP → process_order( )      → decision matrix → create/change
        │            ├─ create_reservation( )   BAPI_RESERVATION_CREATE1
        │            ├─ change_reservation( )   BAPI_RESERVATION_CHANGE
        │            └─ write_detail_log( )      → ZMM_301_RESV_LOG
        ├─ finish_run_log( )            → ZMM_301_RUN_LOG (counts, status)
        ├─ display_alv( )               (online only)
        └─ schedule_next_run( )         (self-reschedule; JOB_OPEN/SUBMIT/JOB_CLOSE)
```

The engine is encapsulated in `LCL_APP`; the report body only wires the selection screen and instantiates the class. This keeps the logic unit-testable (ABAP Unit against `LCL_APP` methods).

---

## 4. Selection screen (technical)

| Block | Element | ABAP | Type | Modif id |
|---|---|---|---|---|
| B1 | `P_WERK_FR` | PARAMETER `werks_d` OBLIGATORY, default 8P01 | | |
| B1 | `P_LGOR_FR` | PARAMETER `lgort_d` | | |
| B1 | `P_WERK_TO` | PARAMETER `werks_d` OBLIGATORY, default 8Q01 | | |
| B1 | `P_LGOR_TO` | PARAMETER `lgort_d` | | |
| B2 | `SO_AUFNR/SO_AUART/SO_MATNR/SO_DISPO` | SELECT-OPTIONS | | |
| B2 | `P_RSDAT` | PARAMETER `rsdat`, default sy-datum, OBLIGATORY | | |
| B3 | `P_MOVE/P_TEST/P_ERRON` | CHECKBOX | | |
| B4 | `P_SCHED` | CHECKBOX | | `SCH` |
| B4 | `P_FREQ` | PARAMETER `i`, default 5 | | `SCH` |
| B4 | `P_FUNIT` | LISTBOX MIN/HRS/DAY | | `SCH` |

**Events**
- `INITIALIZATION` — populate `P_FUNIT` listbox via `VRM_SET_VALUES`.
- `AT SELECTION-SCREEN OUTPUT` — grey out B4 fields (`SCREEN-INPUT = 0`) unless `P_SCHED = 'X'` using modif id `SCH`.
- `AT SELECTION-SCREEN` — call `validate_selection( )` logic (plant existence T001W, storage location T001L, origin≠destination, frequency floor/ceiling). Raise `MESSAGE … TYPE 'E'`.

---

## 5. Detailed method design (`LCL_APP`)

### 5.1 `constructor`
Generates `mv_run_id` via `cl_system_uuid=>create_uuid_c32_static( )` (fallback to date/time/index). Sets `mv_mode` = `B` when `sy-batch = 'X'`, else `O`.

### 5.2 `select_open_orders` → `tt_ord`
- Single join `AUFK ⋈ AFKO ⋈ AFPO` filtered by `WERKS = P_WERK_FR`, select-options, and `AFPO-ELIKZ = space`; plus a second join adding the **delivered** orders (`ELIKZ ≠ space`) that still hold an open 301 reservation (`ZMM_301_RESV_LOG ⋈ RESB`, `BDMNG > ENMNG`, not deleted), so they can be closed.
- Bulk status read: collect `OBJNR`, `SELECT objnr stat FROM jest WHERE inact = space` `FOR ALL ENTRIES`.
- Keep orders with system status **REL** (`I0002`) and drop **not-released**. Orders carrying **TECO/CLSD/DLFL/DLT** (`I0045/I0046/I0076/I0013`), and delivered orders, are flagged (`TO_CLOSE = X`) for a **close** action rather than dropped, so a still-open reservation gets closed; a close-flagged order without an open reservation is ignored (no create, not logged).
- Returns typed table `tt_ord` (fields: aufnr, auart, objnr, posnr, matnr, psmng, wemng, meins, elikz, dispo, to_close).

**DB access & volume**: one set-based read + one JEST read. Expected volume = open orders in 8P01 (confirm; drives package sizing).

### 5.3 `process_order( is_order )`
Algorithm per order:
```
PO open      = PSMNG − WEMNG
read link     ZMM_301_RESV_LOG (latest by ERDAT/ERZET, UP TO 1 ROWS) → RSNUM/RSPOS
read RESB     BDMNG, ENMNG   (has_res? – RESB-XLOEK = space)
if to_close and (not has_res or BDMNG = ENMNG) → RETURN   " nothing to close, not logged
if P_ERRON and latest detail status ≠ 'E' → RETURN
target BDMNG = PO open + ENMNG

if not has_res:
    if PO open ≤ 0 → status K (Fully received)
    else          → create_reservation( )
else:
    if to_close or PO open ≤ 0:
        if BDMNG = ENMNG → status F (Complete)
        else             → change_reservation( close = X )
    elif target ≠ BDMNG  → change_reservation( close = '' )   " Realign
    else                 → status N (Unchanged)

if WEMNG − ENMNG > 0 and has_res → cnt_drift++
append to mt_out; write_detail_log( )
```

### 5.4 `create_reservation`
- Check the header material exists in `P_WERK_TO` (MARC) → else status `E`, message ZMM301/003.
- `is_authorised( '01' )` before the BAPI call (not in test run).
- Test run → status `S` (Simulated), no posting.
- Fills `BAPI2093_RES_HEAD_C1` (`RES_DATE`, `MOVEMENT=P_MOVE`) and one `BAPI2093_RES_ITEM_C1` item:
  `MATERIAL_LONG/MATERIAL`, `PLANT=P_WERK_FR`, `STGE_LOC=P_LGOR_FR`, `MOVE_TYPE=301`, `ENTRY_QNT=PO open`, `ENTRY_UOM=MEINS`, `REQ_DATE=P_RSDAT`, `MOVE_PLANT=P_WERK_TO`, `MOVE_STLOC=P_LGOR_TO`.
- `BAPI_RESERVATION_CREATE1` → on `E/A` in RETURN: `BAPI_TRANSACTION_ROLLBACK`, status `E`; else `BAPI_TRANSACTION_COMMIT WAIT='X'`, capture `RSNUM`, status `C`.

### 5.5 `change_reservation( iv_close )`
- `is_authorised( '02' )` before the BAPI call (not in test run).
- New qty = `ENMNG` (close) or `target BDMNG` (realign). Guard: never below `ENMNG`.
- Test run → status `S`.
- `BAPI_RESERVATION_CHANGE` with item `BAPI2093_RES_ITEM_C` (`RES_ITEM`, `ENTRY_QNT`) and change-flag `BAPI2093_RES_ITEM_CX` (`RES_ITEM`, `ENTRY_QNT='X'`). Commit/rollback per RETURN. Status `X` (close) or `R` (realign).
- **Fallback** (release without a usable change BAPI): encapsulate behind a small method so an MB22 BDC/enterprise FM can replace the BAPI call without touching callers. *(Open Issue O4)*

### 5.6 Logging
- `start_run_log` writes a `ZMM_301_RUN_LOG` header (status `R`) + `COMMIT`.
- `write_detail_log` upserts one `ZMM_301_RESV_LOG` row per order keyed by `AUFNR/POSNR/RUN_ID`.
- `finish_run_log` updates counts, end time, `DURATION_S` (via `cl_abap_tstmp`), final status `S`/`W`.
- Background runs additionally write the BAL application log `ZMM/Z301RES` (`BAL_LOG_CREATE` in `start_run_log`, `BAL_LOG_MSG_ADD_FREE_TEXT` per order and for drift, `BAL_DB_SAVE` in `finish_run_log`; log number stored in `ZMM_301_RUN_LOG-BALLOGNR`) and a summary list to the spool.

### 5.7 ALV (`display_alv`)
`CL_SALV_TABLE=>factory` over `mt_out`; all functions on; optimize columns. Recommended build-out: traffic-light column from `STATUS`, hotspot on `RSNUM` → MB23 and on `AUFNR` → CO03.

### 5.8 Scheduling (`schedule_next_run`)
- Guard: only if `P_SCHED='X'` and `is_automation_active( )` (`ZMM_301_CTRL-ACTIVE`).
- Next start = now + `interval_in_seconds( )` computed via `cl_abap_tstmp=>add`.
- `JOB_OPEN` → `SUBMIT … VIA JOB … WITH <all params> AND RETURN` → `JOB_CLOSE` with `SDLSTRTDT/SDLSTRTTM`.
- Next run is scheduled **after** the current finishes → runs never overlap (self-throttling). Writes `NEXT_RUN_DT/TM` to the run log. Chain stops cleanly when `ACTIVE` is unset (message ZMM301/012).

---

## 6. Data dictionary

Tables `ZMM_301_RESV_LOG` and `ZMM_301_RUN_LOG` defined in `00_DDIC_and_message_class.md`. Key points:
- `RUN_ID` (CHAR32) is the join key between run header and detail rows.
- `ZMM_301_RESV_LOG` primary key `MANDT/AUFNR/POSNR/RUN_ID` retains history across runs; a secondary index on `AUFNR/POSNR` (and `ERDAT/ERZET`) supports the "latest status" read in `process_order`.
- Housekeeping: reorg report to delete run/detail rows older than N days (keep error rows longer) — parameterised.

---

## 7. Authorization

`AT SELECTION-SCREEN` / start of `run`:
- Method `is_authorised( actvt )`, called before the create (ACTVT 01) and change (ACTVT 02) BAPI: `AUTHORITY-CHECK OBJECT 'M_MRES_WWA' ID 'ACTVT' … ID 'WERKS' FIELD P_WERK_FR` (and `P_WERK_TO`), and `M_MRES_BWA ID 'ACTVT' … ID 'BWART' FIELD '301'`. Failure → order status E, message ZMM301/018.
- On failure: message and either abort (screen) or skip the order with a logged error (loop).
- `S_TCODE` on `ZMM301R` guarded by the transaction.

---

## 8. Performance

- Set-based selects; hashed access to JEST via `line_exists( )` on a sorted/keyed table (build: convert `lt_jest` to `HASHED`/`SORTED` keyed by `OBJNR STAT` for O(1) lookups).
- Avoid singleton reads in the loop where possible: pre-read all existing reservations (`ZMM_301_RESV_LOG` + `RESB`) for the selected orders into keyed internal tables in a build refinement; current design reads per order for clarity.
- Commit strategy: one commit per BAPI (safest for restart). For very high volumes, batch N orders per LUW with per-order rollback isolation (confirm with volume figures).

---

## 9. Restart / idempotency

- Idempotent by construction: each run recomputes `target BDMNG = PO open + ENMNG` and converges without duplicates.
- `P_ERRON` reprocesses only orders whose latest detail status is `E`.
- A failed order in one run is retried next run.

---

## 10. Batch/job design

- Delivered variant `ZMM301R_JOB` (8P01→8Q01, test off, self-reschedule on, freq 5 MIN).
- Self-rescheduling chain job `ZMM301R_CHAIN` (see 5.8). Single-instance enqueue guard recommended (`ENQUEUE_E…` on a program key) to prevent overlap if also scheduled via SM36.

---

## 11. Unit test plan (ABAP Unit)

Test class `LTC_APP` (local, `FOR TESTING`, `RISK LEVEL HARMLESS`). Inject test doubles for DB/BAPI (extract DB reads and BAPI calls behind small methods or a test seam interface).

| Test | Method under test | Setup | Assert |
|---|---|---|---|
| create when no reservation | `process_order` | PO open 10, no link | action = create, BDMNG 10 |
| realign after progress | `process_order` | ENMNG 4, PO open 6, BDMNG 10 | action = realign, target 10 (unchanged) or new target |
| realign on qty change | `process_order` | PO open 8, ENMNG 2, BDMNG 10 | target 10 ≠ 10? → compute; realign when differs |
| unchanged | `process_order` | target = BDMNG | status N |
| close on TECO | `process_order` | to_close, BDMNG≠ENMNG | change close |
| complete | `process_order` | PO open 0, BDMNG=ENMNG | status F |
| fully received, no res | `process_order` | PO open ≤0, no link | status K |
| frequency floor | `validate_selection` | 30 sec | error ZMM301/010 |
| interval calc | `interval_in_seconds` | 2 HRS | 7200 |

---

## 12. Transport & dependencies

- All objects in package `Z_MM_INVENTORY`, one transport.
- Depends on tables and message class being active first (see DDIC install order).
- No dependency on TS-MM-301MOV-001 at compile time; functionally complementary at runtime (shares `ZMM_301_CTRL`, `ZMM_301_RESV_LOG`).

---

## 13. Open technical points

| # | Item | FS ref |
|---|---|---|
| T1 | Confirm `BAPI_RESERVATION_CHANGE` signature/availability; else MB22 fallback | O4 |
| T2 | Confirm `BAPI_RESERVATION_CREATE1` item field names on the release | O1 |
| T3 | Finalise commit batching for expected volume | O5 |
| T4 | ~~Add BAL application-log calls in logging methods~~ — done (22-Sep-2026) | §6.8 |
| T5 | Confirm order status codes vs plant status profile | §6.3 (FS) |
