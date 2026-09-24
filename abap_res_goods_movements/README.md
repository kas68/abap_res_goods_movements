# 301 Migration Transfer — ABAP objects

Reference implementation for the two FSD+TSD documents (v0.3):
- **R-xxx-SEG** (formerly FS-MM-301RES-001) — reservation create/align program
- **E-xxx-SEG** (formerly FS-MM-301MOV-001) — GR-triggered 301 posting

> These are on-premise S/4HANA ABAP sources meant as a build starting point. They are
> structured and commented to match the FSs. A few standard-API field names must be
> confirmed in the target release (marked below and with `*** verify ***` in code).

## Files

| File | Object | Type |
|---|---|---|
| `00_DDIC_and_message_class.md` | Z tables, data elements, message class, log objects, tcodes | DDIC / SE91 |
| `ZMM_R_CREATE_301_RESERV.abap` | Reservation create/align report (txn ZMM301R) | Report |
| `ZCL_MM_301_GR_TRIGGER.abap` | MB_DOCUMENT_BADI implementation | Class |
| `Z_MM_301_POST_TRANSFER.abap` | Decoupled 301 posting (RFC-enabled) | Function module |
| `ZMM_R_301_MOV_MONITOR.abap` | Monitor / repost / catch-up (txn ZMM301M) | Report |

## Install order

1. Create data elements/domains as needed, then the **tables** and **message class ZMM301** (`00_DDIC...md`).
2. Create SLG0 log objects `ZMM/Z301RES`, `ZMM/Z301MOV`.
3. Create the **function group** and function module `Z_MM_301_POST_TRANSFER` (mark *Remote-Enabled*).
4. Create report `ZMM_R_CREATE_301_RESERV` (+ text symbols, listbox for P_FUNIT) and tcode `ZMM301R`.
5. Create report `ZMM_R_301_MOV_MONITOR` and tcode `ZMM301M`.
6. Create class `ZCL_MM_301_GR_TRIGGER` and a **BAdI implementation of `MB_DOCUMENT_BADI`** pointing to it.
7. Maintain config: `ZMM_301_CTRL` (plant pair 8P01/8Q01, storage locations, ACTIVE), and `ZMM_301_VALTYPE` (one row per fiscal year → destination valuation type).

## Points to verify in the target system (see FS open issues)

1. **`BAPI2017_GM_ITEM_CREATE` receiving valuation-type field** — code uses `VAL_TYPE_MOVE`; confirm the exact field name (candidate: `VAL_TYPE_MOVE` vs `MOVE_VAL_TYPE`). Origin `VAL_TYPE` is left blank (origin not split-valuated). *(FS M9)*
2. **`BAPI_RESERVATION_CHANGE`** availability and the `BAPI2093_RES_ITEM_C` / `_CX` field names for the qty change; MB22 FM/BDC is the fallback. *(FS O4)*
3. **`BAPI_RESERVATION_CREATE1`** item fields (`MATERIAL_LONG`/`MATERIAL`, `MOVE_TYPE`, `MOVE_PLANT`, `MOVE_STLOC`).
4. **GM code** `04` for the 301 transfer posting.
5. **`MB_DOCUMENT_BADI`** is enhanceable in the release and fires for all GR channels (MIGO/MB31/CO11N/MFBF). `MB_DOCUMENT_BEFORE_UPDATE` is called in the posting LUW just **before** the update task is triggered (not in the update task — that is `MB_DOCUMENT_UPDATE`); `XMKPF` and `XMSEG` are both tables. Confirm in SE18. *(FS M1)*
6. **Decoupling** — `IN BACKGROUND TASK` (tRFC) registers the posting after the GR commit. For strict serialisation per material/plant, switch to a **bgRFC** queue. Confirm the "immediate" tolerance. *(FS M8)*
7. **Order status codes** (JEST) `I0002` REL, `I0045` TECO, `I0046` CLSD, `I0076` DLFL, `I0013` DLT match the plant's status profile.
9. **Authorisation objects** — reservation report: `M_MRES_WWA` (ACTVT, WERKS) + `M_MRES_BWA` (ACTVT, BWART); posting FM: `M_MSEG_WMB` (ACTVT, WERKS) + `M_MSEG_BWA` (ACTVT, BWART). Confirm in SU21.
10. **`BAPI2093_RES_ITEM_C1-ITEM_TEXT`** used to carry the order number on the reservation item.
8. **Company code / fiscal-year variant** derivation (`T001W→T001K→T001`) and `FI_PERIOD_DETERMINE` usage for the posting-date fiscal year.

## Design notes carried from the FSs

- Reservation *remaining* (`BDMNG − ENMNG`) is kept equal to PO *remaining* (`PSMNG − WEMNG`): target `BDMNG = PO open + ENMNG`. Movements are expected and never lock the reservation.
- The goods receipt is sacred: the 301 posts in a separate LUW; a transfer failure never rolls back the GR. The reservation program's drift check and the monitor's catch-up are the safety nets.
- Origin plant is not split-valuated; only the destination valuation type (current fiscal year, from `ZMM_301_VALTYPE`) is set on the 301.
- Batch frequency (self-reschedule) parameter range: 1 minute … multiple days.

## Change log

| Date | Change |
|---|---|
| 22-Sep-2026 | Aligned with FSD+TSD v0.3: explicit authority checks (reservation + posting); application log (BAL) in both reports and the posting FM with `BALLOGNR` stored; `SELECT SINGLE … ORDER BY` replaced by `UP TO 1 ROWS` (latest link / valuation type); detail log keyed by the real order item; delivered orders that still hold an open reservation are now selected and closed; TECO/CLSD orders without a reservation are no longer given one; JEST codes corrected (DLFL = I0076, DLT = I0013); material-in-destination-plant check; `GJAHR` stored in `ZMM_301_MOV_LOG`; idempotency based on `MOV_MBLNR` (covers postings without reservation); reversal lookup includes the year (`SJAHR`); BAdI loops `XMKPF` as a table; monitor filters on the GR posting date, posting-date window mandatory (default current month), methods `select_log` / `select_catchup` / `repost`. |
