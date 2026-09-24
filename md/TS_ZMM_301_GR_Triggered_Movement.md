# Technical Specification
## GR-Triggered Automatic 301 Transfer Posting

| | |
|---|---|
| **Document ID** | TS-MM-301MOV-001 |
| **Functional spec** | FS-MM-301MOV-001 |
| **SAP solution** | S/4HANA on-premise |
| **Module** | MM (Inventory Management – goods movements) |
| **Objects** | BAdI class `ZCL_MM_301_GR_TRIGGER`, FM `Z_MM_301_POST_TRANSFER`, report `ZMM_R_301_MOV_MONITOR` (txn `ZMM301M`) |
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

Technical design for the objects that post the physical 301 transfer (origin → destination) automatically after each goods receipt against a production order, and the monitor/repost utility. The transfer is decoupled from the goods receipt so it can never roll back the GR. See FS-MM-301MOV-001.

---

## 2. Object inventory

| # | Object | Type | Name | Notes |
|---|---|---|---|---|
| 1 | Class | CLAS | `ZCL_MM_301_GR_TRIGGER` | Implements `IF_EX_MB_DOCUMENT_BADI` |
| 2 | BAdI impl | SXCI | `ZMM_301_GR_TRIGGER` | Implementation of BAdI `MB_DOCUMENT_BADI` |
| 3 | Function group | FUGR | `ZMM_301_MOV` | Container for the posting FM |
| 4 | Function module | FUNC | `Z_MM_301_POST_TRANSFER` | Remote-Enabled |
| 5 | Report | PROG | `ZMM_R_301_MOV_MONITOR` | Monitor/repost/catch-up |
| 6 | Transaction | TRAN | `ZMM301M` | Monitor |
| 7 | Table | TABL | `ZMM_301_CTRL` | Control/config (SM30 view) |
| 8 | Table | TABL | `ZMM_301_MOV_LOG` | Per-GR movement log |
| 9 | Table | TABL | `ZMM_301_MOV_RUN_LOG` | Monitor/repost execution log |
| 10 | Table | TABL | `ZMM_301_VALTYPE` | Fiscal-year → valuation type (SM30 view) |
| 11 | Table (read) | TABL | `ZMM_301_RESV_LOG` | Reservation link (from FS-MM-301RES-001) |
| 12 | Message class | MSAG | `ZMM301` | Shared |
| 13 | Application log | SLG0 | `ZMM` / `Z301MOV` | Logging |

---

## 3. Solution architecture

```
  Goods receipt (101) posts  ─ MIGO / MB31 / CO11N / MFBF
        │  (posting LUW, just before the update task)
        ▼
  MB_DOCUMENT_BADI → ZCL_MM_301_GR_TRIGGER
        │  classify item, read ZMM_301_CTRL, header-material check
        │  CALL FUNCTION 'Z_MM_301_POST_TRANSFER' IN BACKGROUND TASK
        ▼  (tRFC unit fires AFTER the GR COMMIT WORK — separate LUW)
  Z_MM_301_POST_TRANSFER
        ├─ idempotency (ZMM_301_MOV_LOG by source doc/item)
        ├─ re-read MSEG/MKPF (persisted)
        ├─ reservation lookup (ZMM_301_RESV_LOG + RESB open check)
        ├─ fiscal year (T001W→T001K→T001, FI_PERIOD_DETERMINE) → ZMM_301_VALTYPE
        ├─ BAPI_GOODS_MOVEMENT_CREATE (301, VAL_TYPE_MOVE = current-FY type)
        │        or BAPI_GOODSMVT_CANCEL (reversal path)
        └─ ZMM_301_MOV_LOG + app log

  ZMM_R_301_MOV_MONITOR (txn ZMM301M)  ── Monitor / Repost / Catch-up
        └─ reuses Z_MM_301_POST_TRANSFER; writes ZMM_301_MOV_RUN_LOG
```

---

## 4. BAdI class `ZCL_MM_301_GR_TRIGGER` (technical)

- Implements `IF_EX_MB_DOCUMENT_BADI`. Method **`MB_DOCUMENT_BEFORE_UPDATE`** is called in the posting LUW immediately **before** the update task is triggered (it is **not** the update-task method — that is `MB_DOCUMENT_UPDATE`) and receives the tables `XMKPF` (`MKPF` lines) and `XMSEG` (document items); the implementation loops over both.
- Per `XMSEG` line, continue only when: `AUFNR` populated; `BWART ∈ {101,102}`; origin plant has an **active** `ZMM_301_CTRL` entry; posting date within the optional activation window; material is the order **header** material (`is_header_material` → AFPO).
- On a qualifying line, register `Z_MM_301_POST_TRANSFER` **IN BACKGROUND TASK** with the source keys (`MBLNR/MJAHR/ZEILE`) and a reversal flag. No DB writes, no posting inside the BAdI (keep it lightweight; timing critical because it runs in the GR update LUW).

**Private helpers**
- `get_control( iv_werks )` → active `ZMM_301_CTRL` row.
- `is_header_material( iv_aufnr, iv_matnr )` → AFPO existence check.

**Decoupling rationale (LUW).** `IN BACKGROUND TASK` schedules a tRFC unit executed at the next `COMMIT WORK` (the GR's own commit), i.e. a **separate LUW** after the material document is persisted. A failure in the transfer therefore cannot roll back the GR. For strict per-material/plant serialisation, replace tRFC with a **bgRFC** inbound queue keyed by `MATNR/WERKS` (build option; FS M1/M8).

---

## 5. Function module `Z_MM_301_POST_TRANSFER` (technical)

**Interface** (Remote-Enabled):
`IV_MBLNR`, `IV_MJAHR`, `IV_ZEILE`, `IV_REVERSAL` (default space), `IV_RUN_ID` (optional).

**Processing steps**
1. **Idempotency** — read `ZMM_301_MOV_LOG` by source doc/item; if a prior `STATUS='S'` exists and not a reversal → `RETURN`.
2. **Re-read source** — `MSEG` line (`BWART, MATNR, WERKS, LGORT, CHARG, MENGE, MEINS, AUFNR, SMBLN, SMBLP`) and `MKPF` (`BUDAT, BLDAT`). Safe because the tRFC runs post-commit.
3. **Control** — active `ZMM_301_CTRL` for `WERKS_FR = MSEG-WERKS`; else `RETURN`. Movement type from `ZMM_301_CTRL-MOVE_TYPE` (default 301).
4. **Reversal path** (`IV_REVERSAL='X'`): find original 301 via `ZMM_301_MOV_LOG` on `SMBLN/SMBLP`, then `BAPI_GOODSMVT_CANCEL(mov_mblnr/mov_mjahr)`; log `R`/`E`/`W`.
5. **Reservation** — `ZMM_301_RESV_LOG` (latest for the order) → `RESB` open check (`BDMNG − ENMNG > 0`). If none and `NO_RESV_ACTION='S'` → log warning + `RETURN`; if `='P'` → post without reservation reference.
6. **Fiscal year & valuation type** — origin plant → `T001W-BWKEY` → `T001K-BUKRS` → `T001-PERIV`; `FI_PERIOD_DETERMINE(I_BUDAT, I_BUKRS)` → `GJAHR`; look up `ZMM_301_VALTYPE(GJAHR)` → destination valuation type. Missing → status `E`, `RETURN`.
7. **Post 301** — `BAPI_GOODS_MOVEMENT_CREATE`, `GOODSMVT_CODE='04'`:
   - item `MOVE_TYPE=301`, `MATERIAL_LONG`, `PLANT=WERKS_FR`, `STGE_LOC=MSEG-LGORT|LGORT_FR`, `ENTRY_QNT=MENGE`, `ENTRY_UOM=MEINS`, `BATCH=CHARG`;
   - receiving `MOVE_PLANT=WERKS_TO`, `MOVE_STLOC=LGORT_TO`, `MOVE_BATCH=CHARG`;
   - valuation `VAL_TYPE = space` (origin not split-valuated), `VAL_TYPE_MOVE = current-FY valuation type` *(verify field name)*;
   - reservation `RESERV_NO/RES_ITEM/RES_TYPE='R'` when a reservation exists.
   - Commit/rollback per RETURN; on success capture material document; write `ZMM_301_MOV_LOG` (`S` + `MOV_MBLNR/MJAHR/BWTAR`).

**LUW/commit** — the FM owns its LUW; it issues its own `BAPI_TRANSACTION_COMMIT`/`ROLLBACK` and `MODIFY … COMMIT` of the log. It must not be called synchronously inside another posting LUW (only via `IN BACKGROUND TASK` or from the monitor's own dialog LUW).

---

## 6. Monitor/repost report `ZMM_R_301_MOV_MONITOR` (technical)

- Local class `LCL_MON`. Selection: `P_WERK_FR` (must have an active `ZMM_301_CTRL` entry), `SO_BUDAT` (GR posting date, **mandatory**, default current month), `SO_AUFNR`, `P_MODE` (M/P/C listbox), self-reschedule block (`P_SCHED/P_FREQ/P_FUNIT`, mode C only).
- All modes filter on the **GR posting date** (`MKPF-BUDAT`) and plant via `ZMM_301_MOV_LOG ⋈ MKPF ⋈ MSEG` — never on the log date.
- Methods: `select_log` (modes M/P), `select_catchup` (mode C), `repost` (P/C – calls the FM per item and re-reads the outcome), `start_log`/`finish_log` (run log + BAL `ZMM/Z301MOV` for background runs, `BALLOGNR` stored).
- **Mode M** — `select_log` into ALV; roll up counts.
- **Mode P** — `select_log` rows with `STATUS ∈ {E,W}` and no 301 document (`MOV_MBLNR` initial) → `repost`.
- **Mode C** — `select_catchup`: `MSEG ⋈ MKPF` for `BWART=101`, plant, order, `BUDAT` window; skip items already transferred (`MOV_MBLNR` filled); `repost` the rest.
- Run header written to `ZMM_301_MOV_RUN_LOG` (`start_log`/`finish_log`, `DURATION_S`). Catch-up mode self-reschedules using the same `JOB_OPEN/SUBMIT/JOB_CLOSE` pattern (chain job `ZMM301M_CHAIN`).

---

## 7. Data dictionary

Tables defined in `00_DDIC_and_message_class.md`. Notes:
- `ZMM_301_MOV_LOG` PK `MANDT/SRC_MBLNR/SRC_MJAHR/SRC_ZEILE` — one row per source GR item guarantees idempotency; secondary index on `AUFNR` and on `STATUS/ERDAT` supports repost/catch-up scans.
- `ZMM_301_CTRL` PK `MANDT/WERKS_FR/WERKS_TO`; `ZMM_301_VALTYPE` PK `MANDT/BUKRS/GJAHR` (BUKRS may be blank = global).

---

## 8. Authorization

- Posting runs in the tRFC/background context (executing user confirmed — FS M7). `AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'` (`ACTVT 01`, `WERKS` = `WERKS_FR` and `WERKS_TO`) and `M_MSEG_BWA` (`ACTVT 01`, `BWART` 301 / 302 on the reversal path) inside `Z_MM_301_POST_TRANSFER` before posting; failure → status `E`, message ZMM301/027.
- `S_TCODE` on `ZMM301M`; SM30 auth (`S_TABU_DIS`/`S_TABU_NAM`) for the config views.

---

## 9. Performance & robustness

- BAdI method does only classification + enqueue; no selects beyond a single `ZMM_301_CTRL` and `AFPO` read (buffer `ZMM_301_CTRL` as fully buffered — small config table).
- `Z_MM_301_POST_TRANSFER` processes one item per unit; high-volume GR (MFBF) handled by the queue scheduler (`SMQ*`/`SBGRFCMON`). Size inbound queue accordingly.
- All failures isolated to their own LUW; the reservation program's drift check (`WEMNG−ENMNG>0`) and the monitor catch-up are the recovery paths.

---

## 10. Unit test plan (ABAP Unit)

- **`Z_MM_301_POST_TRANSFER`** — wrap DB reads and BAPI calls behind a seam (interface/test double) so posting can be mocked.

| Test | Setup | Assert |
|---|---|---|
| happy path | GR 10 EA, open reservation, valtype mapped | 301 posted, log `S`, `VAL_TYPE_MOVE` set |
| idempotent skip | prior `S` for same source item | early `RETURN`, no second posting |
| no valuation type | no `ZMM_301_VALTYPE` for FY | log `E`, no posting |
| no reservation, action S | `NO_RESV_ACTION='S'` | log `W`, no posting |
| no reservation, action P | `NO_RESV_ACTION='P'` | posted without reservation ref |
| reversal | 102 referencing prior 301 | `BAPI_GOODSMVT_CANCEL` called, log `R` |
| inactive control | `ACTIVE=' '` | early `RETURN` |

- **`ZCL_MM_301_GR_TRIGGER`** — feed synthetic `XMSEG`/`XMKPF`; assert `Z_MM_301_POST_TRANSFER` is enqueued only for qualifying 101/102 header-material lines in an active origin plant.
- **`LCL_MON`** — assert counters and idempotent skips for repost/catch-up.

---

## 11. Transport & dependencies

- Package `Z_MM_INVENTORY`, same transport train as TS-MM-301RES-001.
- Compile dependency: tables + message class active first; `Z_MM_301_POST_TRANSFER` before the monitor and BAdI (both call it).
- Runtime dependency: reservation link table `ZMM_301_RESV_LOG` populated by TS-MM-301RES-001.

---

## 12. Open technical points

| # | Item | FS ref |
|---|---|---|
| T1 | Confirm receiving valuation-type field on `BAPI2017_GM_ITEM_CREATE` (`VAL_TYPE_MOVE` vs `MOVE_VAL_TYPE`) | M9 |
| T2 | Confirm `MB_DOCUMENT_BADI` enhanceable + fires for all GR channels; method param types | M1 |
| T3 | tRFC vs bgRFC decoupling; "immediate" tolerance; queue serialisation | M8 |
| T4 | Executing user context & authorizations for the queued posting | M7 |
| T5 | QI/blocked stock behaviour at transfer time | M2 |
| T6 | Reversal when destination stock already moved on | M5 |
