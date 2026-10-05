# ZPTP_SPLIT_VAL_MIG — HBM Split Valuation (program v0.5)

Inter-plant transfer (mvt 301) of **unrestricted** stock from source plant **8P01** to the
new Split-Valuation plant **8Q01**. Both plants are defaults on the selection screen and stay
obligatory and validated against T001W. Handles **both batch-managed and non-batch-managed** materials.
Mapping and quantities come from the HBM Valuation Type Input File.

## Files
This repository holds the code only; version history is kept in git (the former
`*_v0.1_backup` / `*_v0.2_backup` copies are no longer needed).

- `ZPTP_SPLIT_VAL_MIG.abap` — executable report (SE38).
- `ZPTP_SPLIT_VAL_DDIC.txt` — SE11 tables, data elements, and message class ZPTP_SPLIT_VAL (002–023).
- `ZPTP_SPLIT_VAL_README.md` — this file, the technical documentation.
- `ZPTP_SPLIT_VAL_FUNCTIONAL_SPEC.md` — functional specification and user guide (processing,
  selection-screen parameters, input file format, results).
- `ZPTP_SPLIT_VAL_SPEC_FONCTIONNELLE.md` — the same specification and user guide in French.
- `HIGH_LEVEL_OVERVIEW.md` — non-technical overview of the program.
- `SAP ABAP Development Standard and Namimg Conventions.docx` — the customer's development
  standards and naming conventions (Sysmex D-Project, v1.2).

## What changed in v0.5 (naming conventions)
No change to the processing. Objects follow the Sysmex D-Project *ABAP Development Standards &
Naming Conventions* v1.2 with Work Stream ID **PTP** (MM, Appendix B of the standard).

| # | Change | Why |
|---|---|---|
| 28 | External objects renamed (table below) | Standard §3.2: `Z<WS_ID>_<name>` for reports, tables and message classes; `ZDE<name>` for data elements |
| 29 | Global types `TY_`/`TT_` → `GTY_`/`GTT_`; boolean methods `SEG_EXISTS` → `IS_SEGMENT_CREATED`, `IN_LIST` → `IS_IN_LIST` | Standard §3.3.1 (global structure/table types) and §3.3.4 (`IS_<adjective>` for boolean methods) |
| 30 | Code of `AT SELECTION-SCREEN` and `ON VALUE-REQUEST` moved to `F_CHECK_SCREEN` and `F_F4_FILE` | Standard §4.4.1: data declared in an event block is global; the variables are now local |
| 31 | Program header restructured to the comment block of Appendix A (Description, Context, Assumptions, Design decisions, Related developments); the change history is kept in git | Standard §4.5.1 |

| Object | Before (v0.4) | Now (v0.5) | Rule |
|---|---|---|---|
| Report | `ZHBM_SPLIT_VAL_PH1` | `ZPTP_SPLIT_VAL_MIG` | `Z<WS_ID>_<name>` |
| Log table | `ZLOT_MOV_EXEC` | `ZPTP_MOV_EXEC` | `Z<WS_ID>_<name>` (max. 16 characters) |
| Log table | `ZLOT_BATCH_EXT` | `ZPTP_BATCH_EXT` | `Z<WS_ID>_<name>` |
| Data elements | `ZLOT_RUN_ID`, `ZLOT_RUN_SEQ`, `ZLOT_RUN_MODE`, `ZLOT_STATUS` | `ZDELOT_RUN_ID`, `ZDELOT_RUN_SEQ`, `ZDELOT_RUN_MODE`, `ZDELOT_STATUS` | `ZDE<name>` |
| Domains | `ZLOT_RUN_MODE`, `ZLOT_STATUS` | unchanged | `Z<name>` (already compliant) |
| Message class | `ZHBM` | `ZPTP_SPLIT_VAL` | `Z<WS_ID>_<name>`; §4.10 asks for a dedicated class per large development |
| Package | — | `ZPTP_SPLIT_VAL` (suggested) | `Z<WS_ID>_<name>` |
| Transaction (if needed) | — | `ZPTP_SPLIT_VAL_MIG` | `Z<WS_ID>_<name>` |

Table field names (`RUN_ID`, `RUN_SEQ`, `RUN_MODE`, `STATUS`) are unchanged. Read strictly,
§3.2.11 (field = data element without the leading `ZDE`) would give `LOT_RUN_ID` etc.; the
shorter names are kept to avoid renaming every log field. Confirm this deviation with the
Development Lead, or rename the fields before the tables are created.

## Fixes from the first activation in the sandbox (v0.5)
Found while activating and running the report in the SAP sandbox. Items 32–36 are syntax or
runtime-type errors; item 37 is a functional bug in the quantity check.

| # | Change | Why |
|---|---|---|
| 32 | `POSNR` (table `ZPTP_MOV_EXEC`) and `GV_POSNR` typed `NUMC06` instead of `NUMC6` | Naming alignment. `NUMC06` must exist in the system: create it (NUMC, length 6) if it does not |
| 33 | `S_MATNR`, `S_CHARG`, `S_MTART` declared `FOR` the typed global fields `GV_SEL_MATNR`, `GV_SEL_CHARG`, `GV_SEL_MTART` | `FOR gt_stock-matnr` / `gt_marc-mtart` referred to tables without header line: syntax error |
| 34 | `F_F4_FILE`: `USER_ACTION` of `FILE_OPEN_DIALOG` received in a `TYPE i` field; the selected file read into a `FILE_TABLE` work area, then copied to `P_FILE` | Type conflicts with the method interface: syntax error |
| 35 | `F_F4_FILE`: `I_PATH` of `F4_DXFILENAME_TOPRECURSION` passed as a `DXFIELDS-LONGPATH` copy of `P_FILE` | `P_FILE` is a string: F4 on the application-server path dumped with `CALL_FUNCTION_CONFLICT_TYPE` |
| 36 | `F_EXTEND_BATCH`: empty typed fields `LV_NOID` (`SYMSGID`) and `LV_NONO` (`SYMSGNO`) passed to `F_ADD_EXT_LOG` instead of `SPACE` | Typed FORM parameters do not accept a 1-character literal: syntax error |
| 37 | Check 3.5: the variance is computed directly into `LS_OUT-VARIANCE` (`MENGE_D`) | The inline `DATA(lv_var)` of a subtraction was typed P(8,0): decimals were rounded, so a variance below 0.5 passed the check as a match and was logged as 0 |
| 38 | Selection screen wrapped in an outer frame `B0` titled `TEXT-T01` | Bold heading *STOCKS & BATCHES MIGRATION PROGRAM* (a comment line cannot be bold) |
| 39 | Selection texts rewritten as *label (technical name)*, within 30 characters | The screen showed the technical names: the text pool had not been maintained |
| 40 | References to the specification documents removed from the code and the documentation | Request |

If activation reports *unknown column name "RUN_ID"*, the active version of `ZPTP_MOV_EXEC` in
the system does not match the DDIC file (table not activated, or fields named differently).
The program itself reads the fields as specified.

## What changed in v0.4 (receiving storage location)
| # | Change | Why |
|---|---|---|
| 26 | Each 301 item is received in the storage location with the **same code** as its issuing location (`MOVE_STLOC = STGE_LOC`). `P_LGDST` is optional, only checked against `T001L` when filled, and not used for posting. `LGORT_DST` in the log is the actual receiving location (blank when nothing was posted) | Migration rule: stock keeps its storage location, only the plant changes |
| 27 | Every allocated storage location must exist in the target plant (`T001L`, buffered once), else the line is blocked with `ZPTP_SPLIT_VAL 023`. Allocation and this check now run **before** batch creation; if batch creation fails the allocated stock is given back | The error is caught in validation and in simulation, not by the BAPI at posting time, and no batch is created in 8Q01 for a line that cannot be posted |

## What changed in v0.3 (code review)
| # | Change | Why |
|---|---|---|
| 15 | Target valuation type passed in `MOVE_VAL_TYPE`; `VAL_TYPE` (issuing side) left blank | `VAL_TYPE` is the issuing side, and 8P01 is not split-valuated |
| 16 | A Material+Batch split over several valuation types is rejected (`ZPTP_SPLIT_VAL 016`); an existing target batch with another valuation type blocks the line (`ZPTP_SPLIT_VAL 019`) | With split valuation a batch carries one valuation type (`MCHA-BWTAR`) |
| 17 | Batch creation copies the source batch attributes (`BAPI_BATCH_GET_DETAIL`) and sets the valuation type; `RETURN` passed as a TABLES parameter; unreadable source batch → `ZPTP_SPLIT_VAL 020` | Keep expiry/production date and vendor batch; the default creation lost them |
| 18 | Direct Transfer Mode posts the valuation type only when the material is split-valuated in the target (`MBEW-BWTTY`) | The mode is meant for materials without split valuation |
| 19 | File unit converted to internal (`CONVERSION_EXIT_CUNIT_INPUT`, `ZPTP_SPLIT_VAL 017`) and required to equal the base unit (`ZPTP_SPLIT_VAL 018`); blank = base unit | `PC` vs `ST`; the reconciliation compares base-unit stock |
| 20 | Log rows written before every BAPI call and committed together with each posting; update failure after commit written back (`ZPTP_SPLIT_VAL 022`); inserted row count checked | A dump mid-run no longer leaves posted documents without a log |
| 21 | Simulation runs `BAPI_GOODSMVT_CREATE` with `TESTRUN = 'X'`, then rollback | The test run now checks the posting itself |
| 22 | `P_DEL`: `S_TABU_NAM` check; refused when the run holds posted documents | The log is the migration audit trail |
| 23 | Screen checks only on execution; `P_LGDST`/`P_BUDAT` checked there (and again at start for background jobs) instead of `OBLIGATORY` | Radio-button switch no longer raises errors; delete path needs neither field |
| 24 | `CONVERSION_EXIT_MATN1_INPUT` exceptions caught (`ZPTP_SPLIT_VAL 009`) | No dump on an over-long material number |
| 25 | MBEW of the target plant buffered once; MCHB filtered `CLABS > 0` in the DB; sorted look-up for the NO_BATCH stock check | Performance on full-plant volumes |

### To verify in the sandbox before the first real run
1. A 301 on a batch-managed, split-valuated material: the receiving batch gets the valuation type
   of `MOVE_VAL_TYPE`, and expiry/production date are present in 8Q01.
2. Batch level (plant / material / client): whether classification must be copied explicitly
   (`CLASS*` tables of `BAPI_BATCH_CREATE`) — not done in v0.3.
3. The `BAPIBATCHATT` fields copied from the source batch: exclude any that must not follow the
   batch (e.g. deletion flag, restricted status).
4. Simulation of a batch that does not yet exist in 8Q01: the `TESTRUN` posting may report the
   missing receiving batch, since batch creation is not simulated.
5. Material numbers longer than 18 characters: if extended material numbers are active, the
   BAPIs need the `*_LONG` fields.
6. Signatures of `BAPI_BATCH_GET_DETAIL` / `BAPI_BATCH_CREATE` in SE37 (RETURN as TABLES).

## Deployment order
1. Create package `ZPTP_SPLIT_VAL` (or the package the Development Lead assigns).
2. Create domains `ZLOT_RUN_MODE`, `ZLOT_STATUS` and data elements `ZDELOT_RUN_ID`,
   `ZDELOT_RUN_SEQ`, `ZDELOT_RUN_MODE`, `ZDELOT_STATUS`.
3. Create tables `ZPTP_MOV_EXEC` and `ZPTP_BATCH_EXT` (column store, see the DDIC file); activate.
   Check that data element `NUMC06` exists (used by `POSNR`).
4. Create message class `ZPTP_SPLIT_VAL` (SE91) with the numbers listed in the DDIC file.
5. Create report `ZPTP_SPLIT_VAL_MIG` with the title *STOCKS & BATCHES MIGRATION PROGRAM*
   (Attributes), paste source, add the selection texts and text symbols below, activate.
6. Transport requests follow Appendix C of the standard: `<Work Item ID> : <Work Item Description>`.

## Selection texts (SE38 → Goto → Text elements → Selection texts)
Without these entries the selection screen shows the technical names. Each text is
*label (technical name)* and stays within the 30-character limit of a selection text;
leave *Dictionary Ref.* unticked, otherwise SAP replaces the text with the data element label.

| Name | Text |
|------|------|
| P_WSRC | Source plant (P_WSRC) |
| P_WDST | Target plant (P_WDST) |
| P_LGDST | Receiving SLoc (P_LGDST) |
| S_MATNR | Material (S_MATNR) |
| S_CHARG | Batch (S_CHARG) |
| S_MTART | Material type (S_MTART) |
| P_BUDAT | Posting date (P_BUDAT) |
| P_SRV | Application server (P_SRV) |
| P_LOC | Local file (P_LOC) |
| P_FILE | Input file path (P_FILE) |
| P_SEP | Field separator (P_SEP) |
| P_RUNID | Run ID, blank=new (P_RUNID) |
| P_REPRC | Reprocess errors (P_REPRC) |
| P_FULL | Full validation (P_FULL) |
| P_DIR | Direct transfer (P_DIR) |
| P_TEST | Simulation (P_TEST) |
| P_DEL | Delete run ID (P_DEL) |

Text symbols: `T01`=STOCKS & BATCHES MIGRATION PROGRAM (screen heading), `B01`=Organizational data,
`B02`=Input file, `B03`=Run control, `B04`=Maintenance.

Program attribute *Title* (SE38 → Attributes, shown in the window title bar):
`STOCKS & BATCHES MIGRATION PROGRAM`.

## Scope restrictions
`S_MATNR`, `S_CHARG` and `S_MTART` are optional and narrow both the stock selection and the
input file. `S_MTART` is evaluated against `MARA-MTART` through the `GT_MARC` buffer.

`F_READ_MARC` deliberately reads MARC **without** the material-type restriction: keeping the
type of every material of the plant is what lets the program distinguish a material left out
by `S_MTART` (dropped silently, a deliberate scope choice) from one that is not extended to
the plant (reported by `ZPTP_SPLIT_VAL 006` / `ZPTP_SPLIT_VAL 014`). Restricting the SELECT would collapse the
two cases into one misleading message.

With any of the three set, the "SAP stock not in input file" reconciliation only covers the
selected scope.

## Input file layout
Flat text file, one record per **Material / Batch / Valuation type**:

| Property | Rule |
|---|---|
| Separator | `P_SEP`, default `;` — must not occur inside a value (no quoting/escaping) |
| Fields | At least 5, fixed order; fewer → `ZPTP_SPLIT_VAL 009`, extra fields ignored |
| Header | Line 1 skipped when its 4th field is non-numeric or it has fewer than 5 fields; a file without one is fine |
| Encoding | App-server default code page (`ENCODING DEFAULT`) — **no BOM** |
| Line endings | Those of the app server — transfer in **text** mode, or a stray `CR` lands in the UoM |
| Empty lines | Ignored anywhere |
| Blanks / case | Trimmed; `CHARG`, `BWTAR`, `MEINS` upper-cased; `MATNR` via `CONVERSION_EXIT_MATN1_INPUT` |
| Decimals | `.` or `,`; no thousands separator |

```
MATNR;CHARG;BWTAR;QUANTITY;UOM
100234;0000004711;VT01;150,000;KG     <- one valuation type per batch
100234;0000004712;VT02;80,000;KG     <- another batch, another valuation type
200987;NO_BATCH;VT01;1250,000;PC      <- not batch-managed, declared
300555;;VT02;0,000;L                  <- blank batch (non-batch material, not verified); zero qty -> status Z
```

Per-field rejections: `MATNR`/`BWTAR` missing or material number not convertible → `009`;
quantity non-numeric → `007`, negative → `008`; unit unknown → `017`, not the base unit → `018`;
batch with several valuation types → `016` (zero-quantity lines are not counted); no stock →
`006`; segment missing in target plant → `003`.

A blank batch is not the same as `NO_BATCH`: it is not verified against the material master. On
a non-batch-managed material it is the normal case; on a batch-managed material it finds no
stock (MCHB is read per batch) and the line ends in `006`.

**Not in the file:** storage location, plants, movement type, posting date. The issuing
locations come from the stock, the rest from the selection screen, and the movement type is
always 301 — so adding a column changes nothing without a code change.

## Storage locations (v0.2, receiving side v0.4)
The input file carries no storage location. Stock is read **per `LGORT`** (`MCHB` / `MARD`)
and each input line is allocated over the issuing storage locations that hold the stock,
**largest remaining first**, from a pool shared by all valuation-type lines of the same
Material+Batch — so the same quantity is never issued twice. One material document is posted
per input line, with **one item per issuing storage location** (`STGE_LOC`).

**Receiving storage location (v0.4).** For this migration the receiving storage location in
the target plant has the same code as the issuing one in the source plant: each item is
posted with `MOVE_STLOC = STGE_LOC` (same `LGORT` code on both sides, only the plant differs).
Every allocated storage location must therefore exist in 8Q01 (`T001L`); if one is missing
the line is blocked with status `E` / `ZPTP_SPLIT_VAL 023` and nothing is posted. This check runs
right after the allocation and before batch creation, so it also shows up in a simulation
run. `P_LGDST` is optional: when filled it is only checked against `T001L`.

One `ZPTP_MOV_EXEC` row is written per item.

If the line cannot be covered by the remaining stock, nothing is posted and the record is
logged with status `E` / `ZPTP_SPLIT_VAL 005` — a partial issue is never performed.

> Allocation rule to confirm with the business: largest-first (implemented) vs pro rata.

## Processing logic
- **3.1 Stock identification** — reads unrestricted stock in 8P01 per storage location:
  batch-managed materials from `MCHB-CLABS`, non-batch materials from `MARD-LABST`;
  batch-management flag `BATCHMGD` = `MARC-XCHPF` of 8P01 **or** `MARA-XCHPF`. Quality,
  blocked and special stock are **not** read.
- **3.2 Presence in input file** — a Material/Batch present in SAP but absent from the file
  is checked against the target plant: if a valuation-type segment already exists there
  (`MBEW`), it's flagged **inconsistent** (status `I`, `ZPTP_SPLIT_VAL 010`), logged, and not
  processed; otherwise it is logged as skipped (status `X`, `ZPTP_SPLIT_VAL 011`). Runs in Full
  Validation Mode only, and not on a `P_REPRC` run. Stock of a material or Material+Batch
  already blocked by a line check (`013`–`016`, `018`) is not reported a second time.
- **3.3 Valuation-type validation** — for each file record, the BWTAR valuation segment must
  exist in the target plant (`MBEW`, BWKEY = target plant); otherwise error (status `E`),
  record excluded.
- **3.4 Batch creation** — batch-managed materials only: if the batch is missing in the
  target plant it's created by extension with `BAPI_BATCH_CREATE` + `BAPI_TRANSACTION_COMMIT`,
  carrying the attributes of the source batch (`BAPI_BATCH_GET_DETAIL`) and the target
  valuation type. If it already exists with another valuation type the line is blocked
  (`ZPTP_SPLIT_VAL 019`). A failed creation blocks the transfer. Each attempt is logged in
  `ZPTP_BATCH_EXT`; the result is memorised per Material+Batch for the run, so a batch is
  extended once even when several lines refer to it.
- **3.5 Quantity validation** — file total per Material+Batch must equal available
  unrestricted SAP stock; mismatch blocks (status `E`). **Zero-quantity** file lines post no
  movement (status `Z`).
- **3.6 Stock transfer** — storage-location allocation, then `BAPI_GOODSMVT_CREATE`
  (mvt 301, GM code 04) + commit; one document per input line, one item per issuing storage
  location; batch fields filled only when applicable; target valuation type in
  `MOVE_VAL_TYPE`; receiving `MOVE_STLOC` uses the same `LGORT` code as the issuing side
  for each item, which must exist in the target plant (`ZPTP_SPLIT_VAL 023`, checked before batch
  creation). Posting date from `P_BUDAT`. The document and its log rows are committed
  in the same LUW.
- **4. Logging** — every record written to `ZPTP_MOV_EXEC` (RUN_ID, sequence, mode, testrun,
  material/batch, plants, storage locations, BWTAR, qty, posting date, doc/year, status,
  `MSGID/MSGNO/MSGTX`); batch extensions to `ZPTP_BATCH_EXT`. The ALV mirrors `ZPTP_MOV_EXEC`.

**Order of the checks for one line** (`F_PROCESS_LINES`): blocked by a line check → zero
quantity (`Z`) → no stock (`006`) → *Full mode only:* segment (`003`), quantity (`004`) →
allocation (`005`) → receiving storage locations (`023`) → batch extension (`019`, `020`, BAPI
message) → 301 posting. The first failure ends the line.

## Batch column (v0.2)
The column carries one of three things, and the program treats them differently.

### `NO_BATCH` — a declaration
`NO_BATCH` (also `NOBATCH`, `NO-BATCH`, `NO BATCH`, case-insensitive — constant
`GC_NO_BATCH`) states that the material is **not batch-managed in the source plant nor in the
target plant**. It is the agreed convention, so it raises **no warning**. The program:

1. verifies the declaration three ways in `F_VALIDATE_NO_BATCH`, which runs before the
   aggregation because the declaration decides how the line is posted:
   - `MARC-XCHPF` of the **source** plant and of the **target** plant,
   - `MARA-XCHPF`, the client-level indicator — a material flagged only at client level
     would otherwise be classified as non-batch (the derived field `BATCHMGD` is
     `MARC-XCHPF = 'X' OR MARA-XCHPF = 'X'` and is what every check in the program uses),
   - the stock itself: no unrestricted batch stock may exist in `MCHB` for the source plant,
     which catches a material whose batch indicator was removed after batches were created;
2. **creates no batch** in the target plant — `BAPI_BATCH_CREATE` is not called;
3. posts the 301 with the **valuation type only**: `MOVE_VAL_TYPE` is set (receiving side,
   `VAL_TYPE` stays blank as for every line), `BATCH` and `MOVE_BATCH` are left empty;
4. reconciles the quantity against `MARD-LABST` and allocates it over the source storage
   locations like any other non-batch line.

A declaration contradicted by the material master blocks the line before anything is posted:
`ZPTP_SPLIT_VAL 013` when the material is batch-managed in either plant (the message quotes both
indicators), `ZPTP_SPLIT_VAL 014` when it is not extended to one of them, `ZPTP_SPLIT_VAL 015` when batch stock
exists in 8P01 despite the master data. The material is then excluded from the "SAP stock not in file"
reconciliation, so the run reports the real cause once instead of a missing-stock message
plus an inconsistency.

### A placeholder — a tolerated deviation
`N/A`, `NA`, `NONE`, `NULL`, `-`, `--`, `#`, `.` (constant `GC_DUMMY_BATCH`) are reduced to
blank and **do** raise the `ZPTP_SPLIT_VAL 012` warning, since they are not the agreed convention.

### Anything else
`F_NORMALISE_BATCH` clears **any** remaining batch value carried by a material that is not
batch-managed in 8P01 (`BATCHMGD` off), which catches a convention nobody declared; that also raises
`ZPTP_SPLIT_VAL 012`. On a batch-managed material a non-blank value is taken as a real batch number.

One `ZPTP_SPLIT_VAL 012` row per run reports how many lines were normalised, and each affected record
carries "(batch value normalised to blank)" in its message.

## Input validation (v0.2)
Unusable file lines are **rejected and logged** with status `E` instead of being dropped
silently: layout error (`ZPTP_SPLIT_VAL 009`), non-numeric quantity (`ZPTP_SPLIT_VAL 007`), negative quantity
(`ZPTP_SPLIT_VAL 008`). Line 1 is treated as the header and skipped when its quantity is not numeric.
An input line whose Material+Batch has no unrestricted stock in the source plant is reported
as `ZPTP_SPLIT_VAL 006`, not as a quantity mismatch.

The selection screen checks both plants against `T001W`, refuses source = target, checks
`P_LGDST` against `T001L` when it is filled, requires a separator, and verifies that the input file is
readable before the run starts.

## Execution modes (sec.5)
- **Full Validation Mode** (`P_FULL`, default) — runs all checks 3.2–3.5; only fully valid
  records are transferred.
- **Direct Transfer Mode** (`P_DIR`) — bypasses the validation logic (presence, valuation
  segment, quantity reconciliation) and posts directly; intended for materials that do not
  yet have Split Valuation active in the target plant; the "SAP stock not in file"
  reconciliation is skipped too. Batch creation still runs. The
  valuation type of the file is posted only when the material is split-valuated in the target
  plant; otherwise the 301 carries none and the record says so. The line-level checks (unit of
  measure, one valuation type per batch, NO_BATCH) still apply, and so do zero quantity (`Z`),
  no stock (`006`), allocation (`005`) and receiving storage location (`023`).

## RUN_ID & restart (sec.6)
Each run uses a `RUN_ID` (entered, or auto-generated `HBM<date><time>` when blank) plus an
incremental `RUN_SEQ` (001, 002, …) computed automatically from prior rows. With **Reprocess
error lines only** (`P_REPRC`) set on an existing RUN_ID, only records that ended in status
`E` in the previous sequence are re-processed. Full history is preserved.

Status `I` records (SAP stock absent from the file while a target segment exists) **cannot**
be recovered this way — they carry no valuation type and are by definition not in the file.
Complete the input file and start a **full** run; the program issues an information message
when the previous sequence holds status `I` rows. The "SAP stock not in file" reconciliation
is skipped entirely on a `P_REPRC` run, since the input set is then a deliberate subset.

## Simulation vs real (sec.7)
`P_TEST` (TESTRUN, default ON) performs all reads/validations, reads the source batch, and
calls `BAPI_GOODSMVT_CREATE` with `TESTRUN = 'X'` followed by a rollback, so the posting
itself is checked **without** any database change; rows are logged with status `T`, or `E`
with the BAPI message; the material document column shows `SIMULATED`. Batch creation is not
simulated (the batch row in `ZPTP_BATCH_EXT` has status `T`). Uncheck to post.

## Maintenance — delete a RUN_ID (sec.5)
`P_DEL` + a `RUN_ID` deletes that run's rows from `ZPTP_MOV_EXEC` and `ZPTP_BATCH_EXT` only
(after a confirmation popup). No stock movement, no impact on SAP standard data. Requires
`S_TABU_NAM` (activity 02, table `ZPTP_MOV_EXEC`) and is refused when the run holds posted
documents (status `S`, not a test run): the log of real postings is the audit trail.

## Assumptions / to confirm
- **Valuation level = plant**, so `MBEW-BWKEY` = target plant. If your system valuates at
  company-code level, pass the valuation area instead of `p_wdst` as `IV_BWKEY` to
  `lcl_help=>load_mbew`, `is_segment_created` and `is_split_valuated`.
- `BAPI_BATCH_CREATE` receives the attributes of the source batch plus the target valuation
  type; classification is not copied (see "To verify in the sandbox").
- Stock is read for the `s_matnr` / `s_charg` / `s_mtart` scope in 8P01; for the 3.2 "SAP not
  in file" check to be complete, run without those filters (heavier) or filter deliberately.
- Quantities must be in the material base unit: the file unit is converted to the internal
  unit and checked against `MARA-MEINS` (`ZPTP_SPLIT_VAL 017` / `ZPTP_SPLIT_VAL 018`); a blank unit is read as
  the base unit.
- One valuation type per batch: a batch split over several valuation types is rejected
  (`ZPTP_SPLIT_VAL 016`). HBM to confirm the rule for such batches (correct the file, or new batch
  numbers).
- Authorization: the posting BAPIs run their own checks; `P_DEL` checks `S_TABU_NAM`. A
  report-level check (e.g. `S_TCODE` / a custom object) to be added per your security model.
- Receiving storage location = issuing storage-location code (v0.4). 8Q01 must be created
  with the same storage locations as 8P01 (at least those holding stock); run a simulation
  first — any gap shows as `ZPTP_SPLIT_VAL 023`.
- Allocation rule largest-first; pro rata would split a line across more items and can
  introduce rounding on UoM with decimals.
- Placeholder list for the batch column (`GC_DUMMY_BATCH`) to be confirmed against the actual
  HBM extract; a value that is neither blank nor in the list is still caught by the
  `MARC-XCHPF` safeguard for non-batch materials, but would be taken as a real batch on a
  batch-managed one.
- The batch-management test is `MARC-XCHPF = 'X' OR MARA-XCHPF = 'X'`, evaluated per plant
  and exposed as `GT_MARC-BATCHMGD`. Confirm with HBM which indicator their material master
  actually maintains.

## Development standards not yet met
The v0.5 pass covers naming. The following points of the customer standard remain open and need
either a code change or a breach approval from the Integration and Development Lead:

- **Hard-coded texts (§2.2, §4.11).** Selection-screen messages, log texts and ALV column headers
  are string literals. They should become text symbols and `ZPTP_SPLIT_VAL` messages
  (`MESSAGE ... INTO`), which also makes `MSGTX` translatable and `MSGID`/`MSGNO` exact.
- **Local classes instead of FORMs (§4.3, §4.4.1).** The report is FORM-based; the standard
  asks for local classes and methods.
- **ALV (§4.11, §4.12).** `REUSE_ALV_GRID_DISPLAY` with a hand-built field catalog; the
  standard asks for OO/factory ALV (`CL_SALV_TABLE`) on a DDIC structure (`ZS<name>`) typed
  with standard data elements, so the headers are translated.
- **Report-level authorization check (§4.20.1).** Only `P_DEL` checks `S_TABU_NAM`; a check
  on execution (e.g. an authorization object `ZPTP_<name>` or `M_MSEG_WWA` on the plants) is
  still to be agreed with the security team.
- **Online documentation (§4.5.2)** for the report in SE38, and message long texts (§4.10).
- **`TYPE-POOLS`** is obsolete and can be removed once the code is checked in the system.
