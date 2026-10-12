# User guide — 301 transfers between 8P01 and 8Q01

This guide explains how the 301 transfer process works and how to run the two programs that support it.

| Program | Transaction | What it does |
|---|---|---|
| Reservation generator | `ZPTP_301_RES` | Creates and keeps up to date the 301 reservations for production orders |
| Transfer report | `ZPTP_301_TRF` | Shows the open reservations and posts the 301 movements you select |

---

## 1. The global logic (read this first)

### 1.1 The idea in one minute

Production orders are produced in plant **8P01**. The finished goods have to be moved to plant **8Q01** with a **301 transfer posting**. In the other direction, raw materials that 8P01 is short of are moved from 8Q01 to 8P01.

The process works in two separate steps:

1. **Plan** — the reservation generator creates a **reservation** for every transfer that will be needed. A reservation is the planned transfer: it says *which material, how much, from which plant to which plant, for which production order*.
2. **Execute** — when goods are really moved, you use the transfer report. It shows the open reservations and the stock available; you select what to move, confirm the quantity, and the program posts the 301 against the reservation.

**Nothing is posted automatically when the goods receipt of a production order is booked.** The goods receipt and the transfer are independent. A person decides when the goods move and how much.

```
 Production order (8P01)
          │
          ▼
 ┌──────────────────────────┐        ┌──────────────────────────────┐
 │ 1. RESERVATION GENERATOR │        │ 2. TRANSFER REPORT           │
 │    ZPTP_301_RES          │ ─────► │    ZPTP_301_TRF              │
 │ creates / aligns the     │ open   │ shows open reservations and  │
 │ 301 reservations         │ reserv.│ stock; posts the 301 for the │
 └──────────────────────────┘        │ items you select             │
                                     └──────────────────────────────┘
                                                  │
                                                  ▼
                                      301 material document, and the
                                      reservation is consumed
```

### 1.2 Two flows

| Flow | Direction | What is reserved | For which orders |
|---|---|---|---|
| **Finished product** | 8P01 → 8Q01 | The finished material of the order, for the quantity not yet delivered | **Released** orders |
| **Raw materials** (selected with *Reservation kind* R or A) | 8Q01 → 8P01 | The components of the order that 8P01 is **short of** | **Open** orders (created or released) |

The two flows have **separate reservations**. A finished-product reservation and a raw-material reservation for the same order never mix.

### 1.3 How the reservation quantity is decided

**Finished product.** The open quantity of the reservation is kept equal to the open quantity of the production order:

> open reservation quantity = order quantity − quantity already delivered

When goods are received on the order, the open quantity falls, and the next generator run lowers the reservation to match. When the order is changed, the reservation follows. When the order is completely delivered, or technically completed or closed, the reservation is closed.

**Raw materials.** For each component of the order, the generator compares the open requirement with the unrestricted stock of the material in plant 8P01:

> shortage = open requirement − unrestricted stock in 8P01

Only a positive shortage is reserved. When the stock in 8P01 later covers the requirement, the reservation for that component is closed. If the component becomes short again, the reservation is reopened.

### 1.3.1 What the transfer does to the reservation
Each posting through the transfer report increases the **withdrawn quantity** of the reservation. The open quantity becomes smaller. You can transfer less than the open quantity; the rest stays open for a later posting.

### 1.4 Which stock counts as "available"

The transfer report shows and checks only **unrestricted-use stock** in the source plant. Stock in quality inspection or blocked stock is **not** counted. If a goods receipt went into quality inspection, you can only transfer it after the usage decision has moved it to unrestricted stock.

### 1.5 Special rules

**Collective orders** (optional). When an order belongs to a collective order:
- the **finished-product** reservation is created only for the **leading** order;
- the **raw-material** reservation is created only for the order at the **lowest level**.

**Exclusion list** (optional). You can provide a spreadsheet of production orders that must **not** get a finished-product reservation, and/or must **not** get a raw-material reservation. See section 2.5.

**Only the main product.** Only the header material of the order gets a finished-product reservation. Co-products and by-products are not reserved.

### 1.5.1 What happens with the valuation type
When the goods are transferred to 8Q01, the receiving stock gets the **valuation type** configured for the plant, the material type and the fiscal year of the posting date. This is automatic and set up by the key user (see section 4). You don't enter it.

### 1.6 What is *not* done automatically
- No transfer is posted when a goods receipt is booked.
- A reversal of a goods receipt does **not** reverse the transfer. If you need to undo a transfer, cancel the 301 material document yourself with transaction **MBST**. The reservation then reopens by itself.
- Existing reservations of an order that is added to the exclusion list, or that is no longer the leading or lowest-level order, are **not** closed. Close them manually in **MB22** if needed.

### 1.7 Typical working rhythm

| When | Who | What |
|---|---|---|
| Regularly (for example every day, or automatically in the background) | Planner | Run the **reservation generator** so that reservations match the orders |
| When goods are ready to move | Warehouse / logistics | Run the **transfer report**, select items, post |
| When the list of excluded orders changes | Planner | Run the generator **online** once with the new spreadsheet |
| At the start of each fiscal year | Key user | Maintain the valuation types (section 4) |

---

## 2. Reservation generator — `ZPTP_301_RES`

### 2.1 Before you start
- Choose the **run mode** (section 2.2): **1 Test** only shows what would happen, **2 Online** (default) shows the test result and lets you create the reservations of the production orders you tick, **3 Background** creates all reservations.
- Always run a test first when you change the selection, the options, or the exclusion list.

### 2.2 The selection screen

**Plants and storage locations**

| Field | Meaning | Default |
|---|---|---|
| Origin plant | Plant where the production orders are produced | 8P01 |
| Origin storage location | Optional **override** of the order's storage location (see below) | — |
| Destination plant | Plant receiving the finished product | 8Q01 |
| Destination storage location | Optional **override** of the receiving storage location (see below) | — |

The two plants must be different.

**Where the storage locations of a new reservation come from**
- **Source (issuing) storage location:** the one typed here (override), otherwise the storage location of the production order (finished product). For raw materials the order has no source storage location, so only the field on the screen applies. If still unknown, the program tries the storage locations of the source plant that hold the material, starting with the one with the most unrestricted stock, and takes the first one for which the table gives a target storage location. If none gives a target, the source is the storage location with the most unrestricted stock (empty if there is no stock) and the target stays empty.
- **Target (receiving) storage location:** the one typed here (override), otherwise the key user's table `ZPTP_301_LGORT`. It is read with the direction, the plants, the **source storage location** and the material type, and returns the target storage location.
- If nothing is found, the reservation has no storage location on that side.

In normal operation leave the two fields empty and let the table decide. The storage locations are **not** a filter for the orders: they are only copied onto the reservations that are created. Existing reservations keep their storage locations. The transfer report takes the source storage location, and the stock it checks, from the reservation.

**Order selection**

| Field | Meaning |
|---|---|
| Production order | Limit the run to some orders (ranges allowed) |
| Order type | Limit by order type |
| Material | Limit by the finished material of the order |
| MRP controller | Limit by MRP controller |
| Reservation requirement date | Requirement date given to **new** reservations (default: today) |

If you leave the selection fields empty, **all** open orders of the origin plant are processed.

**Run control**

| Field | Meaning | Default |
|---|---|---|
| Movement allowed | New reservations are marked as *movement allowed* | ticked |
| Reprocess errors only | Only process items whose last run ended in error | not ticked |
| Extend material to target storage location | When the material does not exist in the target storage location, the program extends it there (copying the data of the source storage location) before creating the reservation | **ticked** |
| Clean all logs | Before the run, deletes **all** rows of the run log and of the reservation log. Online it asks for confirmation. Ignored in test mode. Afterwards *Reprocess errors only* has no error history to work with. | not ticked |

**Run mode** (in the *Run control* block; choose one)

| Mode | What happens |
|---|---|
| **1 Test** | Simulation of all selected orders. Nothing is created, changed or logged. The result list is only shown. |
| **2 Online** (default) | The program first shows the same result list as the test mode, with a **checkbox "Create" on the left of each line**. Tick the lines of the production orders you want, then press **Create reservations** in the toolbar. See section 2.3. Not possible in the background. |
| **3 Background** | All reservations are created, realigned or closed. This mode can run as a background job (schedule it in SM36 / F9 with a variant). If you run it online, the result list is shown at the end. |

**Raw materials**

| Field | Meaning | Default |
|---|---|---|
| Reservation kind (run control) | `H` = finished products only, `R` = components (raw materials) only, `A` = all. Raw-material reservations (8Q01 → 8P01) are created for `R` and `A`. | A |
| RM issuing plant / storage location | Plant that sends the raw material; the storage location is an optional override | 8Q01 |
| RM receiving plant / storage location | Plant that receives the raw material; the storage location is an optional override | 8P01 |

The four raw-material fields are only available when the reservation kind includes components (`R` or `A`).

**Collective orders / exclusions**

| Field | Meaning |
|---|---|
| Collective orders: leading / lowest level | Applies the collective-order rules of section 1.5. Ticked by default |
| Apply exclusion list | Applies the stored exclusion list (section 2.5) |
| Exclusion spreadsheet (.xlsx) | File on your PC with a new exclusion list (only when the previous box is ticked) |

### 2.3 Running it

1. Start transaction **`ZPTP_301_RES`**.
2. Fill in the selection. For a first run, select **1 Test**.
3. Execute (F8).
4. Check the result list (section 2.4).
5. If the result is as expected, go back (F3), choose **3 Background** (or **2 Online**), and execute again.

**Online mode in detail**
1. Choose **2 Online** (default) and execute. The list opens with the simulated result (status *Simulated*).
2. Tick the checkbox **Create** on a line of every production order you want to create. One tick is enough for the whole order: the finished-product line and the raw-material lines of that order are all created together. You can tick several orders.
3. Press **Create reservations** in the toolbar.
4. The lines of the ticked orders are replaced by the real result (*Created*, *Realigned*, *Closed* or *Error*). The other orders stay as *Simulated*.
5. You can tick more orders and press the button again, as often as you like. Leave the list with Back (F3) when you are done.

Orders you do not tick are never created in this mode.

### 2.4 Reading the result list

One line per reservation item. The most important columns:

| Column | Meaning |
|---|---|
| Kind | `H` = finished product (8P01 → 8Q01), `R` = raw-material component (8Q01 → 8P01) |
| Order, Material | The production order and the material reserved |
| Open quantity basis | Open order quantity (H), or the shortage (R) |
| Requirement / Withdrawn quantity | Current values of the reservation |
| Target quantity | The requirement quantity the reservation should have |
| Reservation, Item | Reservation number and item |
| Status | Result of the run, see below |
| Message | Explanation, in particular for errors |

**Status values**

| Status | Meaning |
|---|---|
| Created | A new reservation was created |
| Realigned | The reservation quantity was changed to match the order |
| Closed | The reservation was closed (order finished or no shortage) |
| Unchanged | The reservation was already correct |
| Complete | The reservation is fully transferred |
| Skipped | Nothing to do (for example *Fully received*), or the order was excluded by a rule (the message gives the reason) |
| Simulated | Test mode, or online mode before you create: this is what **would** happen |
| Error | Something failed; read the message |

Every run is also stored in the run log with the counters (created, realigned, closed, unchanged, skipped, errors).

**Layout of the list**
- The lines are **grouped by production order** first, then by item, then by kind (`H` finished product, `R` raw material). The *Kind* column is next to *Item*.
- The material column is followed by the material **description** and the **material type**, then the **batch of the production order** (finished product: the batch of the order; raw material: the batch of the component line). The same batch is put on the new reservation, and the transfer report proposes it, then **Ext. to target plant**: ticked when the material is extended to the target plant (plant data exist there). If it is empty, the reservation cannot be created and the material has to be extended to the plant first (the program only extends the storage location, not the plant).
- The column **Coll.Order Lead** is ticked only for the leading order of a collective order.
- The column **Lead coll. order** shows the leading order of the collective order the production order belongs to (empty if it is not part of a collective order).
- Lines are coloured by status: **green** for *Created*, *Complete* and *Unchanged*, **dark grey** for *Closed*, **yellow** for *Realigned*. The ALV has a fixed colour palette, so the text keeps its default colour.
- Lines with status **E** (error) are shown in **red text on a white background**.
- The **lowest-level order** of a **collective order** has a **light-grey background**.
- The other orders of a collective order (not the lowest level) are shown in **grey font**.

To check a reservation afterwards, use **MB23** (display reservation). **MB25** lists reservations, and the production order number is in the *goods recipient* field.

### 2.4a Material not yet in the target storage location

A reservation can only be created if the material exists in the **target storage location**. If it does not, and **Extend material to target storage location** is ticked, the program extends the material for you: it creates the storage location data in the target plant, copying the data of the source storage location (storage bin, MRP indicator, special procurement type, reorder point, replenishment quantity, inventory correction factor). The line then shows the message *material extended to target SLoc*. In a test run the status says *material will be extended to target SLoc*.

The program cannot extend the material if it does not exist in the **target plant** at all, or if the target storage location does not exist in the plant. In that case the line shows *Create error* with the reason, and the key user has to extend the material to the plant (MM01/MM02).

This changes the material master, so only leave the option ticked if this is wanted. With the option off, the reservation is not created and the BAPI's own error message is shown.

### 2.5 Using the exclusion list

Use it when some orders must **not** get a reservation, for example orders handled outside this process.

**Prepare the Excel file (.xlsx)**
- **Worksheet 1:** production orders that must **not** get a **finished-product** reservation (8P01 → 8Q01).
- **Worksheet 2:** production orders that must **not** get a **raw-material** reservation (8Q01 → 8P01).
- Put the order numbers in **column A**. A header row in row 1 is allowed and ignored.
- The file must be the **complete** list, because every upload **replaces** the previous list.

**Load and use it**
1. Start `ZPTP_301_RES` **online** (not in the background).
2. Tick **Apply exclusion list**.
3. In **Exclusion spreadsheet**, choose the file (use the field's search help to pick it from your PC).
4. Execute. The list is stored, and the run uses it.

Later runs, **including scheduled background runs**, use the **stored** list. Leave the file field empty and just tick **Apply exclusion list**. Upload a new file only when the list changes.

Excluded orders appear in the result with status **Skipped** and the message *Order on exclusion list*.

### 2.6 Running it automatically

The program does not reschedule itself. To run it regularly, schedule it as a recurring background job (SM36, with a variant using **3 Background**).

### 2.7 Collective orders

**Collective orders: leading / lowest level** is ticked by default. With it ticked, orders that do not qualify show status **Skipped** with the message *Collective order: not the leading order* (finished product) or *not the lowest-level order* (raw materials).

---

## 3. Transfer report — `ZPTP_301_TRF`

### 3.1 Before you start
- Reservations must exist; run the generator first (section 2).
- The material must be available as **unrestricted** stock in the source plant.
- For batch-managed materials, know the batch you want to move.

### 3.2 The selection screen

| Field | Meaning | Default |
|---|---|---|
| Source plant (issuing) | Plant the goods leave | 8P01 |
| Destination plant (receiving) | Plant the goods go to | 8Q01 |
| Reservation | Limit to some reservations | — |
| Production order | Limit to some orders | — |
| Material | Limit to some materials | — |
| Requirement date | Limit by requirement date | — |
| Only items with unrestricted stock | Hide items with nothing available | not ticked |
| Posting date | Posting date of the 301 | today |

- Use **8P01 → 8Q01** to transfer finished products.
- Use **8Q01 → 8P01** (swap the two plants) to transfer raw materials.

### 3.3 The result list

One line per open reservation item. The status light is empty until you post.

| Column | Meaning |
|---|---|
| Reservation, Item | Reservation number and item |
| Prod. order | The production order the goods belong to |
| Material, Description | The material |
| From / To plant, SLoc | Issuing and receiving plant and storage location |
| Req. date | Requirement date |
| Req. qty / Withdrawn | Quantity required and already transferred |
| **Open res. qty** | What is still to be transferred |
| **Unrestr. stock** | Unrestricted stock available in the source |
| **Qty to post** (highlighted, editable) | Quantity the report will post. **Default = open reservation quantity** |
| UoM | Unit of measure |
| **Batch** (highlighted, editable) | Batch to transfer, for batch-managed materials |
| Mat. doc | The 301 material document, after a successful posting |
| Message | Result or error of the posting |

### 3.4 Posting a transfer

1. Click the **grey selector** at the left of the row(s) you want to post. You can select several rows.
2. Check the **Qty to post**. Change it if you want to transfer less than the open quantity (click the cell, type the new quantity).
3. For batch-managed materials, enter the **Batch**.
4. Press **Post transfer** in the toolbar.

The program posts **one 301 per selected row**, each independent of the others.

After posting:
- **Green light:** posted. The material document number is shown, and the open quantity and stock on that row are refreshed. The row is deselected.
- **Red light:** not posted. The message says why. Fix the cause and try again.

### 3.5 Rules the program checks

- The quantity must be **greater than zero**.
- The quantity cannot be **more than the open reservation quantity**.
- The quantity cannot be **more than the unrestricted stock** in the source.
- A batch-managed material **needs a batch**.

You can transfer **less** than the open quantity as many times as you like until the reservation is complete.

### 3.6 Messages you may see and what to do

| Message | What it means / what to do |
|---|---|
| Quantity must be greater than zero | Enter a positive quantity |
| Quantity exceeds open reservation quantity | Lower the quantity, or ask the planner to run the generator if the order quantity was increased |
| Quantity exceeds unrestricted stock | Not enough free stock; the goods may be in quality inspection or blocked |
| Material … is batch-managed: enter a batch | Fill in the Batch column |
| Reservation item is deleted or final-issued | The reservation is no longer usable; run the generator |
| No valuation type mapped for fiscal year …, plant …, material type … | The key user must maintain the valuation types (section 4) |
| Could not determine fiscal year for posting date … | Check the posting date; contact the key user |
| Material not batch-managed in plant … | The batch cannot be created in the destination; contact the key user |
| Source batch … read error / Batch … create error | The batch could not be copied to the destination plant; read the text and contact the key user |
| Other SAP error text (for example posting period closed) | This is SAP's own message. Fix the cause or contact support |

Every attempt, successful or not, is stored in the transfer log.

### 3.7 Undoing a transfer

Cancel the 301 material document in **MBST** (movement type 302 is created). The withdrawn quantity of the reservation goes back and the item is open again in the transfer report.

---

## 4. For the key user: what has to be maintained

Use transaction **SM30** for these tables.

| Table | What to maintain |
|---|---|
| `ZPTP_301_CTRL` | One row for the plant pair 8P01 → 8Q01, with **Active** ticked. It enables the valuation-type logic for the finished-product transfer. |
| `ZPTP_301_LGORT` | The **target storage location** of the reservations. Key: direction (`H` finished product, `R` raw material), issuing plant, receiving plant, **source storage location** (blank = any) and material type (blank = all). The most specific row wins: first the row for the source storage location, then the row for the material type. Both storage locations must exist in their plant. Components of one order that need different target storage locations end up in separate reservations. Changing the table does not change reservations that already exist. |
| `ZPTP_301_VALTYPE` | The destination **valuation type** per destination plant, material type and fiscal year. A blank plant or material type means "all". Add the rows for the next fiscal year **before the year starts**, or transfers dated in the new year are refused. Keep a blank-material-type row as a fallback for each year. |

The exclusion list is stored in the table `ZPTP_301_EXCL`; it is filled through the spreadsheet upload and is not normally edited by hand.

---

## 5. Quick reference

### Daily routine
1. `ZPTP_301_RES`, mode **1 Test**. Check the result.
2. `ZPTP_301_RES`, mode **3 Background** (all) or **2 Online** (selected orders). Reservations are up to date.
3. `ZPTP_301_TRF`. Select the items you move today, confirm quantities, **Post transfer**.

### Where to check things

| What | Where |
|---|---|
| A reservation | **MB23** (display), **MB25** (list; order number in *goods recipient*) |
| A transfer material document | **MB03** |
| Cancel a transfer | **MBST** |
| Close a reservation by hand | **MB22** |
| Scheduled generator jobs | **SM37**, the job you scheduled for the generator |

### Common questions

**The goods receipt of the order was booked, but there is no transfer. Why?**
Transfers are not automatic. Use the transfer report.

**The finished product is in quality inspection. Can I transfer it?**
Not until the usage decision moves it to unrestricted stock. Until then it is not counted as available.

**The order quantity changed. Is the reservation updated?**
Yes, at the next generator run (Realigned).

**An order is not in the transfer report.**
Check that the reservation exists (MB23). If not, run the generator and look at the status for that order: it may be *Skipped* (excluded, not the leading order, not released, fully received).

**A raw-material reservation was not created.**
Check that *Also reserve raw materials* was ticked, that the component is a stock item and really short in 8P01, and that the order is not excluded or part of a collective order at a higher level.

**Can I transfer more than the reservation?**
No. The quantity is limited to the open reservation quantity. Ask the planner to correct the order or the reservation.
