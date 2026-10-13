# 301 Transfer 8P01 ⇄ 8Q01 — ABAP objects

Creates 301 transfer reservations for production orders and posts the 301 transfers against them.

- **Reservation generator** — creates and aligns the reservations.
- **Transfer report** — lists the open reservations and posts the 301 movements selected by the user.

> On-premise S/4HANA ABAP sources. A few standard-API field names must be confirmed in the target release (see *Points to verify*).

## Objects

| Object | Type | Purpose |
|---|---|---|
| `ZPTP_301_RESERVATION_GENERATOR.abap` | Report (txn `ZPTP_301_RES`) | Create / align / close the 301 reservations |
| `ZPTP_301_RESERVATION_TRANSFER.abap` | Report (txn `ZPTP_301_TRF`) | Open reservations with stock; post the selected 301 transfers |
| `Z_PTP_301_RES_TRANSFER_POST.abap` | Function module (group `ZPTP_301_TRANSFER`) | Posts one 301 against one reservation item |

## Flow

1. **Reservation generator** keeps, for each open production order, a 301 reservation whose open quantity (`BDMNG − ENMNG`) equals the open order quantity (`PSMNG − WEMNG`).
   - **Finished product** (`AFPO-MATNR`), 8P01 → 8Q01 (`RES_KIND = H`): released orders only.
   - **Raw-material components**, 8Q01 → 8P01 (`RES_KIND = R`, selected with `P_KIND` = `R` or `A`): open orders (created or released). One reservation per order holds the components that are short in 8P01 (requirement − `MARD-LABST`). It is independent of the finished-product reservation.
2. **Transfer report** shows the open reservation items. The user selects items and posts the 301 transfers.

Nothing is posted automatically at goods receipt.

## Reservation generator

### Selection and run control
- Plants `P_WERKFR` (default 8P01) / `P_WERKTO` (default 8Q01). Storage locations `P_LGORFR` / `P_LGORTO` are optional **overrides** (see *Storage locations*).
- Orders: `SO_AUFNR`, `SO_AUART`, `SO_MATNR`, `SO_DISPO`; requirement date `P_RSDAT`.
- Only the header item (`AFPO-POSNR = 0001`, no co-products) and issue components (`RESB-SHKZG = H`, no by-products) are considered. Components must be stock items (`POSTP = L`), not deleted, not phantom, not final-issued.
- Run mode (radio buttons): see *Run modes*. `P_ERRON` reprocesses only items whose last status is an error, `P_EXTSL` extends the material to the target storage location when it is missing (see below), `P_CLRLG` deletes all rows of `ZPTP_301_RUN_LOG` and `ZPTP_301_RES_LOG` before the run (asks for confirmation online; ignored in test mode), `P_MOVE` sets *movement allowed* (`RESB-XWAOK`).
- Reservation kind (`P_KIND`, dropdown, default `A`): `H` finished products only, `R` components (raw materials) only, `A` all (both). Raw materials: issuing plant `P_WERKRF` (8Q01) and receiving plant `P_WERKRT` (8P01); storage locations `P_LGORRF` / `P_LGORRT` are optional overrides.
- Order ↔ reservation link: `ZPTP_301_RES_LOG` (`AUFNR`, `RES_KIND`, `POSNR` → `RSNUM`/`RSPOS`). Each reservation item also carries the order number in `RESB-WEMPF` (BAPI field `GR_RCPT`); the generator falls back to it when no log row exists.

### Run modes
| Mode | Radio button | Behaviour |
|---|---|---|
| 1 Test | `R_TEST` | Simulation of all selected orders; nothing is created, changed or logged in the detail log. The result list is only displayed. |
| 2 Online (default) | `R_ONL` | Starts like the test mode (simulation) and shows the result list with a checkbox column *Create* on the left of every line, in the same layout. The user ticks lines and presses **Create reservations** (function `CREATE`): all lines (finished product and raw materials) of every production order that has a ticked line are processed for real and replace their simulated lines; other orders stay simulated. The button can be used repeatedly. Cannot run in the background. |
| 3 Background | `R_BACK` | All reservations are created / realigned / closed. Can run as a background job. When run online the result list is displayed afterwards. |

The run log (`ZPTP_301_RUN_LOG`) is finished when the online list is left, with the counters of the final result list.

### Storage locations
- **Source (issuing) storage location of a new reservation item**: the storage location typed on the selection screen (override), else the storage location of the order.
  - Finished product (8P01 → 8Q01): `AFPO-LGORT` of the order item.
  - Raw materials (8Q01 → 8P01): the order does not carry the 8Q01 storage location, so only the screen field `P_LGORRF` is used.
  - **Fallback** (finished products and raw materials): when no source storage location is known, the storage locations of the source plant (`MARD`) that hold the material are tried one after the other, the one with the most unrestricted stock (`LABST`) first. The first one for which `ZPTP_301_LGORT` returns a target is used as source **and** target. If none gives a target, the source is the storage location with the most unrestricted stock (blank if there is none) and the target stays blank; a row with a blank `LGORT_FR` still matches in that case.
- **Target (receiving) storage location**: the storage location typed on the selection screen (override), else table `ZPTP_301_LGORT`, read with the direction (`H` finished product / `R` raw material), the plant pair, the **source storage location** and the material type (`MARA-MTART`). The most specific entry wins: first the entry for the source storage location (blank = any source storage location), then the entry for the material type (blank = all material types). No entry → blank.

The receiving storage location is a reservation header field. Raw-material components of one order that resolve to different receiving storage locations therefore go into separate reservations. Existing reservations keep their storage locations; they are not changed by the realign. All storage locations maintained in `ZPTP_301_LGORT` for the plant pair(s) of the run must exist in the plant (message 041).

### Material extension to the target storage location
Before a reservation is created (not in simulations), the generator checks for every item whether the material exists in the target storage location (`MARD` for the receiving plant and storage location). If not, and the option **Extend material to target storage location** (`P_EXTSL`, default on) is ticked, it extends the material:
- `BAPI_MATERIAL_SAVEDATA` with the storage location view (`STORAGE_VIEW`), committed immediately.
- Data copied from the source storage location (`MARD`): storage bin (`LGPBE`), storage location MRP indicator (`DISKZ`), special procurement type (`LSOBS`), reorder point (`LMINB`), replenishment quantity (`LBSTF`), inventory correction factor (`BSKRF`). Fields that do not exist in the BAPI structure of the release are skipped.
- Prerequisites: the material exists in the target plant (`MARC`) and the target storage location exists (`T001L`). Otherwise the line gets the status *Create error* with the reason, and the other lines of the reservation are still created.
- The result line says "material extended to target SLoc". In the simulation the status text announces it ("material will be extended to target SLoc").
- This changes the material master (change documents are written by the BAPI).

### Result list (ALV)
- Grouped (sorted, with a separator) by **kind** first (`H` finished product / `R` raw material), then by production order, then by item.
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
- Reads `ZPTP_301_RES_LOG`: the latest reservation item per order / kind / item (`RSNUM <> blank`), then `RESB` (items with `XLOEK` set are not listed).
- ALV per item: state (*Open* / *Closed*: `KZEAR` or `BDMNG <= ENMNG`), *Followed by 301* (successful row in `ZPTP_301_TRF_LOG` whose material document is not reversed yet; reversal documents are recognised through `MSEG-SMBLN`/`SJAHR`), reservation quantity `BDMNG`, withdrawn `ENMNG`, quantity of the 301 movement(s), last material document, and the action `POST` will take.
- `POST` (function of GUI status `ZMANAGER`) on the ticked items, after a confirmation popup:
  - not followed by a movement: `BAPI_RESERVATION_CHANGE` with `DELETE_IND = X`;
  - followed by a movement: `BAPI_GOODSMVT_CANCEL` for every material document of the item (posting date `P_BUDAT`), logged in `ZPTP_301_TRF_LOG` with `STATUS = R`; only if all reversals succeed, the item is deleted. If the deletion fails after the reversals, the line is yellow and says so.
- Selection: `SO_RSNUM`, `SO_AUFNR`, `SO_MATNR`, `SO_ERDAT` (date of the log entry), `P_BUDAT` (posting date of the reversals).
- Text symbols: 001 *Reservation selection*, 002 *Reversal*. Selection texts: `SO_RSNUM` Reservation, `SO_AUFNR` Production order, `SO_MATNR` Material, `SO_ERDAT` Log date, `P_BUDAT` Posting date of the reversals. GUI status `ZMANAGER` (SE41, copy of `STANDARD_FULLSCREEN` of `SAPLKKBL`, add `POST`, text *Delete / reverse*, icon `ICON_DELETE`).

## Transfer report

- Lists open 301 reservation items (`RESB`: `BWART = 301`, `WERKS` = source plant, `UMWRK` = destination plant, not deleted / final-issued, `XWAOK = X`, `BDMNG > ENMNG`) with material, open quantity (`BDMNG − ENMNG`) and the **unrestricted** stock in the source (`MARD-LABST`, or `MCHB-CLABS` if the item has a batch). Quality-inspection and blocked stock are not counted.
- Run it with 8P01 → 8Q01 for finished products and with 8Q01 → 8P01 for raw-material reservations.
- Select items, adjust *Qty to post* (default = open reservation quantity) and the batch if needed, tick *Close res.* to close the item with the posting (final issue, `IV_CLOSE` → `WITHDRAWN = X`), press **Post transfer** (function `POST`).
- The quantity must be > 0, ≤ the open reservation quantity and ≤ the unrestricted stock. Partial transfers are allowed; the item stays open for the rest.
- One call of `Z_PTP_301_RES_TRANSFER_POST` per item = one posting = one commit. A failing item never blocks the others. Results show in the *Message* column and in `ZPTP_301_TRF_LOG`.
- A 301 is cancelled manually with MBST; cancelling restores `ENMNG` and the reservation reopens.

## Posting function module `Z_PTP_301_RES_TRANSFER_POST`

1. Reads the reservation item; it must be open and the quantity must not exceed the open quantity.
2. Batch-managed materials require a batch.
3. Re-checks the unrestricted stock.
4. **Valuation type**
   - *Forward* (8P01 → 8Q01; an active `ZPTP_301_CTRL` entry exists for the plant pair): the destination valuation type is read from `ZPTP_301_VALTYPE` for the destination plant, the material type (`MARA-MTART`) and the fiscal year of the posting date (company code from the source plant via `T001W` → `T001K`, `FI_PERIOD_DETERMINE`). The most specific entry wins: plant-specific over blank plant, then material-type-specific over blank material type. The source valuation type stays blank (8P01 is not split-valuated). No entry → error, nothing posted.
   - *Reverse* (8Q01 → 8P01): no mapping; the source valuation type is read from the source batch (`MCHA-BWTAR`).
5. Creates the batch in the destination plant from the source batch when it does not exist (`BAPI_BATCH_GET_DETAIL`, `BAPI_BATCH_CREATE`); the new batch is committed with the 301.
6. Posts the 301 with `BAPI_GOODSMVT_CREATE` (`GM_CODE 04`) referencing the reservation (`RESERV_NO`, `RES_ITEM`, `RES_TYPE` blank), commits, and writes `ZPTP_301_TRF_LOG`.

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
| RES_KIND | X | CHAR1 | Direction: `H` = finished product (8P01 → 8Q01), `R` = raw material (8Q01 → 8P01) |
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
| TEST_RUN, SELF_SCHED | | CHAR1 |
| FREQ_VALUE, FREQ_UNIT | | INT4, CHAR3 |
| NEXT_RUN_DT, NEXT_RUN_TM | | DATUM, UZEIT |
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
Fields: `RUN_ID` SYSUUID_C32, `AUFNR`, `MATNR`, `WERKS_FR`, `WERKS_TO`, `MENGE` (reference `MEINS`), `MEINS`, `CHARG`, `BWTAR`, `STATUS` CHAR1 (S/E), `MESSAGE` CHAR255, `MOV_MBLNR`, `MOV_MJAHR`, `ERNAM`.

## Installation

1. Create the messages (SE91).
2. Create the tables (SE11) and the table maintenance for `ZPTP_301_CTRL` and `ZPTP_301_VALTYPE`.
3. Create the function group `ZPTP_301_TRANSFER` and the function module `Z_PTP_301_RES_TRANSFER_POST` (normal function module).
4. Create the report `ZPTP_301_RESERVATION_GENERATOR` (SE38; attributes: executable program, Unicode checks and fixed point arithmetic on) with its text symbols and selection texts, and transaction `ZPTP_301_RES`.
5. Generator GUI status `ZGENERATOR` (SE41, program `ZPTP_301_RESERVATION_GENERATOR`): copy `STANDARD_FULLSCREEN` of `SAPLKKBL` and add function `CREATE` (text *Create reservations*, icon `ICON_CREATE`) to the application toolbar. It is used by the online mode.
5a. Create the report `ZPTP_301_RESERVATION_TRANSFER` with its text symbols and selection texts, the GUI status `ZTRANSFER` (SE41: copy `STANDARD_FULLSCREEN` of `SAPLKKBL`, add function `POST` with text *Post transfer* and icon `ICON_EXECUTE_OBJECT` to the application toolbar), and transaction `ZPTP_301_TRF`.
6. Maintain the configuration: `ZPTP_301_CTRL` (8P01 → 8Q01, `ACTIVE = X`), `ZPTP_301_VALTYPE` and `ZPTP_301_LGORT`.

### Text elements — generator
Text symbols: 001 *Plants and storage locations*, 002 *Order selection*, 003 *Run control*, 007 *Run mode*, 008 *Options*, 009 *Reservation kind*, 010 *H = Finished products only*, 011 *R = Components (raw materials) only*, 012 *A = All (finished products and components)*, 005 *Raw materials (8Q01 -> 8P01)*, 006 *Collective orders / exclusions*, L04 *Finished products*, L05 *Components*, L06 *All*.
Selection texts: `P_WERKFR` Origin plant, `P_LGORFR` Origin storage location (override of the order's storage location), `P_WERKTO` Destination plant, `P_LGORTO` Destination storage location (override), `SO_AUFNR` Production order, `SO_AUART` Order type, `SO_MATNR` Material, `SO_DISPO` MRP controller, `P_RSDAT` Reservation requirement date, `P_MOVE` Movement allowed, `R_TEST` 1 Test (simulation, nothing is created), `R_ONL` 2 Online (simulation, then create the ticked orders), `R_BACK` 3 Background (all reservations are created), `P_ERRON` Reprocess errors only, `P_EXTSL` Extend material to target storage location, `P_CLRLG` Clean all logs before the run, `P_KIND` Reservation kind (dropdown: H finished products / R components / A all), `P_WERKRF` RM issuing plant, `P_LGORRF` RM issuing storage location (override), `P_WERKRT` RM receiving plant, `P_LGORRT` RM receiving storage location (override), `P_COLL` Collective orders: leading / lowest level, `P_EXCL` Apply exclusion list, `P_FILE` Exclusion spreadsheet (.xlsx).

### Text elements — transfer report
Text symbols: 001 *Plants (up to 2 combinations)*, 002 *Reservation selection*, 003 *Posting*, C01 *Combination 1*, C02 *Combination 2*, C03 *From plant*, C04 *To plant*.
Selection texts: `P_ACT1` / `P_ACT2` Active (combination 1 / 2), `P_WFR1` / `P_WFR2` Source plant (issuing), `P_WTO1` / `P_WTO2` Destination plant (receiving), `SO_RSNUM` Reservation, `SO_AUFNR` Production order, `SO_MATNR` Material, `SO_BDTER` Requirement date, `P_STOCK` Only items with unrestricted stock, `P_BUDAT` Posting date.

## Test

1. Generator in test mode on one released order: status *Simulated*, no reservation. In background mode: reservation created (check MB23 and `RESB-WEMPF`). Run again: *Unchanged*; change the order quantity: *Realigned*. In online mode: tick two orders, press *Create reservations*, check that only those two are created.
2. `P_KIND` = `R` on an order with a short component; `P_COLL` on a multi-level collective order; `P_EXCL` with an upload file.
3. Transfer report: post a transfer with the default quantity, then a partial quantity, then a quantity above the stock (must be refused). Check the material document, `ZPTP_301_TRF_LOG` and `RESB-ENMNG`.
4. Raw-material direction (8Q01 → 8P01) and a batch-managed material whose batch does not exist in the destination plant.

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
