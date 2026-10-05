# 301 Migration Transfer Solution - High-Level Overview

## 1. Executive summary

This solution supports the progressive migration of operations from plant **8P01**, which is being wound down, to plant **8Q01**, the target plant.

Finished goods produced in 8P01 must be transferred to 8Q01 as production continues. The solution automates this temporary migration process by combining:

1. **Reservation management**: create and maintain plant-to-plant transfer reservations for the finished products of relevant production orders.
2. **Goods-receipt-triggered transfer**: automatically transfer each received quantity from 8P01 to 8Q01 as soon as the production receipt is posted.
3. **Monitoring and recovery**: provide visibility, error handling, reposting and catch-up processing for transfers that could not be completed immediately.
4. **Optional raw-material reservations**: create and maintain a separate 301 reservation for production-order component shortages, from 8Q01 back to 8P01, for subsequent manual execution.

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

### Raw materials from 8Q01 to 8P01

The reservation report has an **optional raw-material function**, controlled by the `P_RAWMAT` checkbox. It is off by default.

When enabled, the report creates a **separate** movement type 301 reservation from 8Q01 to 8P01 for the short components of each **open** production order (created or released; not technically completed, closed or flagged for deletion). The finished-product reservation still requires the order to be **released**.

```text
Raw-material shortage in 8P01
    -> own 301 reservation from 8Q01 to 8P01 (one item per component)
```

The shortage is the open component requirement minus unrestricted stock in 8P01. Deleted items, phantom assemblies, non-stock items and components already finally issued are excluded. Components that become short after the reservation was created are placed in a new raw-material reservation; existing items are realigned, or closed when the shortage is covered or the order is completed.

This reservation is independent of the finished-product reservation and is used for manual execution only (MB1B or MIGO). It is not consumed by the goods-receipt-triggered posting.

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

## 4. Solution overview

### 4.1 Reservation creation and alignment

Report `ZPTP_301_RESERVATION_GENERATOR` creates and maintains the transfer reservations for open production orders.

For each qualifying production order, the report:

- selects the finished or header material of the order;
- calculates the production order open quantity;
- checks whether a migration reservation already exists;
- creates a movement type 301 reservation when required;
- realigns the reservation when its remaining quantity differs from the order open quantity;
- closes the reservation when the order is complete or no longer requires a transfer;
- prevents duplicate reservations by using the custom order-to-reservation link and log.

The finished-product reservation is created only for released orders. When `P_RAWMAT` is enabled, the report also creates, realigns or closes the separate raw-material reservation for open orders (see section 2).

The report can be run interactively with an ALV result list or in the background with an application log. It also supports a test mode that shows the expected actions without changing the database.

### 4.2 Automatic transfer after goods receipt

The BAdI implementation `ZMB_DOC_301_TRANSFER` (class `ZCL_IM_MB_DOC_301_TRANSFER`, logic in enhancement class `ZCE_MB_DOCUMENT_BADI_301`) detects relevant material-document items during goods movement posting.

It processes only items that meet the configured scope, including:

- goods receipt movement type 101, or the corresponding reversal movement type 102;
- production order receipt in the configured origin plant;
- finished or header material of the production order;
- active plant-pair and migration configuration.

The BAdI does not post the transfer directly inside the goods receipt transaction. It registers `Z_PTP_301_TRANSFER_POST` as a background task so that the transfer runs after the goods receipt has successfully committed, in a separate logical unit of work.

This design ensures that a failed 301 transfer does not cancel or block the original goods receipt.

### 4.3 Transfer posting

Function module `Z_PTP_301_TRANSFER_POST` performs the physical transfer for one source goods-receipt item.

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

Report `ZPTP_301_MOVEMENT_MONITOR` provides three operating modes:

- **Monitor**: display source goods receipts and their transfer status in ALV.
- **Repost**: retry failed or warning entries that do not yet have a transfer material document.
- **Catch-up**: scan the goods-receipt history for relevant 101 receipts that have no completed transfer and post the missing movements.

Catch-up processing can be scheduled periodically. The frequency is configurable, from one minute to multiple days, and the active control configuration acts as a stop switch.

## 5. Main functional capabilities

### Automatic quantity-based transfer

The transfer quantity is taken from the actual goods-receipt item. The solution therefore follows production output rather than relying on a periodic estimate.

### Header-material control

Only the production order's finished or header material is transferred. Component materials and unrelated goods movements are ignored.

### Reservation consumption

When a related reservation is available, the 301 is posted against it so that the reservation consumption quantity is updated and the remaining balance stays aligned with the production order.

### Batch continuity

For batch-managed materials, the batch received in 8P01 is carried into the transfer to 8Q01.

### Fiscal-year valuation handling

The destination valuation type is determined from the fiscal year of the goods receipt posting date and the maintained `ZPTP_301_VALTYPE` correspondence table. This supports fiscal-year rollover and avoids guessing when a mapping is missing.

### Reversal handling

A cancelled goods receipt (102) triggers the corresponding reverse transfer logic. The original 301 document is located and cancelled through the reverse movement process, subject to the configured business controls.

### Idempotency and duplicate prevention

Each source goods-receipt item is identified by material document, document year and item number. Before posting, the solution checks `ZPTP_301_MOV_LOG`. A transfer that already has a material document is not posted again, including during retries or catch-up runs.

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

## 7. Operational controls

The migration scope is controlled by configuration rather than hard-coded process assumptions. The control data defines, at minimum:

- origin plant and destination plant;
- default storage locations;
- transfer movement type;
- behaviour when no reservation is found;
- activation status and optional validity dates.

The solution also validates the key prerequisites, including plant and storage-location existence, same-company-code restrictions, posting authorization, material availability and valuation-type mapping.

The automation can therefore be switched off without removing the programs or changing the implementation when the migration ends.

## 8. Scope boundaries

### Included

- Migration transfers from the configured origin plant to the configured destination plant.
- Finished goods received against production orders.
- Creation, alignment and closure of 301 reservations for finished products.
- Optional creation, alignment and closure of separate raw-material reservations from 8Q01 to 8P01.
- Automatic 301 posting after relevant goods receipts.
- Reversal processing, monitoring, reposting and catch-up.
- Online simulation and background scheduling.

### Excluded

- Automatic posting of raw-material transfers; their physical execution remains manual.
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
- controlled handling of reversals and fiscal-year valuation types;
- clear operational visibility of successes, warnings and errors;
- a recoverable process that does not jeopardize goods-receipt posting;
- a temporary automation that can be retired cleanly after the migration.

## 10. Main SAP objects

| Object | Role |
|---|---|
| `ZPTP_301_RESERVATION_GENERATOR` / `ZPTP_301_RES` | Create and align 301 reservations |
| `ZCL_IM_MB_DOC_301_TRANSFER` / `ZCE_MB_DOCUMENT_BADI_301` | Detect relevant 101 and 102 material-document items |
| `Z_PTP_301_TRANSFER_POST` | Post or reverse the follow-on transfer |
| `ZPTP_301_MOVEMENT_MONITOR` / `ZPTP_301_MON` | Monitor, repost and catch up transfers |
| `ZPTP_301_CTRL` | Activate and scope the migration automation |
| `ZPTP_301_RES_LOG` | Link production orders to finished-product (`RES_KIND` H) and raw-material (`RES_KIND` R) reservations |
| `ZPTP_301_MOV_LOG` | Record source receipts and transfer results |
| `ZPTP_301_RUN_LOG` / `ZPTP_301_MOVRLOG` | Execution logs of the reservation report and the monitor |
| `ZPTP_301_VALTYPE` | Map fiscal years to destination valuation types |
| `ZPTP_SPLIT_VAL` | Shared message class (messages 027–051) |

## 11. Lifecycle

This solution is designed for the migration period only:

1. activate and configure the 8P01 to 8Q01 plant pair;
2. create and align reservations for the remaining production orders;
3. operate the automatic finished-goods transfer and monitoring processes;
4. resolve any remaining errors and close completed reservations;
5. deactivate the control entry when 8P01 has been fully drained;
6. retain the logs for audit and migration history according to the applicable retention policy.

The core business outcome is simple: production receipts made in the closing plant are transferred to the target plant promptly, consistently and with enough control to recover safely when an individual transfer cannot be posted automatically.
