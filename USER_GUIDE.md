# User guide — 301 transfers between 8P01 and 8Q01

This guide explains how the 301 transfer process works and how to run the three programs that support it.

| Program | Transaction | What it does |
|---|---|---|
| Reservation generator | `ZPTP_301_RES` | Creates and keeps up to date the 301 reservations for production orders |
| Transfer report | `ZPTP_301_TRF` | Shows the open reservations and posts the 301 movements you select |
| Reservation manager | `ZPTP_301_MGR` | Deletes reservations created by the generator, reversing their 301 postings first if there are any |
| Log manager | `ZPTP_301_LOG` | Checks that the three log tables are consistent with the reservations, and deletes log records |

---

## 1. The global logic (read this first)

### 1.1 The idea in one minute

Production orders are produced in plant **8P01**. The finished goods have to be moved to plant **8Q01** with a **301 transfer posting**. In the other direction, raw materials that 8P01 is short of are moved from 8Q01 to 8P01.

The process works in two main steps, plus a management tool:

1. **Plan** — the reservation generator creates a **reservation** for every transfer that will be needed. A reservation is the planned transfer: it says *which material, how much, from which plant to which plant, for which production order*.
2. **Execute** — when goods are really moved, you use the transfer report. It shows the open reservations and the stock available; you select what to move, confirm the quantity, and the program posts the 301 against the reservation.
3. **Manage** (when needed) — the reservation manager lets you cancel reservations created by the generator. It deletes the reservation items and, if a 301 was already posted, reverses the material document first.

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
 │                          │        │ items you select             │
 └────────────┬─────────────┘        └──────────────┬───────────────┘
              │ reservations created                │ 301 material documents
              │ by the generator                    │ posted against them
              │                                     │
              ▼                                     ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │ 3. RESERVATION MANAGER   ZPTP_301_MGR                           │
 │ manages the reservations: deletes the items and, if a 301 was   │
 │ posted, reverses the material document first                    │
 └─────────────────────────────────────────────────────────────────┘
```

The transfer report consumes the reservations with 301 postings. The reservation manager is used on the side, when a reservation must be cancelled.

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
When the goods are transferred to 8Q01, the receiving stock gets the **valuation type** configured for the plant, the material type and the fiscal year of the posting date. This is automatic and set up by the key user (see section 6). You don't enter it.

### 1.6 What is *not* done automatically
- No transfer is posted when a goods receipt is booked.
- A reversal of a goods receipt does **not** reverse the transfer. If you need to undo a transfer, cancel the 301 material document yourself with transaction **MBST**, or use the reservation manager (section 4), which reverses the document and deletes the reservation item. After an MBST cancellation the reservation reopens by itself.
- Existing reservations of an order that is added to the exclusion list, or that is no longer the leading or lowest-level order, are **not** closed. Close them manually in **MB22** if needed.

### 1.7 Typical working rhythm

| When | Who | What |
|---|---|---|
| Regularly (for example every day, or automatically in the background) | Planner | Run the **reservation generator** so that reservations match the orders |
| When goods are ready to move | Warehouse / logistics | Run the **transfer report**, select items, post |
| When the list of excluded orders changes | Planner | Run the generator **online** once with the new spreadsheet |
| When reservations must be cancelled | Planner | Use the **reservation manager** (section 4) |
| At the start of each fiscal year | Key user | Maintain the valuation types (section 6) |

---

## 2. Reservation generator — `ZPTP_301_RES`

### 2.1 Before you start
- Choose the **run mode** (section 2.2): **1 Test** only shows what would happen, **2 Online** (default) shows the test result and lets you create the reservations of the production orders you tick, **3 Background** creates all reservations.
- Always run a test first when you change the selection, the options, or the exclusion list.

### 2.2 The selection screen

The screen has these blocks, from top to bottom: **Run control** (with the sub-blocks *Reservation kind*, *Run mode* and *Options*), **Order selection** (with the sub-block *Collective orders / exclusions*), **Plants / locations** and **Raw materials**.

**Run control — Reservation kind** (dropdown, with a legend under it)

| Value | What the program processes |
|---|---|
| **A** All (default) | Finished products and raw-material components |
| **H** Finished products only | Only the finished-product reservations (8P01 → 8Q01) |
| **R** Components only | Only the raw-material reservations (8Q01 → 8P01) |

The raw-material fields (see below) are only available for **R** and **A**.

**Run control — Run mode** (choose one)

| Mode | What happens |
|---|---|
| **1 Test** | Simulation of all selected orders. Nothing is created, changed or logged. The result list is only shown. |
| **2 Online** (default) | The program first shows the same result list as the test mode, with a **checkbox "Create" on the left of each line**. Tick the lines of the production orders you want, then press **Create reservations** in the toolbar. See section 2.3. Not possible in the background. |
| **3 Background** | All reservations are created, realigned or closed. This mode can run as a background job (schedule it in SM36 / F9 with a variant). If you run it online, the result list is shown at the end. |

Selecting *3 Background* does not create a job by itself: it only decides what the run does. See section 2.6 to schedule it.

**Run control — Options**

| Field | Meaning | Default |
|---|---|---|
| Movement allowed | New reservations are marked as *movement allowed* | ticked |
| Extend material to target storage location | When the material does not exist in the target storage location, the program extends it there (copying the data of the source storage location) before creating the reservation | **ticked** |

**Order selection**

| Field | Meaning |
|---|---|
| Production order | Limit the run to some orders (ranges allowed) |
| Order type | Limit by order type |
| Material | Limit by the finished material of the order |
| MRP controller | Limit by MRP controller |
| Reservation requirement date | Requirement date given to **new** reservations (default: today) |

If you leave the selection fields empty, **all** open orders of the origin plant are processed.

**Order selection — Collective orders / exclusions**

| Field | Meaning | Default |
|---|---|---|
| Collective orders: leading / lowest level | Applies the collective-order rules of section 1.5 | **ticked** |
| Apply exclusion list | Applies the stored exclusion list (section 2.5) | not ticked |
| Exclusion spreadsheet (.xlsx) | File on your PC with a new exclusion list (only when the previous box is ticked) | — |

**Plants / locations**

| Field | Meaning | Default |
|---|---|---|
| Origin plant | Plant where the production orders are produced | 8P01 |
| Destination plant | Plant receiving the finished product | 8Q01 |

The two plants must be different.

**Raw materials**

| Field | Meaning | Default |
|---|---|---|
| RM issuing plant | Plant that sends the raw material | 8Q01 |
| RM receiving plant | Plant that receives the raw material | 8P01 |

**Where the storage locations of a new reservation come from**

*Finished products (`H`, 8P01 → 8Q01)*
- **Source (issuing) storage location:** the storage location of the production order. If the order has none, the program tries the storage locations of the source plant that hold the material, starting with the one with the most unrestricted stock, and takes the first one for which the table gives a target storage location. If none gives a target, the source is the storage location with the most unrestricted stock (empty if there is no stock) and the target stays empty.
- **Target (receiving) storage location:** the key user's table `ZPTP_301_LGORT`. It is read with the plants, the **source storage location** and the material type, and returns the target storage location.

*Raw materials (`R`, 8Q01 → 8P01)* — the table is **not** used:
- **Source (issuing) storage location:** the storage location of plant 8Q01 where the **batch of the component** has unrestricted stock (the one with the most stock if there are several). A component without batch: the storage location with the most unrestricted stock.
- **Target (receiving) storage location:** the storage location of the **component item in the production order**.

If nothing is found, the reservation has no storage location on that side.

The storage locations cannot be typed on the selection screen: they come from the rules above (for finished products the key user changes the table, section 6). In **online mode** you can change them for one order in the result list before creating it (section 2.3). The storage locations are **not** a filter for the orders: they are only copied onto the reservations that are created. Existing reservations keep their storage locations. The transfer report takes the source storage location, and the stock it checks, from the reservation.

### 2.3 Running it

1. Start transaction **`ZPTP_301_RES`**.
2. Fill in the selection. For a first run, select **1 Test** in the *Run mode* block.
3. Execute (F8).
4. Check the result list (section 2.4).
5. If the result is as expected, go back (F3), choose **3 Background** (or **2 Online**), and execute again.

**Online mode in detail**
1. Choose **2 Online** (default) and execute. The list opens with the simulated result (status *Simulated*).
2. Tick the checkbox **Create** on a line of every production order you want to create. One tick is enough for the whole order: the finished-product line and the raw-material lines of that order are all created together. You can tick several orders.
3. If needed, change **From SLoc** and **To SLoc** on the lines you are going to create (the two columns are highlighted; click the cell and type the storage location, empty means none). The values are checked when you press the button: a storage location that does not exist in its plant is refused, the order keeps its lines with the status *Error* and the message, and is not created until you correct it. Lines whose reservation already exists keep their storage locations.
4. Press **Create reservations** in the toolbar.
5. The lines of the ticked orders are replaced by the real result (*Created*, *Realigned*, *Closed* or *Error*). The other orders stay as *Simulated*.
6. You can tick more orders and press the button again, as often as you like. Leave the list with Back (F3) when you are done.

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

**Deleted and closed reservation items.** A reservation item that was **deleted** in SAP is treated as if it had never been created: the generator creates a new reservation for the open quantity and never changes the deleted item. A **closed** item (final issue set) is shown as *Complete* and left alone. An item that you only closed by setting its required quantity equal to the withdrawn quantity is not treated as closed: if the order still has open quantity, the generator realigns it.

Every run is also stored in the run log with the counters (created, realigned, closed, unchanged, skipped, errors).

**Layout of the list**
- The lines are **sorted and grouped by production order** first, then by item, then by kind (`H` finished product, `R` raw material). The *Kind* column is next to *Item*.
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

The program does not reschedule itself. To run it regularly, schedule it as a recurring background job:

1. Run the program once on screen, with the selection you want and **3 Background**, and save it as a **variant** (Goto > Variants > Save as variant).
2. In **SM36**, create the job with the program `ZPTP_301_RESERVATION_GENERATOR` and the variant. In the period values, choose how often it repeats (for example every day).
3. Check the job in **SM37**.

**2 Online** cannot run in a job and stops with an error.

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
| Combination 1: Active, From plant, To plant | Plant the goods leave and plant they go to (finished products) | Active, 8P01 → 8Q01 |
| Combination 2: Active, From plant, To plant | A second pair (raw materials) | Active, 8Q01 → 8P01 |
| Reservation | Limit to some reservations | — |
| Production order | Limit to some orders | — |
| Material | Limit to some materials | — |
| Requirement date | Limit by requirement date | — |
| Only items with unrestricted stock | Hide items with nothing available | not ticked |
| Posting date | Posting date of the 301 | today |

- Combination 1 (8P01 → 8Q01) is for finished products; combination 2 (8Q01 → 8P01) is for raw materials. Both are active by default and the list shows the open reservations of every active combination.
- Untick *Active* to leave a combination out. At least one combination must be active, each active combination needs two different plants, and the two combinations cannot be identical.

### 3.3 The result list

One line per open reservation item. The status light is empty until you post.

| Column | Meaning |
|---|---|
| Reservation, Item | Reservation number and item |
| Prod. order | The production order the goods belong to |
| Material, Description | The material |
| From / To plant, SLoc | Issuing and receiving plant and storage location. **From SLoc** is highlighted and editable (see below) |
| Req. date | Requirement date |
| Req. qty / Withdrawn | Quantity required and already transferred |
| **Open res. qty** | What is still to be transferred |
| **Unrestr. stock** | Unrestricted stock available in the source |
| **Qty to post** (highlighted, editable) | Quantity the report will post. **Default = open reservation quantity**. Quantities are shown with 3 decimals whatever the unit. |
| **Close res.** (checkbox, editable) | Tick it to close the reservation item with this posting, even if quantity is still open (final issue). The remaining open quantity is no longer proposed. |
| UoM | Unit of measure |
| **Batch** (highlighted, editable) | Batch to transfer, for batch-managed materials |
| Mat. doc | The 301 material document, after a successful posting |
| Message | Result or error of the posting |

### 3.4 Posting a transfer

1. Click the **grey selector** at the left of the row(s) you want to post. You can select several rows.
2. Check the **Qty to post**. Change it if you want to transfer less than the open quantity (click the cell, type the new quantity).
3. If the goods are in another storage location than the one proposed, change **From SLoc** (click the cell and type the storage location; leave it empty for the whole plant). For batch-managed materials, enter or change the **Batch**.
4. Tick **Close res.** on a row if the reservation item must be closed with this posting even though quantity is still open (final issue). The quantity to post must still be above zero.
5. Press **Post transfer** in the toolbar.

The program posts **one 301 per selected row**, each independent of the others.

After posting:
- **Green light:** posted. The material document number is shown, and the open quantity and stock on that row are refreshed. The row is deselected. If *Close res.* was ticked, the message ends with *reservation closed (final issue)* and the open quantity is 0.
- **Red light:** not posted. The message says why. Fix the cause and try again.

### 3.5 Rules the program checks

- The quantity must be **greater than zero**.
- The quantity cannot be **more than the open reservation quantity**.
- The quantity cannot be **more than the unrestricted stock** in the source.
- A batch-managed material **needs a batch**; a material that is not batch-managed must not have one.
- The **From SLoc** must exist in the source plant.
- The unrestricted stock is checked for the **storage location and batch you entered** in the grid, not for the ones on the reservation. If the batch has no unrestricted stock in that storage location, the quantity is refused.

You can transfer **less** than the open quantity as many times as you like until the reservation is complete.

### 3.6 Messages you may see and what to do

| Message | What it means / what to do |
|---|---|
| Quantity must be greater than zero | Enter a positive quantity |
| Quantity exceeds open reservation quantity | Lower the quantity, or ask the planner to run the generator if the order quantity was increased |
| Quantity exceeds unrestricted stock … in plant …, storage location …, batch … | Not enough free stock for that storage location and batch; check the *From SLoc* and *Batch* you entered. The goods may also be in quality inspection or blocked |
| Storage location … does not exist in plant … | Correct the *From SLoc* |
| Material … is not batch-managed in plant …: remove the batch | Clear the *Batch* cell |
| Material … is batch-managed: enter a batch | Fill in the Batch column |
| Reservation item is deleted or final-issued | The reservation is no longer usable; run the generator |
| No valuation type mapped for fiscal year …, plant …, material type … | The key user must maintain the valuation types (section 6) |
| Could not determine fiscal year for posting date … | Check the posting date; contact the key user |
| Material not batch-managed in plant … | The batch cannot be created in the destination; contact the key user |
| Source batch … read error / Batch … create error | The batch could not be copied to the destination plant; read the text and contact the key user |
| Other SAP error text (for example posting period closed) | This is SAP's own message. At the end of the text the message class and number are shown in brackets, for example *(M7 509)*; use them to look the message up in SE91 or to report it. Fix the cause or contact support |

Every attempt, successful or not, is stored in the transfer log.

### 3.7 Undoing a transfer

Cancel the 301 material document in **MBST** (movement type 302 is created). The withdrawn quantity of the reservation goes back and the item is open again in the transfer report. To cancel the transfer **and** delete the reservation item, use the reservation manager (section 4).

---

## 4. Reservation manager — `ZPTP_301_MGR`

Use it to cancel reservations that the generator created, for example for an order that will not be transferred any more. It deletes the reservation item, and if a 301 was already posted against it, it reverses that material document first.

### 4.1 What it lists
The program finds the reservation items of the generator in three places, and lists the ones that are **not deleted**:
1. **The reservation log of the generator:** the latest reservation item per order, kind and item.
2. **The transfer log:** every item that was followed by a 301 posting. This still finds the reservations after the generator log has been cleaned.
3. **The reservation table (RESB):** 301 items whose *goods recipient* is the production order number, which is where the generator writes it. This search runs only when you fill at least one of *Reservation*, *Production order* or *Material*, to avoid reading the whole table.

The column *Found via* tells where each item came from. One line per reservation item:

| Column | Meaning |
|---|---|
| Reservation, Item, Prod. order, Kind | The reservation item and the order it belongs to (`H` finished product, `R` raw material) |
| Material, Description, From / To plant | The material and the plants |
| **Open/Closed** | *Closed* when the item is final-issued or the withdrawn quantity covers the required quantity; otherwise *Open* |
| **Followed by 301** | *Yes* when a 301 posting from the transfer report exists for the item and its material document has not been reversed yet; otherwise *No* |
| Res. qty, Withdrawn | Quantity of the reservation and quantity already transferred |
| **301 mvt qty** | Total quantity of the 301 movement(s) not reversed yet |
| Mat. doc, Year | The last 301 material document |
| Found via | *Generator log*, *Transfer log* or *RESB recipient* |
| **Action on POST** | *Delete reservation item* (no movement) or *Reverse 301, then delete* (followed by a movement) |
| Message | Result of the last action |

### 4.2 The selection screen

| Field | Meaning |
|---|---|
| Reservation, Production order, Material | Limit the list |
| Log date | Limit by the date of the log entry written by the generator |
| Posting date of the reversals | Posting date used when a material document is reversed (default: today) |

### 4.3 Deleting reservations
1. Start transaction **`ZPTP_301_MGR`**, set the selection and execute.
2. Click the grey selector at the left of the lines you want to delete. You can select several.
3. Press **Post** (*Delete / reverse*) in the toolbar and confirm the question.

For each selected line the program does the following:
- **No 301 movement:** the reservation item is flagged as deleted.
- **Followed by one or more 301 movements:** each material document is **reversed first** (cancellation with a new material document). Only when all reversals are successful is the item flagged as deleted. Each reversal is written to the transfer log with status *R*.

After the action:
- **Green light:** done. The line shows *Deleted*.
- **Yellow light:** the material documents are reversed but the item could not be deleted. The message says why. Delete the item in MB22 or run the program again.
- **Red light:** nothing was deleted. For a reversal error, the message shows SAP's text with its class and number in brackets. Fix the cause (for example a closed posting period or missing stock to reverse) and try again.

Deleted items no longer appear when you run the program again.

### 4.4 Good to know
- A reservation created by hand in MB21 is only listed if it has a 301 posting in the transfer log, or if you restrict the selection and its goods recipient is a production order number. For items found only through RESB the *Kind* (`H` / `R`) is empty.
- The *Log date* filter applies to the two logs, not to items found through RESB.
- A reversal cancels the **whole** material document. The transfer report posts one item per document, so this matches one reservation item.
- After a deletion, the next generator run creates a new reservation for the open quantity of the order (section 2.4). To stop that, add the order to the exclusion list (section 2.5).
- If you only want to cancel a transfer and keep the reservation, use **MBST** (section 3.7).

---

## 5. Log manager — `ZPTP_301_LOG`

Use it to check the three log tables of the process and to clean them item by item, instead of emptying them completely (option *Clean all logs* of this program).

| Log table | Content |
|---|---|
| `ZPTP_301_RES_LOG` | One row per reservation item and generator run (kind, status, quantities) |
| `ZPTP_301_TRF_LOG` | One row per 301 posting attempt of the transfer report, and per reversal (status *R*) |
| `ZPTP_301_RUN_LOG` | One row per generator run, with its counters |

### 5.1 The selection screen

| Field | Meaning |
|---|---|
| Production order | Limit by order |
| Reservation | Limit by reservation number |
| Run ID | Limit by run (generator run ID, or transfer run ID) |
| Execution date | Limit by the date of the log rows |
| Clean all logs | After a warning that shows the number of rows, deletes **all** rows of the three log tables, whatever the selection, and ends the program without a list. |

### 5.2 The list
One line per reservation item of the logs. The most important columns:

| Column | Meaning |
|---|---|
| **Check** | Green: the logs are consistent. Yellow: a difference to look at. Red: an inconsistency |
| **Kind** (coloured) | `H` finished product (blue-green), `R` raw material (orange) |
| **Last status** (coloured) | Status of the item in its latest generator log row: *Created*, *Realigned*, *Unchanged*, *Complete* (green or yellow), *Closed* (dark grey), *Skipped* (light grey), *Error* (red), *Simulated* |
| RESB state | *Open*, *Closed*, *Deleted* or *Missing*: the real state of the reservation item in SAP |
| Req. qty / Withdrawn (RESB), Req. qty (log) | Quantities in SAP and in the log |
| 301 posted, Last 301 doc | 301 postings of the transfer log that are not reversed |
| **In Run Log**, **In Res Log**, **In TRF Log** (checkboxes) | Whether the record of the item is present in the run log, in the item log and in the transfer log. A reservation record that is missing from a log is a sign of an inconsistency (for example after cleaning a table) |
| Rows item log / transfer log, Runs in run log | How many log rows the item has in each table |
| **Consistency check** | The reason for a yellow or red light |

### 5.3 What the consistency check looks at
- Status *Closed* or *Complete* in the log, but the item is still open in SAP: red.
- The log says the reservation exists, but the item is not in RESB: red. The item is deleted in SAP, the log does not say so: yellow.
- The required quantity of the log differs from SAP (statuses *Realigned* and *Unchanged*): yellow.
- A material document of the transfer log is not found in SAP: red.
- A document is reversed in SAP, but the transfer log has no reversal row: yellow.
- The withdrawn quantity in SAP differs from the 301 postings of the log: yellow.
- A run of the item log is missing in the run log: yellow.

### 5.4 Deleting log records
1. Select the items (grey selector at the left), press **Delete** and confirm the question.
2. For each item the program deletes **all its rows** in the item log and in the transfer log. Then it deletes the rows of the run log of the runs that have **no item row left**.
3. The line shows *Log records deleted*. The deletion cannot be undone.

An item whose reservation still exists and is **followed by a 301 posting that is not reversed** is **blocked**: it cannot be deleted, because the logs would lose the link to the material document. Reverse the posting first with the reservation manager (section 4).

The program never changes reservations or material documents.

**Clean all logs.** The option deletes the three tables completely. The reservation manager then no longer knows which reservations were followed by a 301 posting, so reverse the postings first (section 4). Use the item-by-item deletion above whenever possible.

---

## 6. For the key user: what has to be maintained

Use transaction **SM30** for these tables.

| Table | What to maintain |
|---|---|
| `ZPTP_301_CTRL` | One row for the plant pair 8P01 → 8Q01, with **Active** ticked. It enables the valuation-type logic for the finished-product transfer. |
| `ZPTP_301_LGORT` | The **target storage location** of the **finished-product** reservations (8P01 → 8Q01). Key: direction (`H`), issuing plant, receiving plant, **source storage location** (blank = any) and material type (blank = all). The most specific row wins: first the row for the source storage location, then the row for the material type. Both storage locations must exist in their plant. Raw-material reservations do not use this table (their storage locations come from the batch stock and the production order, see section 2.2). Changing the table does not change reservations that already exist. |
| `ZPTP_301_VALTYPE` | The destination **valuation type** per destination plant, material type and fiscal year. A blank plant or material type means "all". Add the rows for the next fiscal year **before the year starts**, or transfers dated in the new year are refused. Keep a blank-material-type row as a fallback for each year. |

The exclusion list is stored in the table `ZPTP_301_EXCL`; it is filled through the spreadsheet upload and is not normally edited by hand.

**Authorizations.** The reservation manager (`ZPTP_301_MGR`) deletes reservation items and reverses material documents, and the log manager (`ZPTP_301_LOG`) deletes log records. Give these two transactions only to the key user. The generator and the transfer report can be given to the planner and the warehouse.

**Log tables.** The process writes three log tables: `ZPTP_301_RUN_LOG` (one row per generator run), `ZPTP_301_RES_LOG` (one row per reservation item and run) and `ZPTP_301_TRF_LOG` (one row per 301 posting attempt and per reversal). Only the log manager deletes log records. The SAP application log (SLG1) is not used.

---

## 7. Quick reference

### Daily routine
1. `ZPTP_301_RES`, mode **1 Test**. Check the result.
2. `ZPTP_301_RES`, mode **3 Background** (all) or **2 Online** (selected orders). Reservations are up to date.
3. `ZPTP_301_TRF`. Select the items you move today, confirm quantities, **Post transfer**.
4. If a reservation must be cancelled: `ZPTP_301_MGR`, select the items, **Post**.

### Where to check things

| What | Where |
|---|---|
| A reservation | **MB23** (display), **MB25** (list; order number in *goods recipient*) |
| A transfer material document | **MB03** |
| Cancel a transfer | **MBST** |
| Close a reservation by hand | **MB22** |
| Delete a generator reservation (and reverse its 301) | `ZPTP_301_MGR` |
| Check or clean the log tables | `ZPTP_301_LOG` |
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
Check that *Reservation kind* is `R` or `A`, that the component is a stock item and really short in 8P01, and that the order is not excluded or part of a collective order at a higher level.

**I deleted a reservation but it came back.**
The next generator run creates a new reservation for the open quantity of the order. Add the order to the exclusion list (section 2.5) if it must not get one.

**Can I transfer more than the reservation?**
No. The quantity is limited to the open reservation quantity. Ask the planner to correct the order or the reservation.
