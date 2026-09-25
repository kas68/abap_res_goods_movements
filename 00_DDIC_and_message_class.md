# DDIC objects & message class — 301 migration transfer solution

> On-premise S/4HANA. Create these in SE11 / ADT before activating the programs.
> Data types below use standard data elements where they exist; `ZDE_*` are new data
> elements to create (all trivial single-domain wrappers). Field lengths follow standard MM.

---

## 1. Message class `ZMM301` (SE91)

| No. | Message text (placeholders &1..&4) |
|---|---|
| 000 | & & & & |
| 001 | Origin plant &1 and destination plant &2 must be different |
| 002 | No open production orders found for the selection |
| 003 | Material &1 not maintained in destination plant &2 |
| 004 | Order &1: fully received – skipped |
| 005 | Order &1: reservation &2 created |
| 006 | Order &1: reservation &2 realigned to qty &3 |
| 007 | Order &1: reservation &2 closed |
| 008 | Order &1: reservation &2 already aligned |
| 009 | Order &1: BAPI error – &2 |
| 010 | Frequency must be at least 1 minute |
| 011 | Frequency exceeds the configured maximum |
| 012 | Self-reschedule chain stopped (control flag inactive) |
| 013 | Next run scheduled at &1 &2 |
| 014 | Plant &1 does not exist |
| 015 | Storage location &1 does not exist for plant &2 |
| 016 | RM plants required and must differ (source &1 / target &2) |
| 017 | Order &1 component &2: 301 RM reservation &3 created (shortage &4) |
| 018 | No authorization for movement 301 in plant &1 |
| 020 | GR &1/&2 item &3: 301 transfer &4 posted |
| 021 | GR &1/&2 item &3: transfer already posted – skipped |
| 022 | GR &1/&2 item &3: no valuation type for fiscal year &4 |
| 023 | GR &1/&2 item &3: no reservation found for order &4 |
| 024 | GR &1/&2 item &3: 301 posting error – &4 |
| 025 | GR &1/&2 item &3: reversal 302 posted |
| 026 | Automation inactive for plant pair &1 / &2 |

---

## 2. Tables (SE11 – transparent tables)

Notes: all tables are client-dependent (`MANDT` first key). Delivery class `A`
(application table), maintenance allowed via SM30 where a maintenance view is noted.

### 2.1 `ZMM_301_RESV_LOG` — per-order reservation detail log (FS-MM-301RES-001)

| Field | Key | Data element / type | Description |
|---|:---:|---|---|
| MANDT | X | MANDT | Client |
| AUFNR | X | AUFNR | Production order |
| RES_KIND | X | CHAR1 | H = header material (8P01→8Q01) / R = raw-material component (8Q01→8P01) |
| POSNR | X | CO_POSNR | Header item (0001) or component item (RESB-RSPOS) |
| RUN_ID | X | SYSUUID_C32 (CHAR32) | Run identifier (FK → ZMM_301_RUN_LOG) |
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

### 2.2 `ZMM_301_RUN_LOG` — execution log (FS-MM-301RES-001)

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

### 2.3 `ZMM_301_CTRL` — control/config (FS-MM-301MOV-001) — SM30 maintenance view `ZMM_301_CTRL_V`

| Field | Key | Data element / type | Description |
|---|:---:|---|---|
| MANDT | X | MANDT | Client |
| WERKS_FR | X | WERKS_D | Origin plant |
| WERKS_TO | X | WERKS_D | Destination plant |
| LGORT_FR | | LGORT_D | Default origin storage location |
| LGORT_TO | | LGORT_D | Destination storage location |
| MOVE_TYPE | | BWART | Transfer movement type (default 301) |
| NO_RESV_ACTION | | CHAR1 | P=post w/o ref / S=skip when no reservation |
| ACTIVE | | CHAR1 | Automation on/off |
| VALID_FROM | | DATUM | Activation window start |
| VALID_TO | | DATUM | Activation window end |

### 2.4 `ZMM_301_MOV_LOG` — per-GR movement log (FS-MM-301MOV-001)

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
| BWTAR | | BWTAR | Destination valuation type used |
| RSNUM | | RSNUM | Reservation |
| RSPOS | | RSPOS | Reservation item |
| MOV_MBLNR | | MBLNR | Created 301 material document |
| MOV_MJAHR | | MJAHR | Created 301 document year |
| STATUS | | CHAR1 | S=success / E=error / R=reversed / W=warning |
| RUN_ID | | SYSUUID_C32 | Repost/catch-up run (FK → ZMM_301_MOV_RUN_LOG) |
| MESSAGE | | STRING | Message |
| ERDAT | | ERDAT | Created on |
| ERZET | | ERZET | Created at |
| ERNAM | | ERNAM | Created by |

### 2.5 `ZMM_301_MOV_RUN_LOG` — monitor/repost execution log (FS-MM-301MOV-001)

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

### 2.6 `ZMM_301_VALTYPE` — fiscal-year → destination valuation type (FS-MM-301MOV-001) — SM30 view `ZMM_301_VALTYPE_V`

| Field | Key | Data element / type | Description |
|---|:---:|---|---|
| MANDT | X | MANDT | Client |
| BUKRS | X | BUKRS | Company code (may be blank = global) |
| GJAHR | X | GJAHR | Fiscal year |
| BWTAR | | BWTAR | Destination valuation type for that fiscal year |
| DESCR | | TEXT40 | Description |
| ACTIVE | | CHAR1 | Entry active |

---

## 3. Application-log objects (SLG0)

| Object | Subobject | Used by |
|---|---|---|
| ZMM | Z301RES | Reservation report background runs |
| ZMM | Z301MOV | GR-triggered posting + monitor/repost |

---

## 4. Transactions (SE93)

| Tcode | Program | Description |
|---|---|---|
| ZMM301R | ZMM_R_CREATE_301_RESERV | Create/align 301 reservations |
| ZMM301M | ZMM_R_301_MOV_MONITOR | 301 transfer monitor / repost |

> Package: `Z_MM_INVENTORY`. All objects assigned to the same transport.
