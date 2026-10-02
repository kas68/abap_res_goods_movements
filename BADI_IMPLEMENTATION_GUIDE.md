# Implementation Guide — `MB_DOCUMENT_BADI` (GR-triggered 301 transfer)

Detailed build, test and go-live steps for the BAdI part of FS-MM-301MOV-001. This expands
[Step 8 of the main implementation guide](IMPLEMENTATION_GUIDE.md#step-8--enhancement-class-and-badi-implementation).

| Item | Value |
|---|---|
| BAdI definition | `MB_DOCUMENT_BADI` (classic BAdI, multiple use, not filter-dependent) |
| BAdI implementation | `ZMB_DOC_301_TRANSFER` |
| Implementing class | `ZCL_IM_MB_DOC_301_TRANSFER` — delegates only |
| Enhancement class | `ZCE_MB_DOCUMENT_BADI_301` — holds the logic |
| Called function module | `Z_PTP_301_TRANSFER_POST` (remote-enabled, called `IN BACKGROUND TASK`) |
| Package | `ZPTP_301_MIGRATION` |
| Transport | Workbench request 1 (same as all other objects) |
| Source files | [ZCE_MB_DOCUMENT_BADI_301.abap](ZCE_MB_DOCUMENT_BADI_301.abap), [ZCL_IM_MB_DOC_301_TRANSFER.abap](ZCL_IM_MB_DOC_301_TRANSFER.abap) |

---

## 1. How it works

```
MIGO / CO11N / MB31 ... posts GR 101 (or reversal 102)
        │
        ▼
MB_DOCUMENT_BADI~MB_DOCUMENT_BEFORE_UPDATE         (same LUW as the GR, before the update task)
  ZCL_IM_MB_DOC_301_TRANSFER  ──►  ZCE_MB_DOCUMENT_BADI_301->BEFORE_UPDATE
        │   for each relevant MSEG line:
        │   CALL FUNCTION 'Z_PTP_301_TRANSFER_POST' IN BACKGROUND TASK   (only registers a tRFC unit)
        ▼
COMMIT WORK of the GR  ──►  GR is saved
        │
        ▼
tRFC unit runs in its own LUW, under the user who posted the GR
  Z_PTP_301_TRANSFER_POST: posts the 301 (or cancels it for a 102), writes ZPTP_301_MOV_LOG
```

Design rules that the build must keep:

| Rule | Why |
|---|---|
| The BAdI never posts, commits, rolls back or raises messages. | It runs inside the GR's LUW. Any of these would break or cancel the goods receipt. |
| The 301 is only *registered* (`IN BACKGROUND TASK`). | It runs after the GR commit, so a failed transfer can never roll back the GR. If the GR is cancelled, the registered unit is discarded too. |
| Logic lives in `ZCE_MB_DOCUMENT_BADI_301`, not in the BAdI class. | Development standard: enhancements are encapsulated in a `ZCE_` class. |
| Cheap checks first (`AUFNR`, `BWART`), database reads after. | The BAdI runs on **every** goods movement in the client. |
| `ZPTP_301_CTRL-ACTIVE` is the on/off switch. | The implementation can stay active in production; nothing happens until the flag is set. |

### Selection logic (`BEFORE_UPDATE`)

An `XMSEG` line triggers a transfer only if **all** of these are true:

| # | Check | Source | If not met |
|---|---|---|---|
| 1 | `MSEG-AUFNR` is filled | `XMSEG` | skip line |
| 2 | `MSEG-BWART` is `101` (GR) or `102` (GR reversal) | `XMSEG` | skip line |
| 3 | An active entry exists in `ZPTP_301_CTRL` for `WERKS_FR = MSEG-WERKS` | `GET_CONTROL` | skip line |
| 4 | `MKPF-BUDAT` is within `VALID_FROM` / `VALID_TO` (blank = open) | `XMKPF` | skip line |
| 5 | `MSEG-MATNR` is an `AFPO` item material of the order | `IS_HEADER_MATERIAL` | skip line |

Result: one tRFC unit per relevant line, with `IV_REVERSAL = 'X'` for a `102`. A MIGO document with
two orders creates two units and two rows in `ZPTP_301_MOV_LOG`.

---

## 2. Prerequisites

Check these before creating the BAdI objects. The BAdI fires on every goods movement as soon as the
implementation is active, so everything it calls must already work.

| # | Prerequisite | How to check |
|---|---|---|
| 1 | Tables `ZPTP_301_CTRL` and `ZPTP_301_MOV_LOG` active | SE11 |
| 2 | `ZPTP_301_CTRL` maintained with `ACTIVE` **blank** in the development client | SM30 |
| 3 | `Z_PTP_301_TRANSFER_POST` active, processing type **Remote-Enabled Module**, all parameters *Pass Value* | SE37 → Attributes / Import tab |
| 4 | `MB_DOCUMENT_BADI` exists and is enhanceable | SE18 → `MB_DOCUMENT_BADI` → display |
| 5 | Existing implementations reviewed | SE18 → Implementation → Overview (see 2.1) |
| 6 | Interface types match the code | SE24 → `IF_EX_MB_DOCUMENT_BADI` (see 2.2) |

### 2.1 Existing implementations

In SE18, display `MB_DOCUMENT_BADI` → *Implementation* → *Overview*. For every **active**
implementation, note:

- whether it reacts to production-order goods receipts (`BWART` 101/102 with `AUFNR`)
- whether it changes `XMSEG` or posts follow-on documents

The BAdI is multiple-use and the call order of implementations is not guaranteed. Our implementation
only reads `XMKPF`/`XMSEG`, so it is safe alongside others, but a second implementation that also
posts a transfer for the same GR would create a duplicate 301. Clarify that with the owner before go-live.

### 2.2 Interface check

In SE24 display `IF_EX_MB_DOCUMENT_BADI` → method `MB_DOCUMENT_BEFORE_UPDATE` → *Parameters*:

| Parameter | Expected type | Used by our code |
|---|---|---|
| `XMKPF` | `TY_T_MKPF` | yes → `IT_MKPF` |
| `XMSEG` | `TY_T_MSEG` | yes → `IT_MSEG` |
| `XVM07M` | `TY_T_VM07M` | no |

If the types differ in your release, change the `IMPORTING` types of `ZCE_MB_DOCUMENT_BADI_301->BEFORE_UPDATE`
to match (step 3.3).

---

## 3. Enhancement class `ZCE_MB_DOCUMENT_BADI_301` (SE24)

Create it **before** the BAdI implementation: the BAdI class calls it, so it must activate first.

### 3.1 Create the class

SE24 → class `ZCE_MB_DOCUMENT_BADI_301` → *Create* → *Class*.

| Field | Value |
|---|---|
| Description | MB_DOCUMENT_BADI: GR-triggered 301 migration transfer |
| Instantiation | Public |
| Class type | Usual ABAP class |
| Final | ✔ |
| Package | `ZPTP_301_MIGRATION` |
| Transport request | workbench request 1 |

### 3.2 Paste the source

1. In the class editor, click **Source Code-Based** (toolbar button, or *Utilities → Settings → Class Builder → Source code-based*).
2. Select all and replace with the full content of [ZCE_MB_DOCUMENT_BADI_301.abap](ZCE_MB_DOCUMENT_BADI_301.abap).
   Comments must stay inside a section or a method: SE24 stores each method as its own include, so a
   comment above `CLASS`, between `ENDCLASS` and `CLASS ... IMPLEMENTATION`, or between `ENDMETHOD`
   and `METHOD` fails with *"The class contains unknown comments which can't be stored"*.
3. Save, check (Ctrl+F2), activate.

In ADT: *New → ABAP Class*, same name and description, then replace the generated source the same way.

### 3.3 Components (for review after pasting)

| Method | Visibility | Description |
|---|---|---|
| `BEFORE_UPDATE` | Public | Enqueue the 301 transfer for relevant GR items |
| `GET_CONTROL` | Private | Read the active control entry of the origin plant |
| `IS_HEADER_MATERIAL` | Private | Check that the material is the order's finished product |

| Parameter | Method | Kind / type | Description |
|---|---|---|---|
| `IT_MKPF` | `BEFORE_UPDATE` | Importing `TY_T_MKPF` | Material document headers |
| `IT_MSEG` | `BEFORE_UPDATE` | Importing `TY_T_MSEG` | Material document items |
| `IV_WERKS` | `GET_CONTROL` | Importing `WERKS_D` | Origin plant |
| `ES_CTRL` | `GET_CONTROL` | Exporting `ZPTP_301_CTRL` | Control entry |
| `RV_ACTIVE` | `GET_CONTROL` | Returning `ABAP_BOOL` | Control entry active |
| `IV_AUFNR` | `IS_HEADER_MATERIAL` | Importing `AUFNR` | Production order |
| `IV_MATNR` | `IS_HEADER_MATERIAL` | Importing `MATNR` | Material |
| `RV_HEADER` | `IS_HEADER_MATERIAL` | Returning `ABAP_BOOL` | Material is the finished product |

| Constant | Value | Description |
|---|---|---|
| `GC_GR_101` | `'101'` | Goods receipt for production order |
| `GC_REV_102` | `'102'` | Reversal of goods receipt |

### 3.4 Expected check results

| Message | Action |
|---|---|
| Warning on `SELECT SINGLE * FROM zptp_301_ctrl`: key not fully specified | Accept. One active row per origin plant is assumed (see open point M5). |
| *The class contains unknown comments which can't be stored* | A comment is outside a section or method (see 3.2). Move it inside or delete it. |
| *Type "TY_T_MKPF" / "TY_T_MSEG" is unknown* | Use the types shown in 2.2. |
| Anything about `Z_PTP_301_TRANSFER_POST` | The FM must exist and be active (prerequisite 3). |

---

## 4. BAdI implementation `ZMB_DOC_301_TRANSFER` (SE19)

### 4.1 Create the implementation

1. SE19 → section *Create Implementation* → select **Classic BAdI** → BAdI name `MB_DOCUMENT_BADI` → *Create Impl.*
2. Implementation name: `ZMB_DOC_301_TRANSFER`.
3. Fill the *Attributes* tab:

   | Field | Value |
   |---|---|
   | Implementation short text | 301 migration: GR-triggered transfer 8P01 -> 8Q01 |

4. *Interface* tab → *Name of implementing class*: `ZCL_IM_MB_DOC_301_TRANSFER`
   (this is the name SAP proposes; overwrite it if the proposal differs).
5. Save → package `ZPTP_301_MIGRATION`, workbench request 1. SAP generates the class with the
   interface `IF_EX_MB_DOCUMENT_BADI` and both methods empty.

### 4.2 Implement the methods

Do **not** paste the full class file over the generated class; only fill the method bodies.

1. *Interface* tab → double-click `MB_DOCUMENT_BEFORE_UPDATE`.
2. Between `METHOD` and `ENDMETHOD`, insert (from [ZCL_IM_MB_DOC_301_TRANSFER.abap:21-22](ZCL_IM_MB_DOC_301_TRANSFER.abap#L21-L22)):

   ```abap
   NEW zce_mb_document_badi_301( )->before_update( it_mkpf = xmkpf
                                                   it_mseg = xmseg ).
   ```

3. Save and activate the method. Go back.
4. Double-click `MB_DOCUMENT_UPDATE`, insert the comment `" not used`, save and activate.
   (An empty method is fine; opening it once ensures it is generated and active.)

Class description in SE24 (if not set by SE19): *BAdI impl. ZMB_DOC_301_TRANSFER (MB_DOCUMENT_BADI)*.

### 4.3 Activate the implementation

Back in SE19, *Implementation → Activate* (or the activate button). The *Runtime behavior*
must show **Implementation is called**.

> From this moment the BAdI runs on every goods movement in the client. It does nothing as long as
> `ZPTP_301_CTRL-ACTIVE` is blank, but a syntax or runtime error in the class **would block all
> goods movements**. Activate only after the class has passed the check in step 3.4.

### 4.4 Transport objects

Check that request 1 contains:

| Object | Name |
|---|---|
| `R3TR CLAS` | `ZCE_MB_DOCUMENT_BADI_301` |
| `R3TR CLAS` | `ZCL_IM_MB_DOC_301_TRANSFER` |
| `R3TR SXCI` | `ZMB_DOC_301_TRANSFER` (BAdI implementation, including its active state) |

---

## 5. Authorizations

The 301 runs in tRFC **under the user who posted the GR**, not under a batch user.

| Who | Object | Values |
|---|---|---|
| Every user who posts production GRs (MIGO, CO11N, MB31 …) | `M_MSEG_WMB` | `ACTVT 01`; `BWART 301, 302`; `WERKS 8P01, 8Q01` |

If the authorization is missing, the GR still posts; the 301 fails and is logged with status **E**
in `ZPTP_301_MOV_LOG`. It can be reposted later with `ZPTP_301_MON` (mode *Repost errors*) by a key user.

---

## 6. Unit test in the development / test client

### 6.1 Set-up

| Table | Entry |
|---|---|
| `ZPTP_301_CTRL` | `8P01 → 8Q01`, storage locations, `MOVE_TYPE 301`, `NO_RESV_ACTION` as agreed, **`ACTIVE = X`** (test client only) |
| `ZPTP_301_VALTYPE` | entry for the fiscal year of the test posting date |
| Reservation | run `ZPTP_301_RES` live for the test order (optional, depending on `NO_RESV_ACTION`) |

### 6.2 Test cases

| # | Test | Expected result |
|---|---|---|
| B1 | GR 101 in MIGO for a released order in 8P01, header material | GR posted. One row in `ZPTP_301_MOV_LOG`, status **S**, `MOV_MBLNR` = new 301 document (check in MB51/MIGO display) |
| B2 | Same as B1 via **CO11N** with automatic GR | Same as B1 |
| B3 | Same as B1 via **MB31** | Same as B1 |
| B4 | Reverse the GR of B1 (MIGO *Cancellation*, 102) | 302 posted, log row status **R** |
| B5 | GR 101 for an order in a plant **without** control entry | GR posted, no log row, no tRFC unit |
| B6 | Set `ACTIVE` blank, repeat B1 | GR posted, no log row |
| B7 | Posting date outside `VALID_FROM` / `VALID_TO` | GR posted, no log row |
| B8 | Delete the `ZPTP_301_VALTYPE` entry, repeat B1 | **GR posted**, log row status **E** "No valuation type mapped…". Restore the entry and repost with `ZPTP_301_MON` |
| B9 | One MIGO document with GRs for **two orders** | Two log rows, two 301 documents |
| B10 | GR by a user **without** `M_MSEG_WMB` for 301 | GR posted, log row status **E** with the authorization message |
| B11 | Post the same GR item twice via repost | Second call skipped (idempotency check), no second 301 |

After each test: **SM58** must be empty for the test user. An entry there means the unit dumped
(technical error), not a business error — see 7.2.

### 6.3 Debugging the tRFC unit

The 301 runs in a separate session, so a normal breakpoint in the GR transaction does not reach it.

**Option A – hold the unit and debug it from SM58**

1. Start the GR transaction, enter `/h` before saving.
2. In the debugger: *Settings → Display/Change Debugger Settings* → tick **tRFC (In Background Task): Block Sending**.
3. Continue (F8). The GR is saved; the unit stays in SM58 with status *Transaction recorded*.
4. SM58 → select the unit → *Edit → Debug LUW*. The debugger stops at the start of `Z_PTP_301_TRANSFER_POST`.

**Option B – external breakpoint**

Set an external (user) breakpoint in `Z_PTP_301_TRANSFER_POST` for your user, then post the GR.
The tRFC runs under your user and stops at the breakpoint.

To debug the **selection logic** (which lines are picked), set a normal breakpoint in
`ZCE_MB_DOCUMENT_BADI_301->BEFORE_UPDATE`; it runs in the GR's dialog session.

---

## 7. Operations

### 7.1 Switching the automation on and off

| Action | How | Transport needed |
|---|---|---|
| Switch on at go-live | `ZPTP_301_CTRL-ACTIVE = X` (SM30) | No — set directly in production as in [main guide step 12](IMPLEMENTATION_GUIDE.md#step-12--transport-and-go-live); the client must allow SM30 changes to this table |
| Emergency stop | `ZPTP_301_CTRL-ACTIVE` blank | No |
| Remove the BAdI completely | SE19 → deactivate `ZMB_DOC_301_TRANSFER` | Yes (workbench) |

Use the `ACTIVE` flag for every operational stop. Deactivating the implementation is a repository
change and only for the end of the migration.

### 7.2 Monitoring

| Where | What you see | Action |
|---|---|---|
| `ZPTP_301_MON` / `ZPTP_301_MOV_LOG` | Business result per GR item: S / E / R / W | Fix the cause (valuation type, reservation, authorization, stock) and run *Repost errors* |
| **SM58** | tRFC units that **dumped** or could not run (system failure) | Analyse in ST22; after the fix restart with SM58 → *Execute LUW*, or report `RSARFCEX` |
| ST22 | Short dumps in `Z_PTP_301_TRANSFER_POST` | Correct and restart from SM58 |
| `ZPTP_301_MON` mode *Catch-up* | GRs that never got a log row (unit lost, BAdI inactive at the time) | Posts the missing 301s |

Business errors (BAPI returns E) **do not** appear in SM58: the function module logs them and
returns normally, so the unit is not retried endlessly.

---

## 8. Open points before go-live

From the [ABAP code review](ABAP_Code_Review_2026-09-23.md). None blocks activation, but each
can produce an unwanted or missing 301 and must be decided by the business / tested.

| Ref. | Point | Test to cover it |
|---|---|---|
| M1 | `MSEG-AUFNR` is also filled on a 101 **for a purchase order** account-assigned to an order. Filter `KZBEW = 'F'` (GR from production order) is missing. | GR for an order-assigned PO → must **not** trigger |
| M1 | Repetitive manufacturing (MFBF) posts **mvt 131**, not 101, and is not covered. Confirm whether HBM uses REM. | MFBF backflush |
| M2 | `IS_HEADER_MATERIAL` also accepts **co-products** (they are `AFPO` items too). If only the main product counts, check `AFPO-POSNR = '0001'` or the co-product flag. | GR of a co-product |
| M5 | `GET_CONTROL` reads by `WERKS_FR` only. Keep exactly **one active row per origin plant**. | – |
| H4 | The monitor's catch-up does not apply the same filters (header material, validity window). Keep both in sync. | Catch-up over a co-product GR |
| Review §112 | With CO11N automatic GR, COGI reprocessing or decoupled confirmations, `BEFORE_UPDATE` may run **inside the update task**. Check that the unit is registered once and runs after the GR commit. | B2, plus a COGI reprocessing test |
| M1/M8 | Several GRs for the same material at once run as parallel tRFC units. For strict sequence, switch to a **bgRFC queue** keyed by material/plant. | Two GRs for the same material within seconds |

---

## 9. Checklist

- [ ] Prerequisites 1–6 checked (section 2)
- [ ] `ZCE_MB_DOCUMENT_BADI_301` created, full source pasted, active
- [ ] `ZMB_DOC_301_TRANSFER` created in SE19 (classic), class `ZCL_IM_MB_DOC_301_TRANSFER`
- [ ] Both methods implemented and active; implementation **activated**
- [ ] Request 1 contains `CLAS` ×2 and `SXCI`
- [ ] `M_MSEG_WMB` for 301/302 in all GR-posting roles
- [ ] Tests B1–B11 passed; SM58 empty
- [ ] Open points in section 8 decided
- [ ] Production: `ACTIVE` blank after import, set to `X` only at go-live
