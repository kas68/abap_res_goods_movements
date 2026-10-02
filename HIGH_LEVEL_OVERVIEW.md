# High-Level Overview of the Split Valuation Migration Program

## Why this program exists

This program supports a stock migration for a company operating in an SAP environment where inventory must move from an existing plant to a new plant that uses split valuation.

In practical terms, the program takes unrestricted stock from source plant 8P01 and transfers it to target plant 8Q01 using movement type 301. The purpose is to preserve the correct stock positioning while keeping the correct batch and valuation-type mapping in the new plant.

This is not a simple stock move. The migration must:

- move only the relevant unrestricted stock,
- keep batch-managed materials and non-batch materials aligned,
- validate that the target valuation type exists in the new plant,
- create target batches when required,
- reconcile file data with SAP stock,
- log the outcome of every processed record for auditability.

The program is designed for a controlled migration with validation, simulation, and restart capabilities, so the business can move inventory safely without creating inconsistent or duplicate stock records.

---

## What the program does

The ABAP report in [ZPTP_SPLIT_VAL_MIG.abap](ZPTP_SPLIT_VAL_MIG.abap) acts as a migration engine. It reads SAP stock, validates the data coming from the HBM valuation-type input file, and then performs the inter-plant transfer.

### 1. Reads the source stock
The program reads unrestricted stock in the source plant. It distinguishes between:

- batch-managed materials,
- non-batch-managed materials,
- stock located across multiple storage locations.

This is important because the transfer must honor the original stock structure and avoid moving quantities that are not actually available.

### 2. Validates the input file
The program checks the input file that defines what should be moved. For each record, it validates:

- material number,
- batch value,
- valuation type,
- quantity,
- unit of measure,
- whether the target valuation segment exists,
- whether the material/batch combination is allowed.

It also compares the file totals to the actual unrestricted stock in SAP. If the numbers do not match, the line is blocked instead of being posted.

### 3. Handles both batch and non-batch scenarios
The migration supports two main cases:

- Batch-managed materials: batches may need to be created in the target plant.
- Non-batch-managed materials: the program posts the transfer without creating a batch.

The logic also accounts for the “NO_BATCH” convention, where the material is explicitly declared as not batch-managed, and it enforces the declaration against the material master of both plants and against the batch stock. A blank batch is accepted for a non-batch material but is not verified in the same way.

### 4. Creates target batches when needed
For batch-managed materials, the report checks whether the matching batch already exists in the target plant. If it does not exist, it creates it using SAP batch creation logic and copies the source batch attributes where relevant.

This ensures that the receiving batch has the correct master data and receives the target valuation type.

### 5. Allocates stock per storage location
The program does not just move a total quantity; it distributes the stock across the issuing storage locations that actually hold it. This is done before posting so that each 301 movement is consistent with the real stock distribution in the source plant.

The receiving storage location is aligned with the same storage location code, while the plant changes from 8P01 to 8Q01.

### 6. Posts the 301 movement
Once validation and allocation are complete, the program creates one goods movement per input line using 301 movement type. Each movement can include one item per issuing storage location.

The program posts the stock to the target plant while keeping the batch and valuation-type information consistent with the migration rules.

### 7. Runs in validation, simulation, and restart modes
The design includes multiple operational modes:

- Full validation mode: performs the full set of checks.
- Direct transfer mode: skips the valuation-segment check, the quantity reconciliation and the search for SAP stock missing from the file, for materials whose split valuation is not yet active in the target plant; the movement then carries a valuation type only if the material is already split-valuated there.
- Simulation mode: SAP checks each movement in test mode and rolls it back; no stock is moved and no batch is created.
- Restart by RUN_ID: allows a partial rerun or reprocessing of failed lines.

This makes the program practical for large migrations where some records may need to be retried or reviewed separately.

### 8. Logs every processed record
The program writes results to two custom log tables, which form the migration audit trail: ZPTP_MOV_EXEC records every processed line (status, material, batch, plants, storage locations, valuation type, quantities, material document and message), and ZPTP_BATCH_EXT records every batch created or found in the target plant. A run that posted real documents cannot have its log deleted.

This is essential because the migration is not just a posting task; it is a controlled business process with traceability.

---

## Main business value

The program provides three major benefits:

1. Safety: it validates stock, quantity, valuation types, and batch integrity before posting.
2. Control: it supports simulation, reprocessing, and run-based tracking.
3. Auditability: every line is logged and can be reviewed, restarted, or corrected.

In short, this is a controlled migration tool for moving unrestricted stock while preserving valuation and batch consistency across plants.

---

## Related repository files

- [README.md](README.md) — short project summary and status
- [ZPTP_SPLIT_VAL_README.md](ZPTP_SPLIT_VAL_README.md) — more technical implementation details
- [ZPTP_SPLIT_VAL_FUNCTIONAL_SPEC.md](ZPTP_SPLIT_VAL_FUNCTIONAL_SPEC.md) — functional specification and user guide: parameters, input file format, results
- [ZPTP_SPLIT_VAL_SPEC_FONCTIONNELLE.md](ZPTP_SPLIT_VAL_SPEC_FONCTIONNELLE.md) — the same specification in French
- [ZPTP_SPLIT_VAL_DDIC.txt](ZPTP_SPLIT_VAL_DDIC.txt) — supporting SAP table and object definitions
- [ZPTP_SPLIT_VAL_MIG.abap](ZPTP_SPLIT_VAL_MIG.abap) — executable SAP report
