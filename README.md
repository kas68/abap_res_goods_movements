# 301 Migration Transfer — ABAP objects

Reference implementation for the two functional specs:
- **FS-MM-301RES-001** — reservation create/align program
- **FS-MM-301MOV-001** — GR-triggered 301 posting

> These are on-premise S/4HANA ABAP sources meant as a build starting point. They are
> structured and commented to match the FSs. A few standard-API field names must be
> confirmed in the target release (marked below and with `*** verify ***` in code).

## Files

| File | Object | Type |
|---|---|---|
| `IMPLEMENTATION_GUIDE.md` | Step-by-step build with every description, label and text to enter | Guide |
| `00_DDIC_and_message_class.md` | Messages 027–051 of `ZPTP_SPLIT_VAL`, domains/data elements, Z tables, log objects, other objects | DDIC / SE91 |
| `ZPTP_301_RESERVATION_GENERATOR.abap` | Reservation create/align report (txn ZPTP_301_RES) | Report |
| `ZCL_IM_MB_DOC_301_TRANSFER.abap` | Class of BAdI implementation `ZMB_DOC_301_TRANSFER` (`MB_DOCUMENT_BADI`) — delegates only | Class |
| `ZCE_MB_DOCUMENT_BADI_301.abap` | Enhancement class with the GR-trigger logic | Class |
| `Z_PTP_301_TRANSFER_POST.abap` | Decoupled 301 posting (RFC-enabled, function group `ZPTP_301_TRANSFER`) | Function module |
| `ZPTP_301_MOVEMENT_MONITOR.abap` | Monitor / repost / catch-up (txn ZPTP_301_MON) | Report |

## Install order

1. Create messages **027–051** in the existing message class **ZPTP_SPLIT_VAL** (`00_DDIC...md` §1).
2. Create domains/data elements, the configuration tables `ZPTP_301_CTRL` / `ZPTP_301_VALTYPE` with table maintenance, then the log tables (`00_DDIC...md` §2–4).
3. Create SLG0 log objects `ZPTP/Z301RES`, `ZPTP/Z301MOV`.
4. Create the **function group** `ZPTP_301_TRANSFER` and function module `Z_PTP_301_TRANSFER_POST` (mark *Remote-Enabled*).
5. Create report `ZPTP_301_RESERVATION_GENERATOR` (+ text symbols, listbox for P_FUNIT) and tcode `ZPTP_301_RES`.
6. Create report `ZPTP_301_MOVEMENT_MONITOR` and tcode `ZPTP_301_MON`.
7. Create class `ZCE_MB_DOCUMENT_BADI_301`, then the **BAdI implementation `ZMB_DOC_301_TRANSFER` of `MB_DOCUMENT_BADI`** (SE19) with class `ZCL_IM_MB_DOC_301_TRANSFER`.
8. Maintain config: `ZPTP_301_CTRL` (plant pair 8P01/8Q01, storage locations, ACTIVE), and `ZPTP_301_VALTYPE` (one row per fiscal year → destination valuation type).

## Points to verify in the target system (see FS open issues)

1. **`BAPI2017_GM_ITEM_CREATE` receiving valuation-type field** — resolved: code uses `MOVE_VAL_TYPE` (UMBAR). Origin `VAL_TYPE` is left blank (origin not split-valuated). *(FS M9)*
2. **`BAPI_RESERVATION_CHANGE`** availability and the `BAPI2093_RES_ITEM_C` / `_CX` field names for the qty change; MB22 FM/BDC is the fallback. *(FS O4)*
3. **`BAPI_RESERVATION_CREATE1`** item fields (`MATERIAL_LONG`/`MATERIAL`, `MOVE_TYPE`, `MOVE_PLANT`, `MOVE_STLOC`).
4. **GM code** `04` for the 301 transfer posting.
5. **`MB_DOCUMENT_BADI`** is enhanceable in the release and fires for all GR channels (MIGO/MB31/CO11N/MFBF). Confirm `MB_DOCUMENT_BEFORE_UPDATE` parameter types (`XMKPF`, `XMSEG`). *(FS M1)*
6. **Decoupling** — `IN BACKGROUND TASK` (tRFC) registers the posting after the GR commit. For strict serialisation per material/plant, switch to a **bgRFC** queue. Confirm the "immediate" tolerance. *(FS M8)*
7. **Order status codes** (JEST) `I0002/I0045/I0046/I0043/I0076` match the plant's status profile.
8. **Company code / fiscal-year variant** derivation (`T001W→T001K→T001`) and `FI_PERIOD_DETERMINE` usage for the posting-date fiscal year.

## Design notes carried from the FSs

- Reservation *remaining* (`BDMNG − ENMNG`) is kept equal to PO *remaining* (`PSMNG − WEMNG`): target `BDMNG = PO open + ENMNG`. Movements are expected and never lock the reservation.
- The goods receipt is sacred: the 301 posts in a separate LUW; a transfer failure never rolls back the GR. The reservation program's drift check and the monitor's catch-up are the safety nets.
- Origin plant is not split-valuated; only the destination valuation type (current fiscal year, from `ZPTP_301_VALTYPE`) is set on the 301.
- Batch frequency (self-reschedule) parameter range: 1 minute … multiple days.
- **Finished products**: the reservation report reserves the production order's finished product (`AFPO-MATNR`) for the 301 from 8P01 to 8Q01, for **released** orders only (`RES_KIND = H`).
- **Optional raw materials** (`P_RAWMAT`, off by default): for **open** orders (created or released, not TECO/CLSD/deleted), the report also creates a **separate** 301 reservation 8Q01→8P01 holding the order's short components (`RESB` requirement − `MARD-LABST` in 8P01), one item per component (`RES_KIND = R`). It is independent of the finished-product reservation. Components that become short later go into a new RM reservation. Physical execution is manual (MB1B/MIGO); the GR-trigger object ignores it.
- **Order ↔ reservation link**: primary link is `ZPTP_301_RES_LOG` (`AUFNR` + `RES_KIND` + `POSNR` → `RSNUM`/`RSPOS`). Every reservation item also carries the production order in the goods recipient field (`RESB-WEMPF`, BAPI `GR_RCPT`), visible in MB25; the reservation report and the posting FM fall back to it when no log row is found.
