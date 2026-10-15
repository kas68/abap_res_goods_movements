# 301 Transfer 8P01 ⇄ 8Q01 — ABAP objects

Creates 301 transfer reservations for production orders and posts the 301 transfers against them.

- **Reservation generator** — creates and aligns the reservations.
- **Transfer report** — lists the open reservations and posts the 301 movements selected by the user.
- **Reservation manager** — deletes reservations created by the generator, reversing their 301 postings first if needed.
- **Log manager** — checks the consistency of the three log tables and deletes log records.

> On-premise S/4HANA ABAP sources. A few standard-API field names must be confirmed in the target release (see *Points to verify*).

## Objects

| Object | Type | Purpose |
|---|---|---|
| `ZPTP_301_RESERVATION_GENERATOR.abap` | Report (txn `ZPTP_301_RES`) | Create / align / close the 301 reservations |
| `ZPTP_301_RESERVATION_TRANSFER.abap` | Report (txn `ZPTP_301_TRF`) | Open reservations with stock; post the selected 301 transfers |
| `Z_PTP_301_RES_TRANSFER_POST.abap` | Function module (group `ZPTP_301_TRANSFER`) | Posts one 301 against one reservation item |
| `ZPTP_301_RESERVATION_MANAGER.abap` | Report (txn `ZPTP_301_MGR`) | Deletes generator reservations, reversing their 301 postings |
| `ZPTP_301_LOG_MANAGER.abap` | Report (txn `ZPTP_301_LOG`) | Checks and cleans the three log tables |

## Flow

1. **Reservation generator** keeps, for each open production order, a 301 reservation whose open quantity (`BDMNG − ENMNG`) equals the open order quantity (`PSMNG − WEMNG`).
   - **Finished product** (`AFPO-MATNR`), 8P01 → 8Q01 (`RES_KIND = H`): released orders only.
   - **Raw-material components**, 8Q01 → 8P01 (`RES_KIND = R`, selected with `P_KIND` = `R` or `A`): open orders (created or released). One reservation per order holds the components that are short in 8P01 (requirement − `MARD-LABST`). It is independent of the finished-product reservation.
2. **Transfer report** shows the open reservation items. The user selects items and posts the 301 transfers.
3. **Reservation manager** deletes reservations that must be cancelled (reversing the 301 postings first). **Log manager** checks and cleans the logs.

Nothing is posted automatically at goods receipt.

## Reservation generator

### Selection and run control
- Plants `P_WERKFR` (default 8P01) / `P_WERKTO` (default 8Q01). The storage locations are not entered on the screen (see *Storage locations*).
- Orders: `SO_AUFNR`, `SO_AUART`, `SO_MATNR`, `SO_DISPO`; requirement date `P_RSDAT`.
- Only the header item (`AFPO-POSNR = 0001`, no co-products) and issue components (`RESB-SHKZG = H`, no by-products) are considered. Components must be stock items (`POSTP = L`), not deleted, not phantom, not final-issued.
- Run mode (radio buttons): see *Run modes*. `P_EXTSL` extends the material to the target storage location when it is missing (see below), `P_MOVE` sets *movement allowed* (`RESB-XWAOK`).
- Reservation kind (`P_KIND`, dropdown, default `A`): `H` finished products only, `R` components (raw materials) only, `A` all (both). Raw materials: issuing plant `P_WERKRF` (8Q01) and receiving plant `P_WERKRT` (8P01).
- Order ↔ reservation link: `ZPTP_301_RES_LOG` (`AUFNR`, `RES_KIND`, `POSNR` → `RSNUM`/`RSPOS`). Each reservation item also carries the order number in `RESB-WEMPF` (BAPI field `GR_RCPT`); the generator falls back to it when no log row exists.

### Run modes
| Mode | Radio button | Behaviour |
|---|---|---|
| 1 Test | `R_TEST` | Simulation of all selected orders; nothing is created, changed or logged in the detail log. The result list is only displayed. |
| 2 Online (default) | `R_ONL` | Starts like the test mode (simulation) and shows the result list with a checkbox column *Create* on the left of every line, in the same layout. The user ticks lines and presses **Create reservations** (function `CREATE`): all lines (finished product and raw materials) of every production order that has a ticked line are processed for real and replace their simulated lines; other orders stay simulated. The button can be used repeatedly. Cannot run in the background. |
| 3 Background | `R_BACK` | All reservations are created / realigned / closed. Can run as a background job. When run online the result list is displayed afterwards. |

The run log (`ZPTP_301_RUN_LOG`) is finished when the online list is left, with the counters of the final result list.

### Storage locations
- In **online mode** the columns *From SLoc* / *To SLoc* of the result list are editable. When *Create reservations* is pressed, the values typed on lines without a reservation replace the determined ones (checked against `T001L` of the line's plant; an order with an invalid storage location is not processed and keeps its lines with status *Error*). Existing reservations are not changed.
- **Finished product (kind `H`, 8P01 → 8Q01)**
  - Source storage location: `AFPO-LGORT` of the order item.
  - Fallback when the order has none: the storage locations of the source plant (`MARD`) that hold the material are tried one after the other, the one with the most unrestricted stock (`LABST`) first. The first one for which `ZPTP_301_LGORT` returns a target is used as source **and** target. If none gives a target, the source is the storage location with the most unrestricted stock (blank if there is none) and the target stays blank.
  - Target storage location: table `ZPTP_301_LGORT`, read with kind `H`, the plant pair, the **source storage location** and the material type (`MARA-MTART`). The most specific entry wins: first the entry for the source storage location (blank = any), then the entry for the material type (blank = all). No entry → blank.
- **Raw-material component (kind `R`, 8Q01 → 8P01)** — the table `ZPTP_301_LGORT` is **not** used:
  - Source storage location: the storage location of the issuing plant (`MCHB`) where the **batch of the component** (`RESB-CHARG` of the component line) has unrestricted stock (`CLABS > 0`), the one with the most stock first. A component without batch: the storage location of `MARD` with the most unrestricted stock. Nothing found → blank.
  - Target storage location: the storage location of the **component item in the production order** (`RESB-LGORT` of the component line).

The receiving storage location is a reservation header field. Raw-material components of one order that resolve to different receiving storage locations therefore go into separate reservations. Existing reservations keep their storage locations; they are not changed by the realign. All storage locations maintained in `ZPTP_301_LGORT` for the finished-product plant pair of the run must exist in the plant (message 041).

### Material extension to the target storage location
Before a reservation is created (not in simulations), the generator checks for every item whether the material exists in the target storage location (`MARD` for the receiving plant and storage location). If not, and the option **Extend material to target storage location** (`P_EXTSL`, default on) is ticked, it extends the material:
- `BAPI_MATERIAL_SAVEDATA` with the storage location view (`STORAGE_VIEW`), committed immediately.
- Data copied from the source storage location (`MARD`): storage bin (`LGPBE`), storage location MRP indicator (`DISKZ`), special procurement type (`LSOBS`), reorder point (`LMINB`), replenishment quantity (`LBSTF`), inventory correction factor (`BSKRF`). Fields that do not exist in the BAPI structure of the release are skipped.
- Prerequisites: the material exists in the target plant (`MARC`) and the target storage location exists (`T001L`). Otherwise the line gets the status *Create error* with the reason, and the other lines of the reservation are still created.
- The result line says "material extended to target SLoc". In the simulation the status text announces it ("material will be extended to target SLoc").
- This changes the material master (change documents are written by the BAPI).

### Result list (ALV)
- Sorted and grouped (with a separator) by **production order** first, then by item, then by **kind** (`H` finished product / `R` raw material). The *Kind* column is next to *Item*.
- In online mode the columns *From SLoc* / *To SLoc* are editable (see *Storage locations*).
- The columns **Description** (`MAKT-MAKTX`, logon language) and **Mat. type** (`MARA-MTART`) follow the material column; **Batch (order)** (the batch of the production order: `AFPO-CHARG` for the finished product, `RESB-CHARG` of the component line for raw materials; the same batch is written on the new reservation item, BAPI field `BATCH`, so the transfer report proposes it) and **Ext. to target plant** (checkbox) follow the material type and is ticked when the material exists in the target plant (`MARC`).
- Column **Coll.Order Lead**: ticked only on the rows of an order that is the **leading order of a collective order** (not on lower-level orders, not on orders outside a collective order).
- Column **Lead coll. order**: the leading order of the collective order the order belongs to (found by following `AFKO-MAUFNR` up to the top); blank for orders that are not part of a collective order.
- Colour by status: **C** created, **F** complete and **N** unchanged green, **X** closed dark grey (nearest palette colour), **R** realigned yellow. The status colour wins over the grey of a collective order. The ALV grid offers a fixed palette of colours and chooses the text colour itself, so white text on green or dark grey cannot be forced.
- Lines with status **E** (error) are in **red on white**; this wins over the grey of a collective order.
- Rows of the **lowest-level** order of a collective order (`AFKO-PRODNET`) have a light-grey background; rows of the other orders of a collective order are in grey font (palette colour with inverse text). Bold is not used.
- Text colour cannot be set freely in the ALV palette: white text on light grey is not available, and would not be readable.

### Decision per reservation item

| Existing reservation | Open basis quantity | Action |
|---|---|---|
| No | ≤ 0 | Nothing (finished product: logged as *Fully received*) |
| No | > 0 | Create |
| Yes | ≤ 0, or order TECO/CLSD/deleted | Close (`BDMNG = ENMNG`) |
| Yes | > 0, different from reservation | Realign (`BDMNG = basis + ENMNG`) |
| Yes | > 0, equal | Unchanged |

A reservation item with the **deletion indicator** (`RESB-XLOEK`) counts as *No* (never created): a new reservation is created for the open basis quantity and the deleted item is never changed. An item that is **closed** (final issue, `RESB-KZEAR`) counts as completed: status *Complete*, nothing is done.

### Collective orders — option `P_COLL`
- Finished product (8P01 → 8Q01): only for the **leading** order.
- Components (8Q01 → 8P01): only for the **lowest-level** order.
- Orders that are not part of a collective order behave normally.
- Hierarchy source: `AFKO-PRODNET` = part of a collective order, `AFKO-MAUFNR` = superior order. Leading = no superior order; lowest level = no order has it as `MAUFNR`. *** verify *** that `MAUFNR` holds the order directly above; otherwise the lowest-level test must use `AFKO-LKNOT` / `AFKO-RKNOT` (only `collective_role` changes).

### Exclusion list — option `P_EXCL`
- Table `ZPTP_301_EXCL` holds the orders that get no finished-product reservation (`EXCL_H`) and/or no component reservation (`EXCLR`).
- Upload an `.xlsx` from the local PC (`P_FILE`, F4), **online runs only**: worksheet 1 = orders without finished-product reservation, worksheet 2 = orders without component reservation. Column A, header row allowed. The upload **replaces** the stored list.
- Every run, including background runs, reads the list from `ZPTP_301_EXCL`. Run online with a file whenever the list changes.

### Skipped orders
Shown in the ALV and the detail log with status *Skipped* and the reason. Reservations that already exist for a skipped order are left untouched; close them manually (MB22) if an option is switched on after the reservations were created.

### Scheduling
The program does not reschedule itself; schedule it as a (recurring) background job in SM36 with a variant using **3 Background**.

## Reservation manager — `ZPTP_301_RESERVATION_MANAGER` (txn `ZPTP_301_MGR`)
Deletes reservation items created by the generator, with reversal of the 301 postings if any.
- Finds the items in three places: `ZPTP_301_RES_LOG` (latest reservation item per order / kind / item, `RSNUM <> blank`), `ZPTP_301_TRF_LOG` (items with a successful 301 posting; still found after the item log has been cleaned) and `RESB` (`BWART = 301`, `WEMPF` = order number; only when `SO_RSNUM`, `SO_AUFNR` or `SO_MATNR` is filled). Then reads `RESB` (items with `XLOEK` set are not listed). Column *Found via* shows the source.
- ALV per item: state (*Open* / *Closed*: `KZEAR` or `BDMNG <= ENMNG`), *Followed by 301* (successful row in `ZPTP_301_TRF_LOG` whose material document is not reversed yet; reversal documents are recognised through `MSEG-SMBLN`/`SJAHR`), reservation quantity `BDMNG`, withdrawn `ENMNG`, quantity of the 301 movement(s), last material document, and the action `POST` will take.
- `POST` (function of GUI status `ZMANAGER`) on the ticked items, after a confirmation popup:
  - not followed by a movement: `BAPI_RESERVATION_CHANGE` with `DELETE_IND = X`;
  - followed by a movement: `BAPI_GOODSMVT_CANCEL` for every material document of the item (posting date `P_BUDAT`), logged in `ZPTP_301_TRF_LOG` with `STATUS = R`; only if all reversals succeed, the item is deleted. If the deletion fails after the reversals, the line is yellow and says so.
- Selection: `SO_RSNUM`, `SO_AUFNR`, `SO_MATNR`, `SO_ERDAT` (date of the log entry), `P_BUDAT` (posting date of the reversals).
- Text symbols: 001 *Reservation selection*, 002 *Reversal*. Selection texts: `SO_RSNUM` Reservation, `SO_AUFNR` Production order, `SO_MATNR` Material, `SO_ERDAT` Log date, `P_BUDAT` Posting date of the reversals. GUI status `ZMANAGER` (SE41, copy of `STANDARD_FULLSCREEN` of `SAPLKKBL`, add `POST`, text *Delete / reverse*, icon `ICON_DELETE`).

## Log manager — `ZPTP_301_LOG_MANAGER` (txn `ZPTP_301_LOG`)
Checks and cleans `ZPTP_301_RES_LOG`, `ZPTP_301_TRF_LOG` and `ZPTP_301_RUN_LOG`.
- Selection: `SO_AUFNR` (order), `SO_RSNUM` (reservation), `SO_RUNID` (run ID, item log or transfer log), `SO_ERDAT` (date of the log rows).
- One line per item of the logs (`AUFNR`, `RES_KIND`, `POSNR`, `RSNUM`, `RSPOS`; transfer-log-only items have no kind). Kind and last status are highlighted (cell colours). Three checkbox columns *In Run Log*, *In Res Log* and *In TRF Log* show whether the record of the item exists in each of the three log tables (run log: at least one of the item's runs is found). Consistency check with the icon green / yellow / red against `RESB` and `MSEG`: status X or F with the item still open, item missing or deleted in `RESB`, quantity of the log (statuses R / N) different from `RESB`, material document not in `MSEG`, document reversed (`MSEG-SMBLN`) without reversal row (status R) in the transfer log, `RESB-ENMNG` different from the 301 postings of the log, run ID missing in `ZPTP_301_RUN_LOG`.
- `DELETE` (after confirmation): deletes all rows of the item in `ZPTP_301_RES_LOG` and `ZPTP_301_TRF_LOG`, then the `ZPTP_301_RUN_LOG` rows of the runs with no item row left. Items whose reservation exists and has a 301 posting not reversed are blocked.
- `P_CLRLG`: after a warning popup with the row counts, deletes all rows of `ZPTP_301_RES_LOG`, `ZPTP_301_TRF_LOG` and `ZPTP_301_RUN_LOG` whatever the selection and ends the program.
- Text symbols: 001 *Selection*, 002 *Options*. Selection texts: `SO_AUFNR` Production order, `SO_RSNUM` Reservation, `SO_RUNID` Run ID, `SO_ERDAT` Execution date, `P_CLRLG` Clean all logs. GUI status `ZLOGMGR` (SE41, copy of `STANDARD_FULLSCREEN` of `SAPLKKBL`, add `DELETE`, text *Delete log records*, icon `ICON_DELETE`).

## Transfer report

- Lists open 301 reservation items of up to **two plant combinations** (`RESB`: `BWART = 301`, `WERKS` = source plant, `UMWRK` = destination plant, not deleted / final-issued, `XWAOK = X`, `BDMNG > ENMNG`) with material, open quantity (`BDMNG − ENMNG`) and the **unrestricted** stock in the source (`MARD-LABST`, or `MCHB-CLABS` if the item has a batch). Quality-inspection and blocked stock are not counted.
- Plants: combination 1 (`P_ACT1`, `P_WFR1`, `P_WTO1`, default 8P01 → 8Q01, finished products) and combination 2 (`P_ACT2`, `P_WFR2`, `P_WTO2`, default 8Q01 → 8P01, raw materials). Both are active by default; at least one must be active, each active combination needs two different existing plants, and the two cannot be identical.
- Editable columns: *Qty to post* (default = open reservation quantity), *From SLoc* (source storage location), *Batch*, and the checkbox *Close res.*. Quantities are shown with 3 decimals (no unit link on the quantity columns: with a unit such as MG the grid would read a typed 1250 as 1.250).
- Press **Post transfer** (function `POST`). The stock check of the report and of the function module uses the storage location and batch typed in the grid (function module parameter `IV_LGORT`). Tick *Close res.* to close the item with the posting (final issue, `IV_CLOSE` → `WITHDRAWN = X`); the quantity must still be > 0.
- The quantity must be > 0, ≤ the open reservation quantity and ≤ the unrestricted stock of the entered storage location and batch. Partial transfers are allowed; the item stays open for the rest.
- One call of `Z_PTP_301_RES_TRANSFER_POST` per item = one posting = one commit. A failing item never blocks the others. Results show in the *Message* column (SAP error messages end with their class and number, for example *(M7 509)*) and in `ZPTP_301_TRF_LOG`.
- A 301 is cancelled manually with MBST (the reservation reopens), or with the reservation manager, which also deletes the reservation item.

## Posting function module `Z_PTP_301_RES_TRANSFER_POST`

Interface: `IV_RSNUM`, `IV_RSPOS`, `IV_MENGE`, `IV_CHARG` (optional), `IV_LGORT` (source storage location as chosen by the user, blank = whole plant), `IV_BUDAT`, `IV_RUN_ID` (optional), `IV_CLOSE` (optional, `X` = final issue); exports `EV_STATUS` (S / E), `EV_MESSAGE`, `EV_MBLNR`, `EV_MJAHR`. Every exit writes `ZPTP_301_TRF_LOG`.

1. Reads the reservation item; it must be open (not deleted, not final-issued) and the quantity must not exceed the open quantity.
2. Checks the source storage location (`T001L`) and the batch: a batch-managed material needs a batch, a material that is not batch-managed must not have one.
3. Re-checks the unrestricted stock for the storage location and batch entered (`MCHB-CLABS` with a batch, `MARD-LABST` without).
4. **Valuation type**
   - *Forward* (8P01 → 8Q01; an active `ZPTP_301_CTRL` entry exists for the plant pair): the destination valuation type is read from `ZPTP_301_VALTYPE` for the destination plant, the material type (`MARA-MTART`) and the fiscal year of the posting date (company code from the source plant via `T001W` → `T001K`, `FI_PERIOD_DETERMINE`). The most specific entry wins: plant-specific over blank plant, then material-type-specific over blank material type. The source valuation type stays blank (8P01 is not split-valuated). No entry → error, nothing posted.
   - *Reverse* (8Q01 → 8P01): no mapping; the source valuation type is read from the source batch (`MCHA-BWTAR`).
5. Creates the batch in the destination plant from the source batch when it does not exist (`BAPI_BATCH_GET_DETAIL`, `BAPI_BATCH_CREATE`); the new batch is committed with the 301.
6. Posts the 301 with `BAPI_GOODSMVT_CREATE` (`GM_CODE 04`) referencing the reservation (`RESERV_NO`, `RES_ITEM`; `RES_TYPE` blank because `RESB-RSART` is blank), with `STGE_LOC` = the entered storage location and, if `IV_CLOSE` is set, `WITHDRAWN = X`. Commits and writes `ZPTP_301_TRF_LOG`. A BAPI error is returned with the message text and its class / number.

## DDIC objects

Package `ZPTP_301_MIGRATION`. Message class `ZPTP_SPLIT_VAL`.

### Messages (SE91)

| No. | Text | Used by |
|---|---|---|
| 027 | Origin plant &1 and destination plant &2 must be different | Generator, transfer report |
| 028 | No open production orders found for the selection | Generator |
| 040 | Plant &1 does not exist | Generator |
| 041 | Storage location &1 does not exist for plant &2 | Generator |
| 042 | RM plants required and must differ (source &1 / target &2) | Generator |
| 052 | No open 301 reservations found for the selection | Transfer report |
| 053 | No item selected | Transfer report |

### Configuration tables (delivery class `C`, table maintenance generated, authorization group `&NC&` = none)

`ZPTP_301_CTRL`, `ZPTP_301_VALTYPE` and `ZPTP_301_LGORT`.

**`ZPTP_301_CTRL`** — plant pair control

| Field | Key | Type | Description |
|---|:---:|---|---|
| MANDT | X | MANDT | Client |
| WERKS_FR | X | WERKS_D | Origin plant (8P01) |
| WERKS_TO | X | WERKS_D | Destination plant (8Q01) |
| ACTIVE | | XFELD | On/off: marks the plant pair as *forward* (valuation type applies) in the posting |

**`ZPTP_301_LGORT`** — target storage location of the reservations

| Field | Key | Type | Description |
|---|:---:|---|---|
| MANDT | X | MANDT | Client |
| RES_KIND | X | CHAR1 | Direction: `H` = finished product (8P01 → 8Q01). `R` rows are no longer read: the storage locations of raw materials come from the batch stock and the production order |
| WERKS_FR | X | WERKS_D | Issuing plant |
| WERKS_TO | X | WERKS_D | Receiving plant |
| LGORT_FR | X | LGORT_D | Source (issuing) storage location, blank = any (check table `T001L` with `WERKS_FR`) |
| MTART | X | MTART | Material type, blank = all material types |
| LGORT_TO | | LGORT_D | Target (receiving) storage location (check table `T001L` with `WERKS_TO`) |

**`ZPTP_301_VALTYPE`** — destination valuation type

| Field | Key | Type | Description |
|---|:---:|---|---|
| MANDT | X | MANDT | Client |
| WERKS | X | WERKS_D | Destination plant (blank = all plants) |
| MTART | X | MTART | Material type (blank = all material types) |
| GJAHR | X | GJAHR | Fiscal year |
| BWTAR | | BWTAR_D | Destination valuation type |
| DESCR | | TEXT40 | Comment |
| ACTIVE | | XFELD | Entry active |

Maintain one row per plant / material type / fiscal year before the year starts; keep a blank-`MTART` row as the fallback.

### Data tables (delivery class `A`, data class `APPL1`, size category `0`)

**`ZPTP_301_EXCL`** — exclusion list (key `MANDT, AUFNR`; `EXCL_H` CHAR1, `EXCLR` CHAR1, `UPL_DATE` DATS, `UPL_BY` UNAME)

**`ZPTP_301_RUN_LOG`** — one row per generator run

| Field | Key | Type |
|---|:---:|---|
| MANDT, RUN_ID | X | MANDT, SYSUUID_C32 |
| RUN_MODE (O/B), JOBNAME, JOBCOUNT, VARIANT | | CHAR1, BTCJOB, BTCJOBCNT, RALDB_VARI |
| WERKS_FR, WERKS_TO | | WERKS_D |
| SEL_TEXT | | STRING |
| TEST_RUN | | CHAR1 |
| SELF_SCHED, FREQ_VALUE, FREQ_UNIT, NEXT_RUN_DT, NEXT_RUN_TM (**no longer filled**: the rescheduling was removed) | | CHAR1, INT4, CHAR3, DATUM, UZEIT |
| START_DATE, START_TIME, END_DATE, END_TIME | | DATUM, UZEIT |
| DURATION_S | | INT4 |
| CNT_SELECTED, CNT_CREATED, CNT_REALIGNED, CNT_CLOSED, CNT_UNCHANGED, CNT_SKIPPED, CNT_DRIFT, CNT_ERROR | | INT4 |
| STATUS (R/S/W/A), BALLOGNR, ERNAM, MESSAGE | | CHAR1, BALOGNR, ERNAM, STRING |

**`ZPTP_301_RES_LOG`** — per-item reservation log

| Field | Key | Type |
|---|:---:|---|
| MANDT, AUFNR, RES_KIND, POSNR, RUN_ID | X | MANDT, AUFNR, CHAR1 (H/R), CO_POSNR, SYSUUID_C32 |
| RSNUM, RSPOS | | RSNUM, RSPOS |
| WERKS_FR, WERKS_TO, MATNR | | WERKS_D, WERKS_D, MATNR |
| PO_OPEN, RES_BDMNG, RES_ENMNG | | MENGE_D |
| MEINS | | MEINS |
| STATUS | | CHAR1 (C created, R realigned, X closed, N unchanged, F complete, K skipped, E error, S simulated) |
| MESSAGE, ERDAT, ERZET, ERNAM | | STRING, ERDAT, ERZET, ERNAM |

**`ZPTP_301_TRF_LOG`** — one row per transfer attempt (key `MANDT, RSNUM, RSPOS, ERDAT, ERZET`)
Fields: `RUN_ID` SYSUUID_C32, `AUFNR`, `MATNR`, `WERKS_FR`, `WERKS_TO`, `MENGE` (reference `MEINS`), `MEINS`, `CHARG`, `BWTAR`, `STATUS` CHAR1 (S posted, E error, R reversal written by the reservation manager), `MESSAGE` CHAR255, `MOV_MBLNR`, `MOV_MJAHR`, `ERNAM`.

### Which program writes and deletes the log tables

| Table | Written by | Deleted by |
|---|---|---|
| `ZPTP_301_RUN_LOG` | Generator | Log manager only |
| `ZPTP_301_RES_LOG` | Generator | Log manager only |
| `ZPTP_301_TRF_LOG` | Posting function module; reservation manager (reversal rows, status R) | Log manager only |

No other program deletes log records. The SAP application log (SLG1) is not used (`BALLOGNR` of the run log stays empty).

## Installation

1. Create the messages (SE91).
2. Create the tables (SE11) and the table maintenance for `ZPTP_301_CTRL` and `ZPTP_301_VALTYPE`.
3. Create the function group `ZPTP_301_TRANSFER` and the function module `Z_PTP_301_RES_TRANSFER_POST` (normal function module).
4. Create the report `ZPTP_301_RESERVATION_GENERATOR` (SE38; attributes: executable program, Unicode checks and fixed point arithmetic on) with its text symbols and selection texts, and transaction `ZPTP_301_RES`.
5. Generator GUI status `ZGENERATOR` (SE41, program `ZPTP_301_RESERVATION_GENERATOR`): copy `STANDARD_FULLSCREEN` of `SAPLKKBL` and add function `CREATE` (text *Create reservations*, icon `ICON_CREATE`) to the application toolbar. It is used by the online mode.
5a. Create the report `ZPTP_301_RESERVATION_TRANSFER` with its text symbols and selection texts, the GUI status `ZTRANSFER` (SE41: copy `STANDARD_FULLSCREEN` of `SAPLKKBL`, add function `POST` with text *Post transfer* and icon `ICON_EXECUTE_OBJECT` to the application toolbar), and transaction `ZPTP_301_TRF`.
5b. Create the report `ZPTP_301_RESERVATION_MANAGER` with its text elements, the GUI status `ZMANAGER` (SE41, function `POST`, text *Delete / reverse*, icon `ICON_DELETE`) and transaction `ZPTP_301_MGR`.
5c. Create the report `ZPTP_301_LOG_MANAGER` with its text elements, the GUI status `ZLOGMGR` (SE41, function `DELETE`, text *Delete log records*, icon `ICON_DELETE`) and transaction `ZPTP_301_LOG`. Restrict the transaction to the key user.
6. Maintain the configuration: `ZPTP_301_CTRL` (8P01 → 8Q01, `ACTIVE = X`), `ZPTP_301_VALTYPE` (one row per destination plant, material type and fiscal year, before the year starts) and `ZPTP_301_LGORT` (finished-product rows only: raw-material storage locations come from the batch stock and the production order).

### Text elements — generator
Text symbols: 001 *Plants and storage locations*, 002 *Order selection*, 003 *Run control*, 007 *Run mode*, 008 *Options*, 009 *Reservation kind*, 010 *H = Finished products only*, 011 *R = Components (raw materials) only*, 012 *A = All (finished products and components)*, 005 *Raw materials (8Q01 -> 8P01)*, 006 *Collective orders / exclusions*, L04 *Finished products*, L05 *Components*, L06 *All*.
Selection texts: `P_WERKFR` Origin plant, `P_WERKTO` Destination plant, `SO_AUFNR` Production order, `SO_AUART` Order type, `SO_MATNR` Material, `SO_DISPO` MRP controller, `P_RSDAT` Reservation requirement date, `P_MOVE` Movement allowed, `R_TEST` 1 Test (simulation, nothing is created), `R_ONL` 2 Online (simulation, then create the ticked orders), `R_BACK` 3 Background (all reservations are created), `P_EXTSL` Extend material to target storage location, `P_KIND` Reservation kind (dropdown: H finished products / R components / A all), `P_WERKRF` RM issuing plant, `P_WERKRT` RM receiving plant, `P_COLL` Collective orders: leading / lowest level, `P_EXCL` Apply exclusion list, `P_FILE` Exclusion spreadsheet (.xlsx).

### Text elements — reservation manager
Text symbols: 001 *Reservation selection*, 002 *Reversal*. Selection texts: `SO_RSNUM` Reservation, `SO_AUFNR` Production order, `SO_MATNR` Material, `SO_ERDAT` Log date, `P_BUDAT` Posting date of the reversals.

### Text elements — transfer report
Text symbols: 001 *Plants (up to 2 combinations)*, 002 *Reservation selection*, 003 *Posting*, C01 *Combination 1*, C02 *Combination 2*, C03 *From plant*, C04 *To plant*.
Selection texts: `P_ACT1` / `P_ACT2` Active (combination 1 / 2), `P_WFR1` / `P_WFR2` Source plant (issuing), `P_WTO1` / `P_WTO2` Destination plant (receiving), `SO_RSNUM` Reservation, `SO_AUFNR` Production order, `SO_MATNR` Material, `SO_BDTER` Requirement date, `P_STOCK` Only items with unrestricted stock, `P_BUDAT` Posting date.

## Test

1. Generator in test mode on one released order: status *Simulated*, no reservation. In background mode: reservation created (check MB23 and `RESB-WEMPF`). Run again: *Unchanged*; change the order quantity: *Realigned*. In online mode: tick two orders, press *Create reservations*, check that only those two are created.
2. `P_KIND` = `R` on an order with a short component; `P_COLL` on a multi-level collective order; `P_EXCL` with an upload file.
3. Transfer report: post a transfer with the default quantity, then a partial quantity, then a quantity above the stock (must be refused). Check the material document, `ZPTP_301_TRF_LOG` and `RESB-ENMNG`.
4. Raw-material direction (8Q01 → 8P01) and a batch-managed material whose batch does not exist in the destination plant.
5. Transfer report: change *From SLoc* and *Batch* in the grid and check that the stock check follows them; post with *Close res.* ticked and check `RESB-KZEAR`.
6. Reservation manager: delete a reservation without movement (`RESB-XLOEK`), and one with a 301 posting (document reversed first, row with status R in `ZPTP_301_TRF_LOG`). Run the generator afterwards: a new reservation is created for the open quantity.
7. Log manager: list a few items (lights and texts), then delete an item without active 301, check that a blocked item is refused, check `ZPTP_301_RUN_LOG` for runs left without items.

## Points to verify in the target system

1. `BAPI_RESERVATION_CREATE1` item and header fields, and its mandatory table parameter `PROFITABILITYSEGMENT` (passed empty; its type is read from the function interface). Interface errors of the create and change BAPIs are reported on the result line, they do not dump.
   Item and header fields to verify: (`MATERIAL_LONG`, `MOVE_TYPE`, `MOVE_PLANT`, `MOVE_STLOC`, `GR_RCPT`).
2. `BAPI_RESERVATION_CHANGE` availability and the item / item-X field names for the quantity change; MB22 FM/BDC is the fallback.
3. `BAPI_MATERIAL_SAVEDATA` (storage location view: parameters `HEADDATA`, `STORAGELOCATIONDATA`, `STORAGELOCATIONDATAX`, `RETURN`, `RETURNMESSAGES`; components of `BAPI_MARD` such as `STGE_BIN`, `MRP_IND`).
3a. `BAPI_BATCH_GET_DETAIL` and `BAPI_BATCH_CREATE` parameter names (type of `RETURN`, `MATERIAL_LONG`).
4. `BAPI2017_GM_ITEM_CREATE` fields `VAL_TYPE` / `MOVE_VAL_TYPE`; `GM_CODE 04` for the transfer posting.
5. `RESB` fields `WEMPF`, `UMWRK`, `UMLGO`, `XWAOK`, `SHKZG`; `AFKO` fields `PRODNET`, `MAUFNR`.
6. Order status codes (`JEST`) `I0002`, `I0045`, `I0046`, `I0043`, `I0076` match the plant's status profile.
7. Company code and fiscal-year variant derivation (`T001W` → `T001K`) for the posting date.
8. Raw-material direction: the source valuation type comes from the source batch; without a batch it stays blank and the posting may need an explicit valuation type.
9. `BAPI_GOODSMVT_CREATE` with a blank `RES_TYPE` (the reservations have `RESB-RSART` blank) and with `WITHDRAWN = X` setting `RESB-KZEAR`; earlier attempts with `RES_TYPE` `R` and `B` gave message M7 509 ("no movements can be posted").
10. `BAPI_RESERVATION_CHANGE` field `DELETE_IND` (item and item-X structures) for the deletion used by the manager.
11. `BAPI_GOODSMVT_CANCEL` (parameters `MATERIALDOCUMENT`, `MATDOCUMENTYEAR`, `GOODSMVT_PSTNG_DATE`, `GOODSMVT_HEADRET`) and the fields `MSEG-SMBLN` / `SJAHR` used to recognise reversed documents.
