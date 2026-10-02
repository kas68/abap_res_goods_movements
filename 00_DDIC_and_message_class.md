# DDIC objects & messages — 301 migration transfer solution

> On-premise S/4HANA. Create these in SE11 / SE91 before activating the programs.
> Names follow the *SAP ABAP Development Standard and Naming Conventions* (workstream **PTP**):
> tables `Z<WS_ID>_<name>` (max. 16 characters), domains `Z<name>`, data elements `ZDE<name>`,
> generated table-maintenance function group = table name.
> Package: `ZPTP_301_MIGRATION`.

---

## 1. Messages — existing class `ZPTP_SPLIT_VAL` (SE91)

Numbers 000–026 belong to other developments; this solution uses **027–051**.

| No. | Message text (placeholders &1..&4) | Used by code |
|---|---|:---:|
| 027 | Origin plant &1 and destination plant &2 must be different | X |
| 028 | No open production orders found for the selection | X |
| 029 | Material &1 not maintained in destination plant &2 | |
| 030 | Order &1: fully received – skipped | |
| 031 | Order &1: reservation &2 created | |
| 032 | Order &1: reservation &2 realigned to qty &3 | |
| 033 | Order &1: reservation &2 closed | |
| 034 | Order &1: reservation &2 already aligned | |
| 035 | Order &1: BAPI error – &2 | |
| 036 | Frequency must be at least 1 minute | X |
| 037 | Frequency exceeds the configured maximum | X |
| 038 | Self-reschedule chain stopped (control flag inactive) | X |
| 039 | Next run scheduled at &1 &2 | X |
| 040 | Plant &1 does not exist | X |
| 041 | Storage location &1 does not exist for plant &2 | X |
| 042 | RM plants required and must differ (source &1 / target &2) | X |
| 043 | Order &1 component &2: 301 RM reservation &3 created (shortage &4) | |
| 044 | No authorization for movement 301 in plant &1 | X |
| 045 | GR &1/&2 item &3: 301 transfer &4 posted | |
| 046 | GR &1/&2 item &3: transfer already posted – skipped | |
| 047 | GR &1/&2 item &3: no valuation type for fiscal year &4 | |
| 048 | GR &1/&2 item &3: no reservation found for order &4 | |
| 049 | GR &1/&2 item &3: 301 posting error – &4 | |
| 050 | GR &1/&2 item &3: reversal 302 posted | |
| 051 | Automation inactive for plant pair &1 / &2 | |

---

## 2. Domains and data elements (SE11)

Standard data elements are used wherever they exist. Custom ones only where fixed values are needed.

| Domain | Type | Fixed values | Data element | Field label |
|---|---|---|---|---|
| `ZPTP301_NORES_ACT` | CHAR 1 | `P` = Post without reservation / `S` = Skip (log warning) | `ZDEPTP301_NORES_ACT` | No-reservation action |
| `ZPTP301_RES_KIND` | CHAR 1 | `H` = Finished product / `R` = Raw material | `ZDEPTP301_RES_KIND` | Reservation kind |
| `ZPTP301_RES_STAT` | CHAR 1 | `C` Created / `R` Realigned / `X` Closed / `N` Unchanged / `F` Complete / `K` Skipped / `E` Error / `S` Simulated | `ZDEPTP301_RES_STAT` | Reservation status |
| `ZPTP301_MOV_STAT` | CHAR 1 | `S` Success / `E` Error / `R` Reversed / `W` Warning | `ZDEPTP301_MOV_STAT` | Transfer status |

Only `ZPTP301_NORES_ACT` / `ZDEPTP301_NORES_ACT` are needed for the configuration tables (step 2); the
others are used by the log tables (step 4).

### Descriptions and field labels

Domain and data element share the same short description.

| Domain / Data element | Short description | Short (10) | Medium (20) | Long (40) | Heading |
|---|---|---|---|---|---|
| `ZPTP301_NORES_ACT` / `ZDEPTP301_NORES_ACT` | 301 migration: action when no reservation found | No resv. | No-resv. action | Action when no reservation found | No-resv. action |
| `ZPTP301_RES_KIND` / `ZDEPTP301_RES_KIND` | 301 migration: reservation kind | Res. kind | Reservation kind | Reservation kind (FP / raw material) | Kind |
| `ZPTP301_RES_STAT` / `ZDEPTP301_RES_STAT` | 301 migration: reservation processing status | Res.status | Reservation status | Reservation processing status | Status |
| `ZPTP301_MOV_STAT` / `ZDEPTP301_MOV_STAT` | 301 migration: transfer posting status | Trf.status | Transfer status | 301 transfer posting status | Status |

Fixed-value texts:

| Domain | Value | Text |
|---|---|---|
| `ZPTP301_NORES_ACT` | P | Post 301 without reservation reference |
| | S | Skip posting and log a warning |
| `ZPTP301_RES_KIND` | H | Finished product (8P01 -> 8Q01) |
| | R | Raw material (8Q01 -> 8P01) |
| `ZPTP301_RES_STAT` | C | Created |
| | R | Realigned |
| | X | Closed |
| | N | Unchanged |
| | F | Complete (fully consumed) |
| | K | Skipped (nothing to reserve) |
| | E | Error |
| | S | Simulated (test run) |
| `ZPTP301_MOV_STAT` | S | Success (301 posted) |
| | E | Error |
| | R | Reversed (302 posted) |
| | W | Warning (skipped, e.g. no reservation) |

---

## 3. Configuration tables (step 2)

Common settings for both tables:

| Setting | Value |
|---|---|
| Delivery class | **C** (customizing — content transported in a customizing request) |
| Data browser / table view maint. | Display/Maintenance allowed |
| Data class | APPL2 |
| Size category | 0 |
| Buffering | Buffering switched on — **fully buffered** (read on every GR by the BAdI) |
| Log data changes | **X** (standard: mandatory for SM30-maintained tables) |
| Storage type | Column store |
| Enhancement category | Can be enhanced (character-type or numeric) |

### 3.1 `ZPTP_301_CTRL` — control / configuration

| Field | Key | Data element | Check table | Description |
|---|:---:|---|---|---|
| MANDT | X | MANDT | T000 | Client |
| WERKS_FR | X | WERKS_D | T001W | Origin plant (8P01) |
| WERKS_TO | X | WERKS_D | T001W | Destination plant (8Q01) |
| LGORT_FR | | LGORT_D | T001L (WERKS = WERKS_FR) | Default origin storage location |
| LGORT_TO | | LGORT_D | T001L (WERKS = WERKS_TO) | Destination storage location |
| MOVE_TYPE | | BWART | T156 | Transfer movement type (blank = 301) |
| NO_RESV_ACTION | | ZDEPTP301_NORES_ACT | (fixed values) | P = post without reservation / S = skip |
| ACTIVE | | XFELD | | Automation on/off (stop switch for BAdI and job chains) |
| VALID_FROM | | DATAB | | Activation window start (GR posting date) |
| VALID_TO | | DATBI | | Activation window end |

Used by: BAdI enhancement class (`WERKS_FR`, `ACTIVE`, `VALID_FROM/TO`), `Z_PTP_301_TRANSFER_POST`
(all fields), reservation report and monitor (`ACTIVE`, stop switch for self-rescheduling).

### 3.2 `ZPTP_301_VALTYPE` — fiscal year → destination valuation type

| Field | Key | Data element | Check table | Description |
|---|:---:|---|---|---|
| MANDT | X | MANDT | T000 | Client |
| BUKRS | X | BUKRS | T001 | Company code (blank = valid for all) |
| GJAHR | X | GJAHR | | Fiscal year |
| BWTAR | | BWTAR_D | T149D | Destination valuation type for that fiscal year |
| DESCR | | TEXT40 | | Comment (not translated) |
| ACTIVE | | XFELD | | Entry active |

Used by: `Z_PTP_301_TRANSFER_POST` (company-code entry wins over the blank/global one).

### 3.3 Table maintenance (SE11 → Utilities → Table Maintenance Generator)

| Setting | `ZPTP_301_CTRL` | `ZPTP_301_VALTYPE` |
|---|---|---|
| Authorization group | `ZPTP` (not `&NC&`) | `ZPTP` |
| Function group | `ZPTP_301_CTRL` | `ZPTP_301_VALTYPE` |
| Maintenance type | One step | One step |
| Overview screen | 0001 | 0001 |
| Recording routine | Standard recording routine | Standard recording routine |

---

## 4. Log tables (step 4)

Delivery class **A**, data class APPL1, no buffering, column store. Size category according to
expected volumes; a purge/retention rule must be agreed (standard §Z/Y table creation).

### 4.1 `ZPTP_301_RUN_LOG` — execution log (FS-MM-301RES-001)

| Field | Key | Data element / type | Description |
|---|:---:|---|---|
| MANDT | X | MANDT | Client |
| RUN_ID | X | SYSUUID_C32 (CHAR32) | Run identifier |
| RUN_MODE | | CHAR1 | O=online / B=background |
| JOBNAME | | BTCJOB | Job name |
| JOBCOUNT | | BTCJOBCNT | Job count |
| VARIANT | | RALDB_VARI | Variant |
| WERKS_FR | | WERKS_D | Origin plant |
| WERKS_TO | | WERKS_D | Destination plant |
| SEL_TEXT | | STRING | Selection snapshot |
| TEST_RUN | | CHAR1 | X = simulation |
| SELF_SCHED | | CHAR1 | X = self-rescheduling |
| FREQ_VALUE | | INT4 | Frequency value |
| FREQ_UNIT | | CHAR3 | MIN/HRS/DAY |
| NEXT_RUN_DT | | DATUM | Next run date |
| NEXT_RUN_TM | | UZEIT | Next run time |
| START_DATE | | DATUM | Start date |
| START_TIME | | UZEIT | Start time |
| END_DATE | | DATUM | End date |
| END_TIME | | UZEIT | End time |
| DURATION_S | | INT4 | Duration (s) |
| CNT_SELECTED | | INT4 | Orders selected |
| CNT_CREATED | | INT4 | Created |
| CNT_REALIGNED | | INT4 | Realigned |
| CNT_CLOSED | | INT4 | Closed |
| CNT_UNCHANGED | | INT4 | Unchanged |
| CNT_SKIPPED | | INT4 | Skipped |
| CNT_DRIFT | | INT4 | Drift flagged |
| CNT_ERROR | | INT4 | Errors |
| STATUS | | CHAR1 | R/S/W/A |
| BALLOGNR | | BALOGNR | Application-log number |
| ERNAM | | ERNAM | Executed by |
| MESSAGE | | STRING | Summary / abort reason |

### 4.2 `ZPTP_301_RES_LOG` — per-order reservation detail log (FS-MM-301RES-001)

| Field | Key | Data element / type | Description |
|---|:---:|---|---|
| MANDT | X | MANDT | Client |
| AUFNR | X | AUFNR | Production order |
| RES_KIND | X | CHAR1 | H = finished product (8P01→8Q01) / R = raw-material component (8Q01→8P01) |
| POSNR | X | CO_POSNR | Header item (0001) or component item (RESB-RSPOS) |
| RUN_ID | X | SYSUUID_C32 (CHAR32) | Run identifier (FK → ZPTP_301_RUN_LOG) |
| RSNUM | | RSNUM | Reservation number |
| RSPOS | | RSPOS | Reservation item |
| WERKS_FR | | WERKS_D | Issuing plant (H: 8P01 / R: 8Q01) |
| WERKS_TO | | WERKS_D | Receiving plant (H: 8Q01 / R: 8P01) |
| MATNR | | MATNR | Header material (H) or component material (R) |
| PO_OPEN | | MENGE_D | Reserved basis qty (H: PSMNG−WEMNG / R: shortage) |
| RES_BDMNG | | MENGE_D | Reservation requirement qty |
| RES_ENMNG | | MENGE_D | Reservation withdrawn/transferred qty |
| MEINS | | MEINS | Base unit |
| STATUS | | CHAR1 | C=Created / R=Realigned / X=Closed / N=Unchanged / F=Complete / K=Skipped(fully received/no shortage) / E=Error / S=Simulated (see FS §7.3) |
| MESSAGE | | STRING | Message text |
| ERDAT | | ERDAT | Created on |
| ERZET | | ERZET | Created at |
| ERNAM | | ERNAM | Created by |

> Second link: every reservation item created by the report also carries the order number in `RESB-WEMPF` (goods recipient). Used as fallback when no row exists here.

### 4.3 `ZPTP_301_MOVRLOG` — monitor/repost execution log (FS-MM-301MOV-001)

| Field | Key | Data element / type | Description |
|---|:---:|---|---|
| MANDT | X | MANDT | Client |
| RUN_ID | X | SYSUUID_C32 | Run identifier |
| RUN_TYPE | | CHAR1 | M=monitor / P=repost / C=catch-up |
| RUN_MODE | | CHAR1 | O=online / B=background |
| JOBNAME | | BTCJOB | Job name |
| JOBCOUNT | | BTCJOBCNT | Job count |
| START_DATE | | DATUM | Start date |
| START_TIME | | UZEIT | Start time |
| END_DATE | | DATUM | End date |
| END_TIME | | UZEIT | End time |
| DURATION_S | | INT4 | Duration (s) |
| CNT_SCANNED | | INT4 | GRs examined |
| CNT_POSTED | | INT4 | 301 posted |
| CNT_REVERSED | | INT4 | 302 posted |
| CNT_SKIPPED | | INT4 | Idempotent skips |
| CNT_WARNING | | INT4 | Warnings |
| CNT_ERROR | | INT4 | Errors |
| STATUS | | CHAR1 | R/S/W/A |
| BALLOGNR | | BALOGNR | Application-log number |
| ERNAM | | ERNAM | Executed by |
| MESSAGE | | STRING | Summary |

### 4.4 `ZPTP_301_MOV_LOG` — per-GR movement log (FS-MM-301MOV-001)

| Field | Key | Data element / type | Description |
|---|:---:|---|---|
| MANDT | X | MANDT | Client |
| SRC_MBLNR | X | MBLNR | Source GR material document |
| SRC_MJAHR | X | MJAHR | Source GR document year |
| SRC_ZEILE | X | MBLPO | Source GR item |
| AUFNR | | AUFNR | Production order |
| MATNR | | MATNR | Header material |
| MENGE | | MENGE_D | Transferred qty |
| MEINS | | MEINS | Unit |
| CHARG | | CHARG_D | Batch |
| BWTAR | | BWTAR_D | Destination valuation type used |
| RSNUM | | RSNUM | Reservation |
| RSPOS | | RSPOS | Reservation item |
| MOV_MBLNR | | MBLNR | Created 301 material document |
| MOV_MJAHR | | MJAHR | Created 301 document year |
| STATUS | | CHAR1 | S=success / E=error / R=reversed / W=warning |
| RUN_ID | | SYSUUID_C32 | Repost/catch-up run (FK → ZPTP_301_MOVRLOG) |
| MESSAGE | | STRING | Message |
| ERDAT | | ERDAT | Created on |
| ERZET | | ERZET | Created at |
| ERNAM | | ERNAM | Created by |

Recommended secondary index on `ZPTP_301_MOV_LOG`: `AUFNR`, `STATUS` (monitor selections).

---

## 5. Application-log objects (SLG0) — optional

Not called by the current code (no `BAL_*` calls yet).

| Object | Subobject | Used by |
|---|---|---|
| ZPTP | Z301RES | Reservation report background runs |
| ZPTP | Z301MOV | GR-triggered posting + monitor/repost |

---

## 6. Other repository objects

| Object | Type | Notes |
|---|---|---|
| `ZPTP_301_TRANSFER` | Function group | Holds `Z_PTP_301_TRANSFER_POST` (remote-enabled) |
| `ZPTP_301_RESERVATION_GENERATOR` | Report | Tcode `ZPTP_301_RES` |
| `ZPTP_301_MOVEMENT_MONITOR` | Report | Tcode `ZPTP_301_MON` |
| `ZMB_DOC_301_TRANSFER` | BAdI implementation (SE19) of `MB_DOCUMENT_BADI` | Class `ZCL_IM_MB_DOC_301_TRANSFER` |
| `ZCE_MB_DOCUMENT_BADI_301` | Enhancement class | Logic called by the BAdI class |
