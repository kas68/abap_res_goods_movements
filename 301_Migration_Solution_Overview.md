# 301 Migration Transfer Solution - High-Level Overview

## 1. Executive summary

This solution supports the progressive migration of operations from plant **8P01**, which is being wound down, to plant **8Q01**, the target plant.

Finished goods produced in 8P01 must be transferred to 8Q01 as production continues. The solution automates this temporary migration process by combining:

1. **Reservation management**: create and maintain plant-to-plant transfer reservations for relevant production orders and, when enabled, their component shortages.
2. **Goods-receipt-triggered transfer**: automatically transfer each received quantity from 8P01 to 8Q01 as soon as the production receipt is posted.
3. **Monitoring and recovery**: provide visibility, error handling, reposting and catch-up processing for transfers that could not be completed immediately.
4. **Optional raw-material back-flow planning**: create and maintain 301 reservations for production-order component shortages, from 8Q01 back to 8P01, for subsequent manual execution.

The result is a controlled and auditable flow in which production output in 8P01 is progressively made available in 8Q01, without relying on manual transfer creation for every production receipt.

## 2. Why this solution is needed

The movement from 8P01 to 8Q01 is a **migration activity**, not a permanent supply relationship between the two plants. While 8P01 is being drained, stock produced there must follow the migration and be relocated to 8Q01.

Without automation, users would need to:

- identify open production orders and calculate the quantity still to be transferred;
- create or adjust movement type 301 reservations manually;
- monitor goods receipts and create matching 301 transfers manually;
- investigate missing or failed transfers;
- ensure that reversals and quantity changes remain consistent.

This manual process is time-consuming and creates a risk of incomplete transfers, duplicate postings, quantity mismatches and limited traceability.

The solution addresses these risks by making the migration flow event-driven, repeatable and auditable. It is intended to operate only during the migration window and can be disabled through configuration once 8P01 has been fully drained.

### Raw-material back-flow from 8Q01 to 8P01

The reservation report supports an **optional raw-material back-flow planning function**, controlled by the `P_RAWMAT` checkbox. It is off by default.

When enabled, the report creates or aligns one movement type 301 reservation per relevant stock component of the selected production orders:

```text
Raw-material shortage in 8P01
    -> 301 reservation from 8Q01 to 8P01
```

The shortage is calculated as the open component requirement minus unrestricted stock available in 8P01. Deleted items, phantom assemblies, non-stock items and components already finally issued are excluded. A component with no shortage does not receive a new reservation; an existing reservation can be closed when the shortage is covered.

This back-flow is currently a **reservation and planning capability only**. The physical movement is not triggered by the goods-receipt BAdI and is not posted by `Z_MM_301_POST_TRANSFER`; users execute it manually through the standard transfer process, such as MB1B or MIGO. The automatic posting path remains restricted to finished/header-material receipts from 8P01 to 8Q01.

## 3. Business principle

For each relevant production order, the quantity still to be transferred must remain aligned with the quantity still open on the order:

```text
Reservation open quantity = Production order open quantity
BDMNG - ENMNG              = PSMNG - WEMNG
```

Where:

- `PSMNG` is the production order quantity;
- `WEMNG` is the quantity already received against the order;
- `BDMNG` is the reservation requirement quantity;
- `ENMNG` is the quantity already withdrawn or transferred from the reservation.

When a goods receipt of quantity `X` is posted, the solution performs a matching transfer:

```text
Goods receipt 101 for X in 8P01
    -> Transfer posting 301 for X from 8P01 to 8Q01
```

This keeps the physical stock movement and the reservation consumption aligned with production progress.

For an optional raw-material component reservation, the equivalent basis is the uncovered component requirement in 8P01. The reservation direction is reversed, from the configured source plant 8Q01 to the production plant 8P01.

## 4. Solution overview

### 4.1 Reservation creation and alignment

Report `ZMM_R_CREATE_301_RESERV` creates and maintains the transfer reservations for open production orders.

For each qualifying production order, the report:

- selects the finished or header material of the order;
- calculates the production order open quantity;
- checks whether a migration reservation already exists;
- creates a movement type 301 reservation when required;
- realigns the reservation when its remaining quantity differs from the order open quantity;
- closes the reservation when the order is complete or no longer requires a transfer;
- prevents duplicate reservations by using the custom order-to-reservation link and log.

When `P_RAWMAT` is enabled, it additionally:

- reads open stock-component requirements from `RESB` at the production plant;
- compares each requirement with unrestricted stock in 8P01 from `MARD`;
- calculates the shortage to be supplied from 8Q01;
- creates, realigns or closes component reservations for the 8Q01 to 8P01 direction;
- records header and raw-material reservations separately using `RES_KIND` values `H` and `R`.

The report can be run interactively with an ALV result list or in the background with an application log. It also supports a test mode that shows the expected actions without changing the database.

### 4.2 Automatic transfer after goods receipt

The BAdI implementation `ZCL_MM_301_GR_TRIGGER` detects relevant material-document items during goods movement posting.

It processes only items that meet the configured scope, including:

- goods receipt movement type 101, or the corresponding reversal movement type 102;
- production order receipt in the configured origin plant;
- finished or header material of the production order;
- active plant-pair and migration configuration.

The BAdI does not post the transfer directly inside the goods receipt transaction. It registers `Z_MM_301_POST_TRANSFER` as a background task so that the transfer runs after the goods receipt has successfully committed, in a separate logical unit of work.

This design ensures that a failed 301 transfer does not cancel or block the original goods receipt.

The BAdI deliberately ignores raw-material component movements. Raw-material reservations are consumed only by the separate manual transfer process unless a future enhancement introduces an explicit automatic back-flow posting process.

### 4.3 Transfer posting

Function module `Z_MM_301_POST_TRANSFER` performs the physical transfer for one source goods-receipt item.

It:

- rereads the persisted goods receipt and its material-document details;
- checks the migration control entry and posting authorizations;
- determines the related 301 reservation when available;
- builds and posts the transfer using `BAPI_GOODS_MOVEMENT_CREATE`;
- carries the received quantity, unit of measure, storage location and batch;
- resolves the destination valuation type from the goods receipt posting-date fiscal year;
- commits the transfer independently;
- writes the result to the movement log and application log.

If the reservation is not available, the configured policy determines whether the transfer is posted without a reservation reference or held for later processing.

### 4.4 Monitoring and recovery

Report `ZMM_R_301_MOV_MONITOR` provides three operating modes:

- **Monitor**: display source goods receipts and their transfer status in ALV.
- **Repost**: retry failed or warning entries that do not yet have a transfer material document.
- **Catch-up**: scan the goods-receipt history for relevant 101 receipts that have no completed transfer and post the missing movements.

Catch-up processing can be scheduled periodically. The frequency is configurable, from one minute to multiple days, and the active control configuration acts as a stop switch.

The monitor covers the automatic finished-goods transfer log. Raw-material reservation creation and alignment results are shown by the reservation report's ALV output and reservation execution logs; they are not treated as automatic GR-triggered movements.

## 5. Main functional capabilities

### Automatic quantity-based transfer

The transfer quantity is taken from the actual goods-receipt item. The solution therefore follows production output rather than relying on a periodic estimate.

### Header-material control

Only the production order's finished or header material is transferred. Component materials and unrelated goods movements are ignored.

### Reservation consumption

When a related reservation is available, the 301 is posted against it so that the reservation consumption quantity is updated and the remaining balance stays aligned with the production order.

For raw-material back-flow reservations, the reservation is the planning and authorization record for the manual 8Q01 to 8P01 transfer. It is not consumed by the finished-goods GR-triggered posting.

### Batch continuity

For batch-managed materials, the batch received in 8P01 is carried into the transfer to 8Q01.

### Fiscal-year valuation handling

The destination valuation type is determined from the fiscal year of the goods receipt posting date and the maintained `ZMM_301_VALTYPE` correspondence table. This supports fiscal-year rollover and avoids guessing when a mapping is missing.

### Reversal handling

A cancelled goods receipt (102) triggers the corresponding reverse transfer logic. The original 301 document is located and cancelled through the reverse movement process, subject to the configured business controls.

This automatic reversal capability applies to the finished-goods 8P01 to 8Q01 path. Raw-material transfers executed manually follow the standard manual reversal process.

### Idempotency and duplicate prevention

Each source goods-receipt item is identified by material document, document year and item number. Before posting, the solution checks `ZMM_301_MOV_LOG`. A transfer that already has a material document is not posted again, including during retries or catch-up runs.

### Failure isolation

The goods receipt remains successful even if the follow-on transfer fails. The error is recorded for monitoring and can be recovered through reposting or catch-up processing.

### Auditability

The solution records execution and business results in dedicated logs, including:

- source goods receipt and item;
- production order and material;
- transferred quantity and batch;
- reservation reference;
- destination valuation type and fiscal year;
- created transfer document;
- status, message and execution run.

## 6. End-to-end process

```text
1. A production order is open in plant 8P01.
2. The reservation report creates or aligns its 301 transfer reservation.
3. Production output is posted as a goods receipt 101.
4. The BAdI identifies the relevant receipt and registers the follow-on transfer.
5. After the goods receipt commits, the transfer function posts a 301 in a separate LUW.
6. The reservation is consumed and the movement result is logged.
7. If the transfer fails, the goods receipt remains posted and the item appears in the monitor.
8. Repost or catch-up processing retries the missing transfer.
9. When production is complete, the reservation is closed and the migration configuration can be deactivated.
```

When raw-material back-flow is enabled, the reservation report also evaluates component shortages and creates or aligns 8Q01 to 8P01 reservations. Those reservations are then used by the business during a separate manual transfer step.

## 7. Operational controls

The migration scope is controlled by configuration rather than hard-coded process assumptions. The control data defines, at minimum:

- origin plant and destination plant;
- default storage locations;
- transfer movement type;
- behaviour when no reservation is found;
- activation status and optional validity dates.

For raw-material back-flow, the report additionally controls the option and its separate source and target plants and storage locations. The default raw-material direction is 8Q01 to 8P01.

The solution also validates the key prerequisites, including plant and storage-location existence, same-company-code restrictions, posting authorization, material availability and valuation-type mapping.

The automation can therefore be switched off without removing the programs or changing the implementation when the migration ends.

## 8. Scope boundaries

### Included

- Migration transfers from the configured origin plant to the configured destination plant.
- Finished goods received against production orders.
- Creation, alignment and closure of 301 reservations.
- Optional creation, alignment and closure of raw-material component reservations from 8Q01 to 8P01.
- Automatic 301 posting after relevant goods receipts.
- Reversal processing, monitoring, reposting and catch-up.
- Online simulation and background scheduling.

### Excluded

- Automatic posting of raw-material component transfers. Raw-material reservations are supported when enabled, but their physical execution remains manual.
- Intercompany or stock transport order processes.
- Permanent steady-state replenishment between the plants.
- Replacement of the standard goods-receipt process.
- A dedicated Fiori or UI5 front end; the operational interface is the classic selection screen and ALV output.

## 9. Expected business benefits

The solution provides:

- faster availability of migrated stock in 8Q01;
- less manual work for production and inventory teams;
- fewer duplicate, missing or incorrectly sized transfers;
- consistent alignment between production orders and transfer reservations;
- optional visibility of raw-material shortages and planned replenishment reservations from 8Q01 to 8P01;
- controlled handling of reversals and fiscal-year valuation types;
- clear operational visibility of successes, warnings and errors;
- a recoverable process that does not jeopardize goods-receipt posting;
- a temporary automation that can be retired cleanly after the migration.

## 10. Main SAP objects

| Object | Role |
|---|---|
| `ZMM_R_CREATE_301_RESERV` / `ZMM301R` | Create and align 301 reservations |
| `ZCL_MM_301_GR_TRIGGER` | Detect relevant 101 and 102 material-document items |
| `Z_MM_301_POST_TRANSFER` | Post or reverse the follow-on transfer |
| `ZMM_R_301_MOV_MONITOR` / `ZMM301M` | Monitor, repost and catch up transfers |
| `ZMM_301_CTRL` | Activate and scope the migration automation |
| `ZMM_301_RESV_LOG` | Link production orders and header/raw-material items to reservations (`RES_KIND` H/R) |
| `ZMM_301_MOV_LOG` | Record source receipts and transfer results |
| `ZMM_301_VALTYPE` | Map fiscal years to destination valuation types |
| `ZMM301` | Shared message class |

## 11. Lifecycle

This solution is designed for the migration period only:

1. activate and configure the 8P01 to 8Q01 plant pair;
2. create and align reservations for the remaining production orders;
3. optionally enable raw-material back-flow planning and create or align 8Q01 to 8P01 reservations;
4. operate the automatic finished-goods transfer and monitoring processes;
5. execute planned raw-material transfers manually as required;
6. resolve any remaining errors and close completed reservations;
7. deactivate the control entry when 8P01 has been fully drained;
8. retain the logs for audit and migration history according to the applicable retention policy.

The core business outcome is simple: production receipts made in the closing plant are transferred to the target plant promptly, consistently and with enough control to recover safely when an individual transfer cannot be posted automatically.
