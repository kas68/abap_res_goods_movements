# ABAP Code Review – 301 Migration Transfer (R-xxx-SEG / E-xxx-SEG)

**Scope:** 4 files in `abap_res_goods_movements/` (≈1,750 lines)
`ZCL_MM_301_GR_TRIGGER` · `Z_MM_301_POST_TRANSFER` · `ZMM_R_301_MOV_MONITOR` · `ZMM_R_CREATE_301_RESERV`
**Reviewed against:** README, `00_DDIC_and_message_class.md` (v0.3, 22-Sep-2026)
**Date:** 23-Sep-2026. This is a static review; nothing was activated in a system.

---

## 1. Summary

The overall design holds up. The GR is decoupled from the 301 through tRFC, the posting is idempotent on `MOV_MBLNR`, the code uses BAL logging and run logs, and it applies explicit authority checks. The code is also modern ABAP (inline declarations, `VALUE`/`COND`, strict Open SQL) and is well commented.

Several problems must be fixed before unit test:

- **Build blockers.** At least 3 statements will not activate or will dump on the first call: a wrong BAPI name, `OPTIONAL` combined with `DEFAULT`, and a wrong receiving valuation-type field. The reservation BAPI structures probably also don't match.
- **Wrong stock postings.** A failed 102 reversal that is reposted produces a second **301** instead of a 302. A partial 102 cancels the **whole** 301. The catch-up scan re-transfers GRs that were already reversed.
- **Duplicate postings.** There is no lock and the log is written after the commit, so 301s and reservations can be created twice.
- **Self-rescheduling chains freeze their date parameters,** so they stop seeing new data.

| Severity | Count |
|---|---|
| 🔴 Blocker (won't activate / dumps) | 4 |
| 🟠 High (wrong postings / data integrity) | 8 |
| 🟡 Medium (robustness, consistency, performance) | 11 |
| ⚪ Low (style, maintainability) | 7 |

---

## 2. Blockers – syntax / runtime

| # | File · line | Finding | Fix |
|---|---|---|---|
| B1 | `Z_MM_301_POST_TRANSFER` L281 (and comment L243) | `CALL FUNCTION 'BAPI_GOODS_MOVEMENT_CREATE'` does not exist. It will raise the runtime error `CALL_FUNCTION_NOT_FOUND` on the first GR. | Use `'BAPI_GOODSMVT_CREATE'`. The parameter names already match it. |
| B2 | `Z_MM_301_POST_TRANSFER` L295 | `VALUE #( lt_ret[ type = 'E' ]-message OPTIONAL DEFAULT 'Posting error' )`: `OPTIONAL` and `DEFAULT` are mutually exclusive, so this is a syntax error. | `VALUE #( lt_ret[ type = 'E' ]-message DEFAULT VALUE #( lt_ret[ type = 'A' ]-message DEFAULT 'Posting error' ) )`. Apply the same pattern at L151, which currently returns blank when only an 'A' message exists. |
| B3 | `Z_MM_301_POST_TRANSFER` L272 | `ls_item-val_type_move`: the receiving valuation-type field in `BAPI2017_GM_ITEM_CREATE` is **`MOVE_VAL_TYPE`** (UMBAR), which closes README point 1 / FS M9. | Rename it to `ls_item-move_val_type`. |
| B4 | `ZMM_R_CREATE_301_RESERV` L505-516, L581-601 | **Probable structure mismatch; confirm in SE11.** In `BAPI_RESERVATION_CREATE1`, `MOVE_TYPE`, `MOVE_PLANT` and `MOVE_STLOC` are **header** fields (`BAPI2093_RES_HEAD`, one movement type per reservation, as in MB21). The "movement allowed" flag `MOVEMENT` is an **item** field. The code does it the other way round. Likewise, `BAPI_RESERVATION_CHANGE` normally uses the tables `RESERVATIONITEMS_CHANGED` / `RESERVATIONITEMS_CHANGEDX` (`BAPI2093_RES_ITEM_CHANGE` / `…X`), not `RESERVATIONITEMS` / `…X` with `_C` / `_CX` types. | Align with SE37 / SE11 before activating. This closes README points 2 and 3 / FS O4. |

---

## 3. High – functional / data integrity

**H1 – Reposting a failed reversal posts a second 301.** (`ZMM_R_301_MOV_MONITOR` L190, `Z_MM_301_POST_TRANSFER`)
Mode P always calls the FM with `iv_reversal = abap_false`. If a 102 row is in status E (for example because the 302 failed on a lock), the repost goes down the forward path, and the FM never checks `MSEG-BWART`. The result is another 301 instead of a 302.
→ The FM should derive the direction from the source line: `iv_reversal = xsdbool( ls_seg-bwart = '102' )`. Treat the parameter as a hint at most.

**H2 – A partial reversal cancels the whole 301.** (`Z_MM_301_POST_TRANSFER` L142)
`BAPI_GOODSMVT_CANCEL` reverses the complete 301 document. A 102 for part of the GR quantity therefore moves back the full quantity.
→ If `ls_seg-menge` < the original 301 quantity, post a **302 via `BAPI_GOODSMVT_CREATE`** for the 102 quantity instead of cancelling. Also pass `goodsmvt_pstng_date` = the 102 posting date, and store the 302 document number (see M3).

**H3 – The catch-up scan re-transfers GRs that were already reversed.** (`ZMM_R_301_MOV_MONITOR` `select_catchup`)
The scan selects every 101 with no transfer log, including 101s that a 102 has since cancelled. It also never looks for 102s that are missing a 302.
→ Exclude 101 lines referenced by a 102 (`MSEG-SMBLN / SJAHR / SMBLP`), and add a second scan for 102s whose original has an open 301.

**H4 – The catch-up filter differs from the BAdI filter.** (`select_catchup` vs `ZCL_MM_301_GR_TRIGGER`)
The catch-up does not check the header material, the validity window or `KZBEW`. It will post 301s that the BAdI would have skipped, such as co-products or GRs outside the activation window.
→ Put the eligibility rules in one reusable method, for example a static `ZCL_MM_301_GR_TRIGGER=>is_eligible( )`, and have the BAdI, the catch-up and the FM all call it.

**H5 – No lock between the tRFC, the monitor repost and the catch-up, so the same GR item can be posted twice.**
The idempotency check (FM L39) is a plain read. A catch-up run can pick up a GR whose tRFC unit has not yet executed, and both then post.
→ Create a lock object on `ZMM_301_MOV_LOG` (`SRC_MBLNR / MJAHR / ZEILE`) and call `ENQUEUE_EZMM_301_MOV` at FM entry (`_scope = '1'`). If the lock fails, exit and log. As a second safeguard, have the catch-up ignore GRs younger than N minutes.

**H6 – The log is written after the commit, so a crash in between causes a duplicate.** (`Z_MM_301_POST_TRANSFER` L297 → `FORM finish`)
`BAPI_TRANSACTION_COMMIT` persists the 301, and only afterwards does `finish` run `MODIFY zmm_301_mov_log` plus its own commit. If the work process dies between the two, the 301 exists but has no log row, and the next run posts it again.
→ The material document number is known before the commit. Run `MODIFY zmm_301_mov_log` (with `MOV_MBLNR`) **before** `BAPI_TRANSACTION_COMMIT` so both land in one LUW. The same pattern applies in `create_reservation`, where `write_detail_log` runs after the commit.

**H7 – `COMMIT WORK` / `BAPI_TRANSACTION_COMMIT` inside a function called `IN BACKGROUND TASK`.**
Under classic tRFC this usually works, but it breaks the unit's transactional guarantee: all items of one GR run in one unit, and after a dump the earlier items are replayed. Under **bgRFC**, which the code itself recommends (FS M8), it is a hard runtime error.
→ Register a thin wrapper (for example `Z_MM_301_POST_TRANSFER_TRFC`) that calls the worker `DESTINATION 'NONE'`, which gives it its own session and LUW. Alternatively, move to bgRFC now and have the worker commit through a separate `DESTINATION 'NONE'` call. Use `AS SEPARATE UNIT` per item if items must be independent.

**H8 – Self-rescheduling chains freeze their selection dates.**
- Monitor (L329): `so_budat` is passed as-is. A chain started in September scans September GRs forever and never sees October.
- Reservation report (L819): `p_rsdat` is passed as-is, so new reservations get a requirement date further and further in the past. The W019 warning is suppressed in batch.
→ In the chain, recompute the window each run (for example, a parameter "last N days"), or set `so_budat` / `p_rsdat` relative to `sy-datum` in `INITIALIZATION` and do not pass them in the `SUBMIT`.

---

## 4. Medium

| # | Where | Finding / recommendation |
|---|---|---|
| M1 | BAdI L65-70, catch-up | `MSEG-AUFNR` is also filled on a **101 for a purchase order account-assigned to an order**. Add the filter `KZBEW = 'F'` (GR from production order). Also confirm whether HBM uses **REM / MFBF**: a repetitive-manufacturing GR is **mvt 131**, not 101, and the README expects MFBF to be covered. |
| M2 | BAdI `is_header_material` | The comment says co-products are skipped, but co-products are also `AFPO` items, so they pass. If only the main product counts, read `AFKO-PLNBEZ` or `AFPO-POSNR = '0001'`, or check `AFPO-KZBWS` / co-product flag as the FS requires. |
| M3 | FM reversal path | The 302 document number is never stored: the reversal row has status R but `MOV_MBLNR` is blank. Capture `goodsmvt_headret` from `BAPI_GOODSMVT_CANCEL` so there is an audit trail. |
| M4 | FM L57-59 | If the MSEG line is not found, the FM returns silently with no log row. Log E instead so the monitor shows it. Also re-check the validity window in the FM, because repost and catch-up bypass the BAdI check. |
| M5 | FM L68, BAdI `get_control`, monitor | The control lookup uses only `WERKS_FR`, while the key is `WERKS_FR + WERKS_TO`. If a second destination is ever maintained, `SELECT SINGLE` picks one at random. Either enforce one active pair per origin (check in the SM30 maintenance event) or pass the pair explicitly. |
| M6 | Report L510/516 vs FM L260/268 | Storage locations come from different sources: the reservation uses `p_lgor_fr / p_lgor_to` from the selection screen, the posting uses the GR `LGORT` and `ZMM_301_CTRL-LGORT_TO`. If they differ, the BAPI rejects the reservation reference ("does not agree with reservation"). Read the storage locations from `ZMM_301_CTRL` in both places, and include `LGORT / UMLGO` in the FM's RESB check (L181). |
| M7 | Report (whole run) | Two concurrent runs (for example a chain plus an online run) both see "no reservation" and both create one. Add a report-level lock (`ENQUEUE_ESINDX` or a custom lock on plant pair + run) and, ideally, a check for an existing released `ZMM301R_CHAIN` / `ZMM301M_CHAIN` job before scheduling another (TBTCO). |
| M8 | Report `change_reservation` close | Closing an untouched reservation sets BDMNG = ENMNG = **0**, which the BAPI is likely to reject. Use the deletion flag when ENMNG = 0 and the final-issue indicator (KZEAR) otherwise, instead of reducing the quantity. |
| M9 | Report drift L409 | Drift = `WEMNG − ENMNG` of the *latest* reservation. It is permanently wrong for orders partly received before go-live, or when a reservation was recreated. Base it on the sum of `ZMM_301_MOV_LOG` transfers per order instead. |
| M10 | Report `select_open_orders` (a) | Every run reads all orders in the plant with `ELIKZ = space`, including old TECO/CLSD ones, and then does 1-3 SELECTs per order. This load grows with history. Pre-filter at the database: join or exclude through JEST (`NOT EXISTS` on I0045/I0046/I0076), or restrict with an `ERDAT` / `GLTRP` window. |
| M11 | Report `write_detail_log` | One row per order **per run**, including N (unchanged) and S (simulated), at a 5-minute frequency means about 288 × orders rows per day. Log only changes and errors, or add an archiving/purge report. |

---

## 5. Low / maintainability

| # | Finding |
|---|---|
| L1 | `SELECT-OPTIONS … FOR ('AUFNR')` (both reports): the dynamic `FOR (name)` form loses F4 help and conversion-exit handling for AUFNR/MATNR at design time. Prefer static typing: `DATA gv_aufnr TYPE aufnr. SELECT-OPTIONS so_aufnr FOR gv_aufnr.` |
| L2 | Monitor `repost` L193: `ls_o` is not cleared between iterations. If the SELECT finds no row, the previous item's status is counted. Add `CLEAR ls_o` or check `sy-subrc`. |
| L3 | `schedule_next` / `schedule_next_run`: `JOB_CLOSE` `sy-subrc` is not checked, yet S013 "next run scheduled" is always issued. A failed close leaves the chain dead with no alert. Also consider `JOB_SUBMIT` / `cl_bp_abap_job` and a dedicated batch user. |
| L4 | `AT SELECTION-SCREEN` validates only on `ONLI` or in batch. Execute in background (F9, `SJOB`) skips validation. Add `SJOB` (and `PRIN`). |
| L5 | `FORM finish` in the function group: FORMs are obsolete. Move the logging into a small local or global class (`lcl_log`) shared by the FM and both reports. BAL creation, the run log, the frequency logic and `run_id` are duplicated three times. |
| L6 | FM L207: if `T001K` is not found, `lv_bukrs` is blank and the error only surfaces later as "fiscal year could not be determined". Check `sy-subrc` after each lookup. |
| L7 | Hard-coded default plants `8P01` / `8Q01` on the selection screens: move them to a parameter ID or variant so the objects stay reusable after the migration. |

---

## 6. Points to confirm in the system (in addition to the README list)

1. **Update-task context:** with CO11N auto-GR, COGI reprocessing and decoupled confirmations, `MB_DOCUMENT_BEFORE_UPDATE` may run inside the update task. Test that the `IN BACKGROUND TASK` registration still fires once, and only after the GR is committed.
2. **tRFC order:** a 101 followed quickly by its 102 gives no ordering guarantee between the two tRFC units. If the 302 runs first, it logs W "no original 301" and the 301 then posts. Together with H5, this is the strongest argument for a **bgRFC inbound queue keyed on MATNR/WERKS** (FS M8).
3. **Batch + split valuation at 8Q01:** if the material is batch-managed and split-valuated at the destination, the valuation type is a batch attribute (`MCHA-BWTAR`). Check that `MOVE_BATCH` = same batch with a different `MOVE_VAL_TYPE` is accepted.
4. **Lock collisions:** the reservation report (`BAPI_RESERVATION_CHANGE`) and the 301 posting both lock RESB. Expect occasional E rows; the catch-up covers them, but a single retry with `WAIT UP TO 2 SECONDS` would reduce noise.

---

## 7. Suggested fix order

1. B1-B4 (activation) → 2. H1, H2, H3 (wrong stock) → 3. H5, H6 (duplicates) → 4. H8 (chains) → 5. H4 + M1/M2 (one eligibility rule) → 6. H7 (bgRFC decision, with FS M8) → then Medium and Low items.
