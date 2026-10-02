# Implementation Guide — 301 Migration Transfer (8P01 → 8Q01)

Step-by-step build of all objects, with every description, label and text to enter in the system.
Object names follow the *SAP ABAP Development Standard and Naming Conventions* (workstream **PTP**).

| Item | Value |
|---|---|
| Package | `ZPTP_301_MIGRATION` |
| Message class | `ZPTP_SPLIT_VAL` (existing), messages 027–051 |
| Original language | EN (translate labels and texts in SE63 if users log on in another language) |
| Transport requests | 1 workbench request (all objects) + 1 customizing request (content of the 2 configuration tables) |

## Sequence

| Step | Content | Transaction | Depends on |
|---|---|---|---|
| 0 | Package, transport requests, authorization group | SE21 / SE09 / SM30 | – |
| 1 | Messages 027–051 | SE91 | 0 |
| 2 | Domains and data elements | SE11 | 0 |
| 3 | Configuration tables + table maintenance | SE11 | 2 |
| 4 | Log tables | SE11 | 2 |
| 5 | Function group + function module | SE37 | 1, 3, 4 |
| 6 | Reservation report + transaction | SE38 / SE93 | 1, 3, 4 |
| 7 | Monitor report + transaction | SE38 / SE93 | 1, 3, 4, 5 |
| 8 | Enhancement class + BAdI implementation | SE24 / SE19 | 3, 5 |
| 9 | Authorizations | PFCG | 6, 7 |
| 10 | Configuration data | SM30 | 3 |
| 11 | Testing | – | all |
| 12 | Transport and go-live | STMS / SM36 / SM30 | 11 |

The BAdI is created last because it runs on every goods movement. It stays inert until
`ZPTP_301_CTRL-ACTIVE` is set in step 12.

---

## Step 0 — Prerequisites

### 0.1 Package (SE21)

| Field | Value |
|---|---|
| Package | `ZPTP_301_MIGRATION` |
| Short description | PTP – 301 migration transfer 8P01 to 8Q01 |
| Application component | MM-IM |
| Software component | HOME |
| Package type | Standard package |

### 0.2 Transport requests (SE09)

Name both requests according to the TR convention: `<Work Item ID> : <WRICEF ID> <description>`.

| Request | Type | Description (after the work-item prefix) |
|---|---|---|
| 1 | Workbench | 301 migration – repository and DDIC objects |
| 2 | Customizing | 301 migration – configuration ZPTP_301_CTRL / ZPTP_301_VALTYPE |

### 0.3 Authorization group (SM30, view `V_BRG_54`)

Skip if `ZPTP` already exists.

| Field | Value |
|---|---|
| Authorization group | `ZPTP` |
| Short text | PTP – Z configuration tables |

### 0.4 Standard configuration checks

- Plants 8P01 and 8Q01 and their storage locations exist, in the same company code.
- Materials are extended to 8Q01 with the required valuation types.
- Movement type 301 allows reservations (OMJJ).

---

## Step 1 — Messages (SE91, class `ZPTP_SPLIT_VAL`)

1. Open the class in change mode and check that numbers 027–051 are free.
2. Enter the texts below and tick **Self-explanatory** on each.
3. Save to request 1.

| No. | Message text |
|---|---|
| 027 | Origin plant &1 and destination plant &2 must be different |
| 028 | No open production orders found for the selection |
| 029 | Material &1 not maintained in destination plant &2 |
| 030 | Order &1: fully received – skipped |
| 031 | Order &1: reservation &2 created |
| 032 | Order &1: reservation &2 realigned to qty &3 |
| 033 | Order &1: reservation &2 closed |
| 034 | Order &1: reservation &2 already aligned |
| 035 | Order &1: BAPI error – &2 |
| 036 | Frequency must be at least 1 minute |
| 037 | Frequency exceeds the configured maximum |
| 038 | Self-reschedule chain stopped (control flag inactive) |
| 039 | Next run scheduled at &1 &2 |
| 040 | Plant &1 does not exist |
| 041 | Storage location &1 does not exist for plant &2 |
| 042 | RM plants required and must differ (source &1 / target &2) |
| 043 | Order &1 component &2: 301 RM reservation &3 created (shortage &4) |
| 044 | No authorization for movement 301 in plant &1 |
| 045 | GR &1/&2 item &3: 301 transfer &4 posted |
| 046 | GR &1/&2 item &3: transfer already posted – skipped |
| 047 | GR &1/&2 item &3: no valuation type for fiscal year &4 |
| 048 | GR &1/&2 item &3: no reservation found for order &4 |
| 049 | GR &1/&2 item &3: 301 posting error – &4 |
| 050 | GR &1/&2 item &3: reversal 302 posted |
| 051 | Automation inactive for plant pair &1 / &2 |

Messages 027, 028, 036–042 and 044 are used by the current code; the others are reserved for the
functional specifications.

---

## Step 2 — Domains and data elements (SE11)

For each pair, create and activate the domain first, then the data element.

### 2.1 Domains

All domains: Data type **CHAR**, No. of characters **1**, Output length 1, no conversion routine,
not case-sensitive.

| Domain | Short description |
|---|---|
| `ZPTP301_NORES_ACT` | 301 migration: action when no reservation found |
| `ZPTP301_RES_KIND` | 301 migration: reservation kind |
| `ZPTP301_RES_STAT` | 301 migration: reservation processing status |
| `ZPTP301_MOV_STAT` | 301 migration: transfer posting status |

Fixed values (tab **Value Range**):

| Domain | Value | Short text |
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

### 2.2 Data elements

Tab **Data Type**: Elementary type, Domain as below. Tab **Field Label**: lengths 10 / 20 / 40 / 20.

| Data element | Domain | Short description | Short | Medium | Long | Heading |
|---|---|---|---|---|---|---|
| `ZDEPTP301_NORES_ACT` | `ZPTP301_NORES_ACT` | 301 migration: action when no reservation found | No resv. | No-resv. action | Action when no reservation found | No-resv. action |
| `ZDEPTP301_RES_KIND` | `ZPTP301_RES_KIND` | 301 migration: reservation kind | Res. kind | Reservation kind | Reservation kind (FP / raw material) | Kind |
| `ZDEPTP301_RES_STAT` | `ZPTP301_RES_STAT` | 301 migration: reservation processing status | Res.status | Reservation status | Reservation processing status | Status |
| `ZDEPTP301_MOV_STAT` | `ZPTP301_MOV_STAT` | 301 migration: transfer posting status | Trf.status | Transfer status | 301 transfer posting status | Status |

---

## Step 3 — Configuration tables (SE11)

### 3.1 Common settings

| Where | Setting | Value |
|---|---|---|
| Tab Delivery and Maintenance | Delivery class | **C** |
| | Data Browser/Table View Maint. | Display/Maintenance Allowed |
| Goto → Technical Settings | Data class | APPL2 |
| | Size category | 0 |
| | Buffering | Buffering switched on — **Fully buffered** |
| | Log data changes | ✔ |
| | DB-specific properties → Storage type | Column Store |
| Extras → Enhancement Category | | Can be enhanced (character-type or numeric) |

Key fields first, with **Key** and **Initial Values** ticked. Save, set technical settings,
enhancement category and foreign keys, then activate.

### 3.2 `ZPTP_301_CTRL`

Short description: **301 migration: plant pair configuration**

| Field | Key | Data element | Label shown (from data element) | Check table |
|---|:---:|---|---|---|
| MANDT | ✔ | MANDT | Client | T000 |
| WERKS_FR | ✔ | WERKS_D | Plant | T001W |
| WERKS_TO | ✔ | WERKS_D | Plant | T001W |
| LGORT_FR | | LGORT_D | Storage location | T001L |
| LGORT_TO | | LGORT_D | Storage location | T001L |
| MOVE_TYPE | | BWART | Movement type | T156 |
| NO_RESV_ACTION | | ZDEPTP301_NORES_ACT | Action when no reservation found | fixed values |
| ACTIVE | | XFELD | Checkbox | – |
| VALID_FROM | | DATAB | Valid from | – |
| VALID_TO | | DATBI | Valid to | – |

Meaning of the fields (for the functional documentation and SM30 users):

| Field | Meaning |
|---|---|
| WERKS_FR | Origin plant (8P01) |
| WERKS_TO | Destination plant (8Q01) |
| LGORT_FR | Default origin storage location |
| LGORT_TO | Destination storage location |
| MOVE_TYPE | Transfer movement type (blank = 301) |
| NO_RESV_ACTION | P = post without reservation / S = skip and log a warning |
| ACTIVE | Automation on/off; stop switch for the BAdI and the job chains |
| VALID_FROM / VALID_TO | Activation window, compared with the GR posting date |

Foreign keys (cardinality 1 : CN, type *Key fields/candidates*). Correct the proposed mapping where
bold:

| Field | Check table | Field mapping (check table → ZPTP_301_CTRL) |
|---|---|---|
| WERKS_FR | T001W | MANDT → MANDT, WERKS → **WERKS_FR** |
| WERKS_TO | T001W | MANDT → MANDT, WERKS → **WERKS_TO** |
| LGORT_FR | T001L | MANDT → MANDT, WERKS → **WERKS_FR**, LGORT → LGORT_FR |
| LGORT_TO | T001L | MANDT → MANDT, WERKS → **WERKS_TO**, LGORT → LGORT_TO |
| MOVE_TYPE | T156 | MANDT → MANDT, BWART → MOVE_TYPE |

### 3.3 `ZPTP_301_VALTYPE`

Short description: **301 migration: fiscal year to valuation type**

| Field | Key | Data element | Label shown | Check table |
|---|:---:|---|---|---|
| MANDT | ✔ | MANDT | Client | T000 |
| BUKRS | ✔ | BUKRS | Company code | T001 |
| GJAHR | ✔ | GJAHR | Fiscal year | – |
| BWTAR | | BWTAR_D | Valuation type | T149D |
| DESCR | | TEXT40 | Description | – |
| ACTIVE | | XFELD | Checkbox | – |

| Field | Meaning |
|---|---|
| BUKRS | Company code; blank = valid for all company codes (a specific entry wins) |
| GJAHR | Fiscal year of the GR posting date |
| BWTAR | Destination valuation type used on the 301 for that fiscal year |
| DESCR | Free comment (not translated) |
| ACTIVE | Entry active |

Foreign keys: BUKRS → T001 (MANDT, BUKRS); BWTAR → T149D (MANDT, BWTAR).

### 3.4 Table Maintenance Generator (Utilities → Table Maintenance Generator)

| Field | `ZPTP_301_CTRL` | `ZPTP_301_VALTYPE` |
|---|---|---|
| Authorization group | ZPTP | ZPTP |
| Authorization object | S_TABU_DIS | S_TABU_DIS |
| Function group | ZPTP_301_CTRL | ZPTP_301_VALTYPE |
| Function group short text (prompted) | 301 migration: maint. plant pair config. | 301 migration: maint. FY valuation type |
| Package | ZPTP_301_MIGRATION | ZPTP_301_MIGRATION |
| Maintenance type | One step | One step |
| Overview screen | 1 | 1 |
| Recording routine | Standard recording routine | Standard recording routine |

Test in SM30: F4 works on plants, storage locations and NO_RESV_ACTION; saving asks for a
**customizing** request.

---

## Step 4 — Log tables (SE11)

### 4.1 Common settings

| Setting | Value |
|---|---|
| Delivery class | **A** |
| Data Browser/Table View Maint. | Display/Maintenance Allowed with Restrictions |
| Data class | APPL1 |
| Size category | 0 for the two run logs, 2 for `ZPTP_301_RES_LOG` and `ZPTP_301_MOV_LOG` |
| Buffering | Buffering not allowed |
| Log data changes | not set |
| Storage type | Column Store |
| Enhancement category | Can be enhanced (character-type or numeric) |

Fields marked *predefined* use the **Predefined Type** button: enter the type, length and the short
description given. Quantity fields need a reference to the unit field (tab **Currency/Quantity
Fields**, reference table = the table itself, reference field = `MEINS`).

A purge rule for the log tables must be agreed (standard, *Z/Y table creation*).

### 4.2 `ZPTP_301_RUN_LOG`

Short description: **301 migration: reservation report run log**

| Field | Key | Data element / predefined type | Short description |
|---|:---:|---|---|
| MANDT | ✔ | MANDT | Client |
| RUN_ID | ✔ | SYSUUID_C32 | Run identifier |
| RUN_MODE | | predefined CHAR 1 | Run mode (O = online, B = background) |
| JOBNAME | | BTCJOB | Background job name |
| JOBCOUNT | | BTCJOBCNT | Background job number |
| VARIANT | | RALDB_VARI | Report variant |
| WERKS_FR | | WERKS_D | Origin plant |
| WERKS_TO | | WERKS_D | Destination plant |
| SEL_TEXT | | predefined STRING | Selection snapshot |
| TEST_RUN | | XFELD | Test run (simulation) |
| SELF_SCHED | | XFELD | Self-rescheduling active |
| FREQ_VALUE | | INT4 | Frequency value |
| FREQ_UNIT | | predefined CHAR 3 | Frequency unit (MIN / HRS / DAY) |
| NEXT_RUN_DT | | DATUM | Next run date |
| NEXT_RUN_TM | | UZEIT | Next run time |
| START_DATE | | DATUM | Start date |
| START_TIME | | UZEIT | Start time |
| END_DATE | | DATUM | End date |
| END_TIME | | UZEIT | End time |
| DURATION_S | | INT4 | Duration in seconds |
| CNT_SELECTED | | INT4 | Orders selected |
| CNT_CREATED | | INT4 | Reservations created |
| CNT_REALIGNED | | INT4 | Reservations realigned |
| CNT_CLOSED | | INT4 | Reservations closed |
| CNT_UNCHANGED | | INT4 | Reservations unchanged |
| CNT_SKIPPED | | INT4 | Orders skipped |
| CNT_DRIFT | | INT4 | GR received but not yet transferred |
| CNT_ERROR | | INT4 | Errors |
| STATUS | | predefined CHAR 1 | Run status (R running, S success, W warning, A aborted) |
| BALLOGNR | | BALOGNR | Application log number |
| ERNAM | | ERNAM | Executed by |
| MESSAGE | | predefined STRING | Summary / abort reason |

### 4.3 `ZPTP_301_RES_LOG`

Short description: **301 migration: order-to-reservation log**

`RES_KIND` must be part of the key; otherwise finished-product and raw-material rows overwrite
each other. This table is the primary order ↔ reservation link (the second link is `RESB-WEMPF`).

| Field | Key | Data element / predefined type | Short description |
|---|:---:|---|---|
| MANDT | ✔ | MANDT | Client |
| AUFNR | ✔ | AUFNR | Production order |
| RES_KIND | ✔ | ZDEPTP301_RES_KIND | Reservation kind (H / R) |
| POSNR | ✔ | CO_POSNR | 0001 (finished product) or component item RESB-RSPOS |
| RUN_ID | ✔ | SYSUUID_C32 | Run identifier |
| RSNUM | | RSNUM | Reservation number |
| RSPOS | | RSPOS | Reservation item |
| WERKS_FR | | WERKS_D | Issuing plant (H: 8P01 / R: 8Q01) |
| WERKS_TO | | WERKS_D | Receiving plant (H: 8Q01 / R: 8P01) |
| MATNR | | MATNR | Finished product (H) or component (R) |
| PO_OPEN | | MENGE_D | Basis qty: order open qty (H) or shortage (R) — ref. MEINS |
| RES_BDMNG | | MENGE_D | Reservation requirement qty — ref. MEINS |
| RES_ENMNG | | MENGE_D | Reservation withdrawn qty — ref. MEINS |
| MEINS | | MEINS | Base unit of measure |
| STATUS | | ZDEPTP301_RES_STAT | Reservation processing status |
| MESSAGE | | predefined STRING | Message text |
| ERDAT | | ERDAT | Created on |
| ERZET | | ERZET | Created at |
| ERNAM | | ERNAM | Created by |

### 4.4 `ZPTP_301_MOVRLOG`

Short description: **301 migration: monitor run log**

| Field | Key | Data element / predefined type | Short description |
|---|:---:|---|---|
| MANDT | ✔ | MANDT | Client |
| RUN_ID | ✔ | SYSUUID_C32 | Run identifier |
| RUN_TYPE | | predefined CHAR 1 | Run type (M monitor, P repost, C catch-up) |
| RUN_MODE | | predefined CHAR 1 | Run mode (O = online, B = background) |
| JOBNAME | | BTCJOB | Background job name |
| JOBCOUNT | | BTCJOBCNT | Background job number |
| START_DATE | | DATUM | Start date |
| START_TIME | | UZEIT | Start time |
| END_DATE | | DATUM | End date |
| END_TIME | | UZEIT | End time |
| DURATION_S | | INT4 | Duration in seconds |
| CNT_SCANNED | | INT4 | Goods receipts examined |
| CNT_POSTED | | INT4 | 301 transfers posted |
| CNT_REVERSED | | INT4 | 302 reversals posted |
| CNT_SKIPPED | | INT4 | Already transferred (skipped) |
| CNT_WARNING | | INT4 | Warnings |
| CNT_ERROR | | INT4 | Errors |
| STATUS | | predefined CHAR 1 | Run status (R running, S success, W warning, A aborted) |
| BALLOGNR | | BALOGNR | Application log number |
| ERNAM | | ERNAM | Executed by |
| MESSAGE | | predefined STRING | Summary |

### 4.5 `ZPTP_301_MOV_LOG`

Short description: **301 migration: GR transfer posting log**

The key (source GR document and item) guarantees that a goods receipt is never transferred twice.

| Field | Key | Data element / predefined type | Short description |
|---|:---:|---|---|
| MANDT | ✔ | MANDT | Client |
| SRC_MBLNR | ✔ | MBLNR | Source GR material document |
| SRC_MJAHR | ✔ | MJAHR | Source GR document year |
| SRC_ZEILE | ✔ | MBLPO | Source GR item |
| AUFNR | | AUFNR | Production order |
| MATNR | | MATNR | Finished product |
| MENGE | | MENGE_D | Transferred quantity — ref. MEINS |
| MEINS | | MEINS | Base unit of measure |
| CHARG | | CHARG_D | Batch |
| BWTAR | | BWTAR_D | Destination valuation type used |
| RSNUM | | RSNUM | Reservation number |
| RSPOS | | RSPOS | Reservation item |
| MOV_MBLNR | | MBLNR | 301 material document created |
| MOV_MJAHR | | MJAHR | 301 document year |
| STATUS | | ZDEPTP301_MOV_STAT | Transfer posting status |
| RUN_ID | | 2 | Repost / catch-up run identifier |
| MESSAGE | | predefined STRING | Message text |
| ERDAT | | ERDAT | Created on |
| ERZET | | ERZET | Created at |
| ERNAM | | ERNAM | Created by |

Secondary index (Goto → Indexes → Create):

| Index | Short description | Fields | Unique |
|---|---|---|---|
| `Z01` | Order and status (monitor selection) | MANDT, AUFNR, STATUS | No |

---

## Step 5 — Function group and function module (SE37 / SE80)

### 5.1 Function group

| Field | Value |
|---|---|
| Function group | `ZPTP_301_TRANSFER` |
| Short text | 301 migration: transfer posting |
| Package | ZPTP_301_MIGRATION |

### 5.2 Function module `Z_PTP_301_TRANSFER_POST`

| Tab / field | Value |
|---|---|
| Short text | 301 migration: post/reverse 301 for one goods receipt item |
| Function group | ZPTP_301_TRANSFER |
| Attributes → Processing type | **Remote-Enabled Module** (required for IN BACKGROUND TASK) |

Import parameters (all **Pass Value** ✔):

| Parameter | Typing | Associated type | Default | Optional | Short text |
|---|---|---|---|:---:|---|
| IV_MBLNR | TYPE | MBLNR | | | Source GR material document |
| IV_MJAHR | TYPE | MJAHR | | | Source GR document year |
| IV_ZEILE | TYPE | MBLPO | | | Source GR item |
| IV_REVERSAL | TYPE | ABAP_BOOL | SPACE | ✔ | X = GR reversed, cancel the 301 |
| IV_RUN_ID | TYPE | SYSUUID_C32 | | ✔ | Repost / catch-up run identifier |
| IV_COMMIT | TYPE | ABAP_BOOL | SPACE | ✔ | X = synchronous caller, FM commits |

No export, changing, table parameters or exceptions. Paste `Z_PTP_301_TRANSFER_POST.abap` and
activate.

---

## Step 6 — Reservation report

### 6.1 Program attributes (SE38)

| Field | Value |
|---|---|
| Program | `ZPTP_301_RESERVATION_GENERATOR` |
| Title | 301 migration: create and align transfer reservations |
| Type | Executable program |
| Status | Customer production program |
| Application | Materials Management |
| Unicode checks active / Fixed point arithmetic | ✔ / ✔ |

Paste `ZPTP_301_RESERVATION_GENERATOR.abap`.

### 6.2 Text symbols (Goto → Text Elements → Text Symbols)

| Sym | Text | Max. length |
|---|---|---|
| 001 | Plants and storage locations | 40 |
| 002 | Order selection | 40 |
| 003 | Run control | 40 |
| 004 | Scheduling | 40 |
| 005 | Raw materials (8Q01 -> 8P01) | 40 |
| L01 | Minutes | 20 |
| L02 | Hours | 20 |
| L03 | Days | 20 |

### 6.3 Selection texts (Goto → Text Elements → Selection Texts)

Do not tick *Dictionary Ref.*; enter the text.

| Name | Text |
|---|---|
| P_WERKFR | Origin plant |
| P_LGORFR | Origin storage location |
| P_WERKTO | Destination plant |
| P_LGORTO | Destination storage location |
| SO_AUFNR | Production order |
| SO_AUART | Order type |
| SO_MATNR | Material |
| SO_DISPO | MRP controller |
| P_RSDAT | Reservation requirement date |
| P_MOVE | Movement allowed |
| P_TEST | Test run (simulation) |
| P_ERRON | Reprocess errors only |
| P_SCHED | Self-reschedule |
| P_FREQ | Frequency |
| P_FUNIT | Frequency unit |
| P_RAWMAT | Also reserve raw materials |
| P_WERKRF | RM issuing plant |
| P_LGORRF | RM issuing storage location |
| P_WERKRT | RM receiving plant |
| P_LGORRT | RM receiving storage location |

Activate the program and the text elements.

### 6.4 Transaction (SE93)

| Field | Value |
|---|---|
| Transaction code | `ZPTP_301_RES` |
| Short text | 301 Migr.: Create/Align Reservations |
| Start object | Program and selection screen (report transaction) |
| Program / Selection screen | ZPTP_301_RESERVATION_GENERATOR / 1000 |
| GUI support | SAP GUI for HTML, Java and Windows ✔ |

---

## Step 7 — Monitor report

### 7.1 Program attributes (SE38)

| Field | Value |
|---|---|
| Program | `ZPTP_301_MOVEMENT_MONITOR` |
| Title | 301 migration: transfer monitor, repost and catch-up |
| Type / Status / Application | Executable program / Customer production program / Materials Management |

Paste `ZPTP_301_MOVEMENT_MONITOR.abap`.

### 7.2 Text symbols

| Sym | Text | Max. length |
|---|---|---|
| 001 | Selection | 40 |
| 002 | Processing mode | 40 |
| 003 | Scheduling (catch-up) | 40 |
| M01 | Monitor | 20 |
| M02 | Repost errors | 20 |
| M03 | Catch-up scan | 20 |
| L01 | Minutes | 20 |
| L02 | Hours | 20 |
| L03 | Days | 20 |

### 7.3 Selection texts

| Name | Text |
|---|---|
| P_WERKFR | Origin plant |
| SO_BUDAT | Posting date |
| SO_AUFNR | Production order |
| P_MODE | Processing mode |
| P_SCHED | Self-reschedule (catch-up) |
| P_FREQ | Frequency |
| P_FUNIT | Frequency unit |

### 7.4 Transaction (SE93)

| Field | Value |
|---|---|
| Transaction code | `ZPTP_301_MON` |
| Short text | 301 Migr.: Transfer Monitor |
| Start object | Program and selection screen (report transaction) |
| Program / Selection screen | ZPTP_301_MOVEMENT_MONITOR / 1000 |

---

## Step 8 — Enhancement class and BAdI implementation

Detailed build, test and operations steps: [BADI_IMPLEMENTATION_GUIDE.md](BADI_IMPLEMENTATION_GUIDE.md).

### 8.1 Check existing implementations (SE18)

BAdI `MB_DOCUMENT_BADI` → Implementation → Overview. Note any active implementation that also
reacts to production-order goods receipts.

### 8.2 Enhancement class (SE24)

| Field | Value |
|---|---|
| Class | `ZCE_MB_DOCUMENT_BADI_301` |
| Description | MB_DOCUMENT_BADI: GR-triggered 301 migration transfer |
| Instantiation / Final | Public / ✔ |
| Package | ZPTP_301_MIGRATION |

| Method | Visibility | Description |
|---|---|---|
| BEFORE_UPDATE | Public | Enqueue the 301 transfer for relevant GR items |
| GET_CONTROL | Private | Read the active control entry of the origin plant |
| IS_HEADER_MATERIAL | Private | Check that the material is the order's finished product |

| Parameter | Method | Type | Description |
|---|---|---|---|
| IT_MKPF | BEFORE_UPDATE | Importing TY_T_MKPF | Material document headers |
| IT_MSEG | BEFORE_UPDATE | Importing TY_T_MSEG | Material document items |
| IV_WERKS | GET_CONTROL | Importing WERKS_D | Origin plant |
| ES_CTRL | GET_CONTROL | Exporting ZPTP_301_CTRL | Control entry |
| RV_ACTIVE | GET_CONTROL | Returning ABAP_BOOL | Control entry active |
| IV_AUFNR | IS_HEADER_MATERIAL | Importing AUFNR | Production order |
| IV_MATNR | IS_HEADER_MATERIAL | Importing MATNR | Material |
| RV_HEADER | IS_HEADER_MATERIAL | Returning ABAP_BOOL | Material is the finished product |

| Constant | Value | Description |
|---|---|---|
| GC_GR_101 | '101' | Goods receipt for production order |
| GC_REV_102 | '102' | Reversal of goods receipt |

Paste `ZCE_MB_DOCUMENT_BADI_301.abap` (source-code based editor) and activate. On the first syntax
check, confirm that `TY_T_MKPF` / `TY_T_MSEG` match the interface parameters `XMKPF` / `XMSEG` of
`IF_EX_MB_DOCUMENT_BADI` in your release.

### 8.3 BAdI implementation (SE19, classic BAdI)

| Field | Value |
|---|---|
| BAdI name | MB_DOCUMENT_BADI |
| Implementation name | `ZMB_DOC_301_TRANSFER` |
| Implementation short text | 301 migration: GR-triggered transfer 8P01 -> 8Q01 |
| Implementing class | `ZCL_IM_MB_DOC_301_TRANSFER` (overwrite the proposed name if different) |
| Class description | BAdI impl. ZMB_DOC_301_TRANSFER (MB_DOCUMENT_BADI) |
| Package | ZPTP_301_MIGRATION |

| Method | Description |
|---|---|
| IF_EX_MB_DOCUMENT_BADI~MB_DOCUMENT_BEFORE_UPDATE | Calls ZCE_MB_DOCUMENT_BADI_301->BEFORE_UPDATE |
| IF_EX_MB_DOCUMENT_BADI~MB_DOCUMENT_UPDATE | Not used (empty) |

Paste `ZCL_IM_MB_DOC_301_TRANSFER.abap`, activate the class, then **activate the implementation**.

---

## Step 9 — Authorizations (PFCG)

Role names follow your security naming convention.

| Role (description) | Object | Values |
|---|---|---|
| 301 migration – key user | S_TCODE | ZPTP_301_RES, ZPTP_301_MON |
| | M_MSEG_WMB | ACTVT 01; BWART 301, 302; WERKS 8P01, 8Q01 |
| | S_TABU_DIS | ACTVT 02, 03; DICBERCLS ZPTP |
| 301 migration – batch user | M_MSEG_WMB | as above |
| | S_BTCH_JOB | JOBACTION RELE; JOBGROUP * |
| GR posters (production roles) | M_MSEG_WMB | ACTVT 01; BWART 301, 302; WERKS 8P01, 8Q01 |

GR posters need the 301 authorization because the BAdI-triggered transfer runs in tRFC under the
user who posted the goods receipt.

---

## Step 10 — Configuration data (SM30, customizing request)

### `ZPTP_301_CTRL`

| Field | Value |
|---|---|
| WERKS_FR / WERKS_TO | 8P01 / 8Q01 |
| LGORT_FR / LGORT_TO | origin / destination storage locations |
| MOVE_TYPE | 301 |
| NO_RESV_ACTION | P or S (business decision) |
| ACTIVE | **blank** (set only at go-live, never transported as X) |
| VALID_FROM / VALID_TO | migration window, if required |

### `ZPTP_301_VALTYPE`

One row per fiscal year of the migration, plus the next fiscal year:

| BUKRS | GJAHR | BWTAR | DESCR | ACTIVE |
|---|---|---|---|---|
| company code or blank | e.g. 2026 | valuation type | 301 migration FY2026 | X |
| company code or blank | e.g. 2027 | valuation type | 301 migration FY2027 | X |

---

## Step 11 — Testing (in this order)

| # | Test | Expected result |
|---|---|---|
| 1 | `ZPTP_301_RES` with *Test run* on one released order | ALV status S (simulated), no reservation |
| 2 | Same order, live | Reservation in MB25 8P01 → 8Q01, goods recipient = order number, H row in `ZPTP_301_RES_LOG` |
| 3 | *Also reserve raw materials* on an open, unreleased order with a component short in 8P01 | One separate reservation 8Q01 → 8P01 with one item per short component; no finished-product reservation |
| 4 | Change order quantity, rerun | Status R (realigned) |
| 5 | `ACTIVE = X` in the test system, post GR 101 | 301 posted against the reservation, ENMNG updated, status S in `ZPTP_301_MOV_LOG` |
| 6 | Reverse the GR (102) | 302 posted, status R |
| 7 | Remove the `ZPTP_301_VALTYPE` entry, post a GR | GR posted, transfer status E; after restoring the entry, `ZPTP_301_MON` mode *Repost errors* posts it |
| 8 | `ZPTP_301_MON` mode *Catch-up scan* over a GR without transfer | Missing 301 posted |
| 9 | Delete an order's `ZPTP_301_RES_LOG` row, rerun the report | Reservation found via goods recipient, log row rewritten, no duplicate |
| 10 | Set the order to TECO, rerun | Reservation closed (status X) |

---

## Step 12 — Transport and go-live

1. SE09: *Check objects* on request 1 (all active; `R3TR SXCI ZMB_DOC_301_TRANSFER` included),
   release the tasks, then the requests.
2. STMS: import **request 1 (workbench) before request 2 (customizing)**. Return code 0 or 4 is
   fine; 8 or higher must be analysed.
3. Production: check `ZPTP_301_VALTYPE`; check `ZPTP_301_CTRL` with `ACTIVE` blank.
4. Run `ZPTP_301_RES` in test mode over the full scope, review, then run it live.
5. Set **`ACTIVE = X`** in `ZPTP_301_CTRL`: goods receipts now trigger the 301.
6. Schedule the jobs:

   | Job | Program | Mode | Suggested variant (description) |
   |---|---|---|---|
   | ZPTP_301_RES_CHAIN | ZPTP_301_RESERVATION_GENERATOR | Self-reschedule or SM36 periodic | 301 migration – live, 8P01 to 8Q01 |
   | ZPTP_301_MON_CHAIN | ZPTP_301_MOVEMENT_MONITOR | Catch-up (C) | 301 migration – catch-up scan |

7. End of migration: set `ACTIVE` blank (also stops the job chains), close the remaining
   reservations, keep the logs according to the retention rule.

---

## Optional — Application log (SLG0)

Not called by the current code.

| Object | Subobject | Short text |
|---|---|---|
| ZPTP | | PTP developments |
| | Z301RES | 301 migration: reservation report |
| | Z301MOV | 301 migration: transfer posting |

## Open points to confirm in the target release

| Ref. | Point |
|---|---|
| O4 | Field names of `BAPI_RESERVATION_CHANGE` for the quantity change (needed for test 4) |
| M9 | Receiving valuation-type field in `BAPI2017_GM_ITEM_CREATE` |
| M1 | `MB_DOCUMENT_BADI` fires for all GR channels (MIGO, MB31, CO11N, MFBF) |
| – | Co-products: several finished items per order share `POSNR 0001` in the reservation log |
