*&---------------------------------------------------------------------*
*& Report  ZMM_R_CREATE_301_RESERV   (txn ZMM301R)
*&---------------------------------------------------------------------*
*& R-xxx-SEG (FS-MM-301RES-001) : Create / align 301 transfer reservations
*&   for open production orders (origin plant -> destination plant)
*&
*& Migration 8P01 -> 8Q01. Reservation remaining (BDMNG - ENMNG) is kept
*& equal to PO remaining (PSMNG - WEMNG). The physical 301 movements that
*& consume the reservation are posted by the companion object
*& E-xxx-SEG (FS-MM-301MOV-001), NOT by this program.
*&
*& NOTE: BAPI field names for the reservation change/close path should be
*&       verified against the target release (see FS open item O4).
*&---------------------------------------------------------------------*
REPORT zmm_r_create_301_reserv.

TABLES sscrfields.

*---------------------------------------------------------------------*
* Selection screen
*---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001. " Plants / locations
PARAMETERS: p_werk_fr TYPE werks_d OBLIGATORY DEFAULT '8P01', " origin plant
            p_lgor_fr TYPE lgort_d,                            " origin stor.loc
            p_werk_to TYPE werks_d OBLIGATORY DEFAULT '8Q01', " destination plant
            p_lgor_to TYPE lgort_d.                            " destination stor.loc
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002. " Order selection
SELECT-OPTIONS: so_aufnr FOR   ('AUFNR'),
                so_auart FOR   ('AUFART'),
                so_matnr FOR   ('MATNR'),
                so_dispo FOR   ('DISPO').
PARAMETERS:     p_rsdat  TYPE rsdat DEFAULT sy-datum OBLIGATORY. " requirement date
SELECTION-SCREEN END OF BLOCK b2.

SELECTION-SCREEN BEGIN OF BLOCK b3 WITH FRAME TITLE TEXT-003. " Run control
PARAMETERS: p_move  AS CHECKBOX DEFAULT 'X',                   " movement-relevant
            p_test  AS CHECKBOX DEFAULT 'X',                   " test / simulate
            p_erron AS CHECKBOX.                               " reprocess errors only
SELECTION-SCREEN END OF BLOCK b3.

SELECTION-SCREEN BEGIN OF BLOCK b4 WITH FRAME TITLE TEXT-004. " Scheduling
PARAMETERS: p_sched AS CHECKBOX USER-COMMAND sch,              " self-reschedule
            p_freq  TYPE i DEFAULT 5 MODIF ID sch,             " frequency value
            p_funit TYPE c LENGTH 3 DEFAULT 'MIN'              " MIN / HRS / DAY
                    AS LISTBOX VISIBLE LENGTH 6 MODIF ID sch.
SELECTION-SCREEN END OF BLOCK b4.

*---------------------------------------------------------------------*
* Global constants
*---------------------------------------------------------------------*
CONSTANTS: gc_mvt_301 TYPE bwart VALUE '301',
           " system status codes (verify against the plant status profile)
           gc_stat_rel  TYPE j_status VALUE 'I0002', " REL
           gc_stat_teco TYPE j_status VALUE 'I0045', " TECO
           gc_stat_clsd TYPE j_status VALUE 'I0046', " CLSD
           gc_stat_dlfl TYPE j_status VALUE 'I0076', " DLFL deletion flag
           gc_stat_dlt  TYPE j_status VALUE 'I0013', " DLT  deletion indicator
           " result status (ZMM_301_RESV_LOG-STATUS)
           gc_created   TYPE c VALUE 'C',
           gc_realigned TYPE c VALUE 'R',
           gc_closed    TYPE c VALUE 'X',
           gc_unchanged TYPE c VALUE 'N',
           gc_complete  TYPE c VALUE 'F',
           gc_skipped   TYPE c VALUE 'K',            " fully received
           gc_error     TYPE c VALUE 'E',
           gc_simulated TYPE c VALUE 'S',
           gc_freq_min  TYPE i VALUE 60,          " 1 minute floor (seconds)
           gc_freq_max  TYPE i VALUE 2592000.     " 30 days ceiling (seconds)

*---------------------------------------------------------------------*
* Local class : application engine
*---------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.

  PUBLIC SECTION.
    TYPES: BEGIN OF ty_out,
             aufnr        TYPE aufnr,
             posnr        TYPE co_posnr,
             auart        TYPE aufart,
             matnr        TYPE matnr,
             psmng        TYPE psmng,
             wemng        TYPE wemng,
             po_open      TYPE menge_d,
             res_bdmng    TYPE menge_d,
             res_enmng    TYPE menge_d,
             target_bdmng TYPE menge_d,
             drift        TYPE menge_d,
             meins        TYPE meins,
             werks_fr     TYPE werks_d,
             werks_to     TYPE werks_d,
             rsnum        TYPE rsnum,
             rspos        TYPE rspos,
             light        TYPE c LENGTH 1,     " 3 green / 2 yellow / 1 red
             status       TYPE c LENGTH 1,
             statxt       TYPE string,
             message      TYPE string,
           END OF ty_out.
    TYPES tt_out TYPE STANDARD TABLE OF ty_out WITH DEFAULT KEY.

    CLASS-METHODS validate_selection.
    CLASS-METHODS interval_in_seconds RETURNING VALUE(rv_secs) TYPE i.
    METHODS constructor.
    METHODS run.

  PRIVATE SECTION.
    TYPES: BEGIN OF ty_ord,
             aufnr    TYPE aufnr,
             auart    TYPE aufart,
             objnr    TYPE j_objnr,
             posnr    TYPE co_posnr,
             matnr    TYPE matnr,
             psmng    TYPE psmng,
             wemng    TYPE wemng,
             meins    TYPE meins,
             elikz    TYPE elikz,
             dispo    TYPE dispo,
             to_close TYPE abap_bool,     " TECO/CLSD/DLFL or delivered -> close
           END OF ty_ord.
    TYPES tt_ord TYPE STANDARD TABLE OF ty_ord WITH DEFAULT KEY.

    DATA: mt_out    TYPE tt_out,
          mv_run_id TYPE sysuuid_c32,
          mv_mode   TYPE c LENGTH 1,    " O / B
          mv_handle TYPE balloghndl,
          ms_counts TYPE zmm_301_run_log.

    METHODS select_open_orders
      RETURNING VALUE(rt_orders) TYPE tt_ord.
    METHODS process_order
      IMPORTING is_order TYPE ty_ord.
    METHODS is_authorised
      IMPORTING iv_actvt     TYPE activ_auth
      RETURNING VALUE(rv_ok) TYPE abap_bool.
    METHODS create_reservation
      CHANGING  cs_out   TYPE ty_out.
    METHODS change_reservation
      IMPORTING iv_close TYPE abap_bool
      CHANGING  cs_out   TYPE ty_out.
    METHODS start_run_log.
    METHODS finish_run_log IMPORTING iv_status TYPE c.
    METHODS write_detail_log IMPORTING is_out TYPE ty_out.
    METHODS bal_add IMPORTING iv_msgty TYPE symsgty iv_text TYPE csequence.
    METHODS display_alv.
    METHODS on_link_click FOR EVENT link_click OF cl_salv_events_table
      IMPORTING row column.
    METHODS schedule_next_run.
    METHODS is_automation_active RETURNING VALUE(rv_active) TYPE abap_bool.

ENDCLASS.

*---------------------------------------------------------------------*
CLASS lcl_app IMPLEMENTATION.

  METHOD constructor.
    " unique run id
    TRY.
        mv_run_id = cl_system_uuid=>create_uuid_c32_static( ).
      CATCH cx_uuid_error.
        mv_run_id = |{ sy-datum }{ sy-uzeit }{ sy-index }|.
    ENDTRY.
    mv_mode = COND #( WHEN sy-batch = abap_true THEN 'B' ELSE 'O' ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD run.
    start_run_log( ).

    DATA(lt_orders) = select_open_orders( ).
    ms_counts-cnt_selected = lines( lt_orders ).

    IF lt_orders IS INITIAL.
      MESSAGE s002(zmm301).
    ENDIF.

    LOOP AT lt_orders ASSIGNING FIELD-SYMBOL(<order>).
      process_order( <order> ).
    ENDLOOP.

    " roll-up counters from result table
    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<o>).
      CASE <o>-status.
        WHEN gc_created.   ms_counts-cnt_created   = ms_counts-cnt_created   + 1.
        WHEN gc_realigned. ms_counts-cnt_realigned = ms_counts-cnt_realigned + 1.
        WHEN gc_closed.    ms_counts-cnt_closed    = ms_counts-cnt_closed    + 1.
        WHEN gc_unchanged OR gc_complete.
                           ms_counts-cnt_unchanged = ms_counts-cnt_unchanged + 1.
        WHEN gc_skipped.   ms_counts-cnt_skipped   = ms_counts-cnt_skipped   + 1.
        WHEN gc_error.     ms_counts-cnt_error     = ms_counts-cnt_error     + 1.
      ENDCASE.
      IF <o>-drift > 0.
        ms_counts-cnt_drift = ms_counts-cnt_drift + 1.
      ENDIF.
    ENDLOOP.

    DATA(lv_final) = COND c( WHEN ms_counts-cnt_error > 0 THEN 'W' ELSE 'S' ).

    " self-rescheduling chain (background, live or test) - scheduled before
    " the run log is closed so that NEXT_RUN_DT/TM are written with it
    IF p_sched = abap_true.
      IF is_automation_active( ) = abap_true.
        schedule_next_run( ).
      ELSE.
        MESSAGE s012(zmm301) INTO DATA(lv_stop).      " chain stopped
        ms_counts-message = lv_stop.
        bal_add( iv_msgty = 'W' iv_text = lv_stop ).
      ENDIF.
    ENDIF.

    finish_run_log( lv_final ).

    IF mv_mode = 'O'.
      display_alv( ).
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD validate_selection.
    IF p_werk_fr = p_werk_to.
      MESSAGE e001(zmm301) WITH p_werk_fr p_werk_to.
    ENDIF.
    " plant existence + same company code (T001W -> T001K)
    SELECT SINGLE bwkey FROM t001w INTO @DATA(lv_bwk_fr) WHERE werks = @p_werk_fr.
    IF sy-subrc <> 0. MESSAGE e014(zmm301) WITH p_werk_fr. ENDIF.
    SELECT SINGLE bwkey FROM t001w INTO @DATA(lv_bwk_to) WHERE werks = @p_werk_to.
    IF sy-subrc <> 0. MESSAGE e014(zmm301) WITH p_werk_to. ENDIF.
    SELECT SINGLE bukrs FROM t001k INTO @DATA(lv_bukrs_fr) WHERE bwkey = @lv_bwk_fr.
    SELECT SINGLE bukrs FROM t001k INTO @DATA(lv_bukrs_to) WHERE bwkey = @lv_bwk_to.
    IF lv_bukrs_fr <> lv_bukrs_to.
      MESSAGE e016(zmm301) WITH p_werk_fr p_werk_to.
    ENDIF.
    " storage location existence (only if entered)
    IF p_lgor_fr IS NOT INITIAL.
      SELECT SINGLE lgort FROM t001l INTO @DATA(lv_l)
        WHERE werks = @p_werk_fr AND lgort = @p_lgor_fr.
      IF sy-subrc <> 0. MESSAGE e015(zmm301) WITH p_lgor_fr p_werk_fr. ENDIF.
    ENDIF.
    IF p_lgor_to IS NOT INITIAL.
      SELECT SINGLE lgort FROM t001l INTO @lv_l
        WHERE werks = @p_werk_to AND lgort = @p_lgor_to.
      IF sy-subrc <> 0. MESSAGE e015(zmm301) WITH p_lgor_to p_werk_to. ENDIF.
    ENDIF.
    " requirement date in the past -> warning only
    IF p_rsdat < sy-datum AND sy-batch = abap_false.
      MESSAGE w019(zmm301) WITH p_rsdat.
    ENDIF.
    " frequency floor / ceiling (only relevant with self-reschedule)
    IF p_sched = abap_true.
      DATA(lv_secs) = interval_in_seconds( ).
      IF lv_secs < gc_freq_min. MESSAGE e010(zmm301). ENDIF.
      IF lv_secs > gc_freq_max. MESSAGE e011(zmm301). ENDIF.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD interval_in_seconds.
    CASE p_funit.
      WHEN 'MIN'. rv_secs = p_freq * 60.
      WHEN 'HRS'. rv_secs = p_freq * 3600.
      WHEN 'DAY'. rv_secs = p_freq * 86400.
      WHEN OTHERS. rv_secs = p_freq * 60.
    ENDCASE.
  ENDMETHOD.

*---------------------------------------------------------------------*
* select_open_orders
*  (a) open orders: delivery not completed (AFPO-ELIKZ = space)
*  (b) delivered orders (ELIKZ set) that still hold an OPEN 301
*      reservation (BDMNG > ENMNG) -> must be closed, else they would
*      never be selected again and leave phantom demand in 8Q01
*  Status: REL required for (a); TECO/CLSD/DLFL/DLT -> close flag.
*---------------------------------------------------------------------*
  METHOD select_open_orders.
    DATA lt_ord TYPE tt_ord.

    " (a) open orders
    SELECT k~aufnr, k~auart, k~objnr,
           p~posnr, p~matnr, p~psmng, p~wemng, p~meins, p~elikz,
           f~dispo
      FROM aufk AS k
      INNER JOIN afko AS f ON f~aufnr = k~aufnr
      INNER JOIN afpo AS p ON p~aufnr = k~aufnr
      WHERE k~werks   = @p_werk_fr
        AND k~aufnr  IN @so_aufnr
        AND k~auart  IN @so_auart
        AND p~matnr  IN @so_matnr
        AND f~dispo  IN @so_dispo
        AND p~elikz   = @space
      INTO CORRESPONDING FIELDS OF TABLE @lt_ord.

    " (b) delivered orders still holding an open 301 reservation
    SELECT DISTINCT k~aufnr, k~auart, k~objnr,
           p~posnr, p~matnr, p~psmng, p~wemng, p~meins, p~elikz,
           f~dispo
      FROM aufk AS k
      INNER JOIN afko AS f ON f~aufnr = k~aufnr
      INNER JOIN afpo AS p ON p~aufnr = k~aufnr
      INNER JOIN zmm_301_resv_log AS l ON l~aufnr = p~aufnr AND l~posnr = p~posnr
      INNER JOIN resb AS r ON r~rsnum = l~rsnum AND r~rspos = l~rspos
      WHERE k~werks   = @p_werk_fr
        AND k~aufnr  IN @so_aufnr
        AND k~auart  IN @so_auart
        AND p~matnr  IN @so_matnr
        AND f~dispo  IN @so_dispo
        AND p~elikz  <> @space
        AND r~bdmng   > r~enmng
        AND r~xloek   = @space
      APPENDING CORRESPONDING FIELDS OF TABLE @lt_ord.

    IF lt_ord IS INITIAL.
      RETURN.
    ENDIF.

    " bulk status read
    DATA lt_objnr TYPE STANDARD TABLE OF j_objnr WITH EMPTY KEY.
    lt_objnr = VALUE #( FOR l IN lt_ord ( l-objnr ) ).
    SORT lt_objnr. DELETE ADJACENT DUPLICATES FROM lt_objnr.

    TYPES: BEGIN OF ty_jest, objnr TYPE j_objnr, stat TYPE j_status, END OF ty_jest.
    DATA lt_jest TYPE HASHED TABLE OF ty_jest WITH UNIQUE KEY objnr stat.
    SELECT objnr, stat FROM jest
      FOR ALL ENTRIES IN @lt_objnr
      WHERE objnr = @lt_objnr-table_line
        AND inact = @space
      INTO TABLE @lt_jest.

    LOOP AT lt_ord ASSIGNING FIELD-SYMBOL(<ord>).
      DATA(lv_rel)  = xsdbool( line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_rel  ] ) ).
      DATA(lv_stop) = xsdbool(
             line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_teco ] )
          OR line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_clsd ] )
          OR line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_dlfl ] )
          OR line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_dlt  ] ) ).

      <ord>-to_close = xsdbool( lv_stop = abap_true OR <ord>-elikz IS NOT INITIAL ).

      " not released and nothing to close -> ignore
      IF lv_rel = abap_false AND <ord>-to_close = abap_false.
        DELETE lt_ord.
      ENDIF.
    ENDLOOP.

    rt_orders = lt_ord.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD process_order.
    DATA(lv_po_open) = CONV menge_d( is_order-psmng - is_order-wemng ).

    DATA(ls_out) = VALUE ty_out( aufnr    = is_order-aufnr
                                 posnr    = is_order-posnr
                                 auart    = is_order-auart
                                 matnr    = is_order-matnr
                                 psmng    = is_order-psmng
                                 wemng    = is_order-wemng
                                 po_open  = lv_po_open
                                 meins    = is_order-meins
                                 werks_fr = p_werk_fr
                                 werks_to = p_werk_to ).

    " existing reservation: LATEST link row for the order item + RESB.
    " (SELECT SINGLE does not allow ORDER BY -> UP TO 1 ROWS)
    SELECT rsnum, rspos, status FROM zmm_301_resv_log
      WHERE aufnr = @is_order-aufnr AND posnr = @is_order-posnr
        AND rsnum <> @space
      ORDER BY erdat DESCENDING, erzet DESCENDING
      INTO TABLE @DATA(lt_link) UP TO 1 ROWS.

    DATA lv_has_res TYPE abap_bool.
    IF lt_link IS NOT INITIAL.
      DATA(ls_link) = lt_link[ 1 ].
      SELECT SINGLE bdmng, enmng FROM resb
        INTO @DATA(ls_resb)
        WHERE rsnum = @ls_link-rsnum AND rspos = @ls_link-rspos
          AND xloek = @space.
      IF sy-subrc = 0.
        lv_has_res       = abap_true.
        ls_out-rsnum     = ls_link-rsnum.
        ls_out-rspos     = ls_link-rspos.
        ls_out-res_bdmng = ls_resb-bdmng.
        ls_out-res_enmng = ls_resb-enmng.
      ENDIF.
    ENDIF.

    " orders to be closed but with no (open) reservation: nothing to do,
    " not logged (avoids one log row per run for every finished order)
    IF is_order-to_close = abap_true
       AND ( lv_has_res = abap_false OR ls_out-res_bdmng = ls_out-res_enmng ).
      RETURN.
    ENDIF.

    " reprocess-errors-only filter: latest detail-log status must be Error
    IF p_erron = abap_true.
      SELECT status FROM zmm_301_resv_log
        WHERE aufnr = @is_order-aufnr AND posnr = @is_order-posnr
        ORDER BY erdat DESCENDING, erzet DESCENDING
        INTO TABLE @DATA(lt_last) UP TO 1 ROWS.
      IF lt_last IS INITIAL OR lt_last[ 1 ]-status <> gc_error.
        RETURN.
      ENDIF.
    ENDIF.

    " target requirement qty : reservation open must equal PO open
    DATA(lv_target) = CONV menge_d( lv_po_open + ls_out-res_enmng ).
    ls_out-target_bdmng = lv_target.

    " drift indicator (received in origin but not transferred)
    IF lv_has_res = abap_true AND is_order-wemng - ls_out-res_enmng > 0.
      ls_out-drift = is_order-wemng - ls_out-res_enmng.
    ENDIF.

    " ---------------- decision matrix ----------------
    IF lv_has_res = abap_false.
      IF lv_po_open <= 0.
        ls_out-status  = gc_skipped.
        ls_out-statxt  = 'Fully received'.
        MESSAGE i004(zmm301) WITH is_order-aufnr INTO ls_out-message.
      ELSE.
        create_reservation( CHANGING cs_out = ls_out ).
      ENDIF.
    ELSE.
      IF is_order-to_close = abap_true OR lv_po_open <= 0.
        " order complete/TECO/delivered -> close (BDMNG = ENMNG) if not already
        IF ls_out-res_bdmng = ls_out-res_enmng.
          ls_out-status = gc_complete.
          ls_out-statxt = 'Complete'.
        ELSE.
          change_reservation( EXPORTING iv_close = abap_true CHANGING cs_out = ls_out ).
        ENDIF.
      ELSEIF lv_target <> ls_out-res_bdmng.
        change_reservation( EXPORTING iv_close = abap_false CHANGING cs_out = ls_out ).
      ELSE.
        ls_out-status = gc_unchanged.
        ls_out-statxt = 'Unchanged'.
        MESSAGE s008(zmm301) WITH is_order-aufnr ls_out-rsnum INTO ls_out-message.
      ENDIF.
    ENDIF.

    IF ls_out-drift > 0.
      MESSAGE w017(zmm301) WITH is_order-aufnr is_order-wemng ls_out-res_enmng INTO DATA(lv_drift).
      bal_add( iv_msgty = 'W' iv_text = lv_drift ).
    ENDIF.
    bal_add( iv_msgty = SWITCH #( ls_out-status WHEN gc_error THEN 'E' ELSE 'S' )
             iv_text  = |{ is_order-aufnr }: { ls_out-statxt } { ls_out-message }| ).

    ls_out-light = SWITCH #( ls_out-status
                     WHEN gc_error THEN '1'
                     WHEN gc_simulated THEN '2'
                     ELSE COND #( WHEN ls_out-drift > 0 THEN '2' ELSE '3' ) ).
    APPEND ls_out TO mt_out.
    write_detail_log( ls_out ).
  ENDMETHOD.

*---------------------------------------------------------------------*
* is_authorised : reservation authorisations for both plants + mvt type
*   M_MRES_WWA (reservations: plant)         ACTVT / WERKS
*   M_MRES_BWA (reservations: movement type) ACTVT / BWART
*   *** verify object/field names in SU21 of the target release ***
*---------------------------------------------------------------------*
  METHOD is_authorised.
    rv_ok = abap_true.
    AUTHORITY-CHECK OBJECT 'M_MRES_WWA'
      ID 'ACTVT' FIELD iv_actvt ID 'WERKS' FIELD p_werk_fr.
    IF sy-subrc <> 0. rv_ok = abap_false. RETURN. ENDIF.
    AUTHORITY-CHECK OBJECT 'M_MRES_WWA'
      ID 'ACTVT' FIELD iv_actvt ID 'WERKS' FIELD p_werk_to.
    IF sy-subrc <> 0. rv_ok = abap_false. RETURN. ENDIF.
    AUTHORITY-CHECK OBJECT 'M_MRES_BWA'
      ID 'ACTVT' FIELD iv_actvt ID 'BWART' FIELD gc_mvt_301.
    IF sy-subrc <> 0. rv_ok = abap_false. ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD create_reservation.
    " material must exist in the destination plant
    SELECT SINGLE matnr FROM marc INTO @DATA(lv_m)
      WHERE matnr = @cs_out-matnr AND werks = @p_werk_to.
    IF sy-subrc <> 0.
      cs_out-status = gc_error.
      cs_out-statxt = 'Create error'.
      MESSAGE e003(zmm301) WITH cs_out-matnr p_werk_to INTO cs_out-message.
      RETURN.
    ENDIF.

    IF p_test = abap_true.
      cs_out-status = gc_simulated.
      cs_out-statxt = 'Simulated (create)'.
      RETURN.
    ENDIF.

    IF is_authorised( '01' ) = abap_false.
      cs_out-status = gc_error.
      cs_out-statxt = 'Not authorised'.
      MESSAGE e018(zmm301) WITH cs_out-aufnr p_werk_fr p_werk_to gc_mvt_301 INTO cs_out-message.
      RETURN.
    ENDIF.

    DATA: ls_head   TYPE bapi2093_res_head_c1,
          lt_items  TYPE STANDARD TABLE OF bapi2093_res_item_c1,
          ls_item   TYPE bapi2093_res_item_c1,
          lt_return TYPE STANDARD TABLE OF bapiret2,
          lv_resno  TYPE rsnum.

    ls_head-res_date = p_rsdat.
    ls_head-movement = p_move.

    ls_item-material_long = cs_out-matnr.
    ls_item-plant         = p_werk_fr.
    ls_item-stge_loc      = p_lgor_fr.
    ls_item-move_type     = gc_mvt_301.
    ls_item-entry_qnt     = cs_out-po_open.      " initial ENMNG = 0
    ls_item-entry_uom     = cs_out-meins.
    ls_item-req_date      = p_rsdat.
    ls_item-move_plant    = p_werk_to.
    ls_item-move_stloc    = p_lgor_to.
    ls_item-item_text     = |PO { cs_out-aufnr }|.   " order ref. (SGTXT) *** verify field name ***
    APPEND ls_item TO lt_items.

    CALL FUNCTION 'BAPI_RESERVATION_CREATE1'
      EXPORTING
        reservationheader = ls_head
      IMPORTING
        reservation       = lv_resno
      TABLES
        reservationitems  = lt_items
        return            = lt_return.

    IF line_exists( lt_return[ type = 'E' ] ) OR line_exists( lt_return[ type = 'A' ] )
       OR lv_resno IS INITIAL.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      cs_out-status  = gc_error.
      cs_out-statxt  = 'Create error'.
      cs_out-message = VALUE #( lt_return[ type = 'E' ]-message
                                DEFAULT VALUE #( lt_return[ type = 'A' ]-message OPTIONAL ) ).
    ELSE.
      DATA ls_commit TYPE bapiret2.
      CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X' IMPORTING return = ls_commit.
      IF ls_commit-type = 'E' OR ls_commit-type = 'A'.
        cs_out-status = gc_error.
        cs_out-statxt = 'Commit error'.
        MESSAGE e029(zmm301) WITH cs_out-aufnr INTO cs_out-message.
        RETURN.
      ENDIF.
      cs_out-rsnum     = lv_resno.
      cs_out-rspos     = '0001'.                   " one item per reservation
      cs_out-res_bdmng = cs_out-po_open.
      cs_out-status    = gc_created.
      cs_out-statxt    = 'Created'.
      MESSAGE s005(zmm301) WITH cs_out-aufnr lv_resno INTO cs_out-message.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD change_reservation.
    " Realign (BDMNG = target) or close (BDMNG = ENMNG).
    " NOTE: verify BAPI_RESERVATION_CHANGE item/itemX field names for the
    "       target release (FS open item O4). MB22 FM/BDC is the fallback.
    DATA(lv_newqty) = COND menge_d(
        WHEN iv_close = abap_true THEN cs_out-res_enmng
        ELSE cs_out-target_bdmng ).
    " guard: never below the quantity already transferred
    IF lv_newqty < cs_out-res_enmng.
      lv_newqty = cs_out-res_enmng.
    ENDIF.

    IF p_test = abap_true.
      cs_out-status = gc_simulated.
      cs_out-statxt = COND #( WHEN iv_close = abap_true
                              THEN 'Simulated (close)' ELSE 'Simulated (realign)' ).
      RETURN.
    ENDIF.

    IF is_authorised( '02' ) = abap_false.
      cs_out-status = gc_error.
      cs_out-statxt = 'Not authorised'.
      MESSAGE e018(zmm301) WITH cs_out-aufnr p_werk_fr p_werk_to gc_mvt_301 INTO cs_out-message.
      RETURN.
    ENDIF.

    DATA: lt_items  TYPE STANDARD TABLE OF bapi2093_res_item_c,
          lt_itemsx TYPE STANDARD TABLE OF bapi2093_res_item_cx,
          lt_return TYPE STANDARD TABLE OF bapiret2,
          ls_i      TYPE bapi2093_res_item_c,
          ls_ix     TYPE bapi2093_res_item_cx.

    ls_i-res_item  = cs_out-rspos.
    ls_i-entry_qnt = lv_newqty.
    APPEND ls_i TO lt_items.

    ls_ix-res_item  = cs_out-rspos.
    ls_ix-entry_qnt = 'X'.
    APPEND ls_ix TO lt_itemsx.

    CALL FUNCTION 'BAPI_RESERVATION_CHANGE'
      EXPORTING
        reservation       = cs_out-rsnum
      TABLES
        reservationitems  = lt_items
        reservationitemsx = lt_itemsx
        return            = lt_return.

    IF line_exists( lt_return[ type = 'E' ] ) OR line_exists( lt_return[ type = 'A' ] ).
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      cs_out-status  = gc_error.
      cs_out-statxt  = 'Change error'.
      cs_out-message = VALUE #( lt_return[ type = 'E' ]-message
                                DEFAULT VALUE #( lt_return[ type = 'A' ]-message OPTIONAL ) ).
    ELSE.
      DATA ls_commit TYPE bapiret2.
      CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X' IMPORTING return = ls_commit.
      IF ls_commit-type = 'E' OR ls_commit-type = 'A'.
        cs_out-status = gc_error.
        cs_out-statxt = 'Commit error'.
        MESSAGE e029(zmm301) WITH cs_out-aufnr INTO cs_out-message.
        RETURN.
      ENDIF.
      IF iv_close = abap_true.
        cs_out-status = gc_closed.
        cs_out-statxt = 'Closed'.
        MESSAGE s007(zmm301) WITH cs_out-aufnr cs_out-rsnum INTO cs_out-message.
      ELSE.
        cs_out-status = gc_realigned.
        cs_out-statxt = 'Realigned'.
        MESSAGE s006(zmm301) WITH cs_out-aufnr cs_out-rsnum lv_newqty INTO cs_out-message.
      ENDIF.
      cs_out-res_bdmng = lv_newqty.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD start_run_log.
    ms_counts = VALUE #( run_id     = mv_run_id
                         run_mode   = mv_mode
                         variant    = sy-slset
                         werks_fr   = p_werk_fr
                         werks_to   = p_werk_to
                         test_run   = p_test
                         self_sched = p_sched
                         freq_value = p_freq
                         freq_unit  = p_funit
                         start_date = sy-datum
                         start_time = sy-uzeit
                         status     = 'R'
                         ernam      = sy-uname
                         sel_text   = |FR { p_werk_fr } TO { p_werk_to } DATE { p_rsdat }| ).
    IF mv_mode = 'B'.
      CALL FUNCTION 'GET_JOB_RUNTIME_INFO'
        IMPORTING  jobname  = ms_counts-jobname
                   jobcount = ms_counts-jobcount
        EXCEPTIONS OTHERS   = 1.
      " application log for background runs (ZMM / Z301RES)
      DATA(ls_bal) = VALUE bal_s_log( object    = 'ZMM'
                                      subobject = 'Z301RES'
                                      extnumber = |ZMM301R { mv_run_id }|
                                      aldate    = sy-datum
                                      altime    = sy-uzeit
                                      aluser    = sy-uname ).
      CALL FUNCTION 'BAL_LOG_CREATE'
        EXPORTING  i_s_log      = ls_bal
        IMPORTING  e_log_handle = mv_handle
        EXCEPTIONS OTHERS       = 1.
      IF sy-subrc <> 0. CLEAR mv_handle. ENDIF.
    ENDIF.
    MODIFY zmm_301_run_log FROM @ms_counts.
    COMMIT WORK.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD finish_run_log.
    ms_counts-end_date = sy-datum.
    ms_counts-end_time = sy-uzeit.
    ms_counts-status   = iv_status.
    " duration
    DATA: lv_ts1 TYPE timestamp, lv_ts2 TYPE timestamp.
    CONVERT DATE ms_counts-start_date TIME ms_counts-start_time
            INTO TIME STAMP lv_ts1 TIME ZONE sy-zonlo.
    CONVERT DATE ms_counts-end_date TIME ms_counts-end_time
            INTO TIME STAMP lv_ts2 TIME ZONE sy-zonlo.
    ms_counts-duration_s = cl_abap_tstmp=>subtract( tstmp1 = lv_ts2 tstmp2 = lv_ts1 ).

    " save the application log (background) and keep its number
    IF mv_handle IS NOT INITIAL.
      bal_add( iv_msgty = COND #( WHEN iv_status = 'W' THEN 'W' ELSE 'S' )
               iv_text  = |Selected { ms_counts-cnt_selected } created { ms_counts-cnt_created } | &&
                          |realigned { ms_counts-cnt_realigned } closed { ms_counts-cnt_closed } | &&
                          |drift { ms_counts-cnt_drift } errors { ms_counts-cnt_error }| ).
      DATA: lt_h TYPE bal_t_logh, lt_nr TYPE bal_t_lgnm.
      INSERT mv_handle INTO TABLE lt_h.
      CALL FUNCTION 'BAL_DB_SAVE'
        EXPORTING  i_t_log_handle   = lt_h
        IMPORTING  e_new_lognumbers = lt_nr
        EXCEPTIONS OTHERS           = 1.
      IF sy-subrc = 0 AND lt_nr IS NOT INITIAL.
        ms_counts-ballognr = lt_nr[ 1 ]-lognumber.
      ENDIF.
      " spool summary for the job log
      WRITE: / 'Run', mv_run_id, 'status', iv_status,
             / 'Selected', ms_counts-cnt_selected, 'Created', ms_counts-cnt_created,
               'Realigned', ms_counts-cnt_realigned, 'Closed', ms_counts-cnt_closed,
             / 'Unchanged', ms_counts-cnt_unchanged, 'Skipped', ms_counts-cnt_skipped,
               'Drift', ms_counts-cnt_drift, 'Errors', ms_counts-cnt_error.
    ENDIF.

    MODIFY zmm_301_run_log FROM @ms_counts.
    COMMIT WORK.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD write_detail_log.
    DATA ls_log TYPE zmm_301_resv_log.
    ls_log = VALUE #( aufnr     = is_out-aufnr
                      posnr     = is_out-posnr
                      run_id    = mv_run_id
                      rsnum     = is_out-rsnum
                      rspos     = is_out-rspos
                      werks_fr  = is_out-werks_fr
                      werks_to  = is_out-werks_to
                      matnr     = is_out-matnr
                      po_open   = is_out-po_open
                      res_bdmng = is_out-res_bdmng
                      res_enmng = is_out-res_enmng
                      meins     = is_out-meins
                      status    = is_out-status
                      message   = is_out-message
                      erdat     = sy-datum
                      erzet     = sy-uzeit
                      ernam     = sy-uname ).
    MODIFY zmm_301_resv_log FROM @ls_log.
    COMMIT WORK.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD bal_add.
    CHECK mv_handle IS NOT INITIAL.
    DATA lv_text TYPE c LENGTH 200.
    lv_text = iv_text.
    CALL FUNCTION 'BAL_LOG_MSG_ADD_FREE_TEXT'
      EXPORTING  i_log_handle = mv_handle
                 i_msgty      = iv_msgty
                 i_text       = lv_text
      EXCEPTIONS OTHERS       = 1.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD display_alv.
    DATA lo_alv TYPE REF TO cl_salv_table.
    TRY.
        cl_salv_table=>factory(
          IMPORTING r_salv_table = lo_alv
          CHANGING  t_table      = mt_out ).
        lo_alv->get_functions( )->set_all( abap_true ).
        DATA(lo_cols) = lo_alv->get_columns( ).
        lo_cols->set_optimize( abap_true ).
        " traffic light from status, hotspots AUFNR -> CO03, RSNUM -> MB23
        lo_cols->set_exception_column( 'LIGHT' ).
        CAST cl_salv_column_table( lo_cols->get_column( 'AUFNR' ) )->set_cell_type( if_salv_c_cell_type=>hotspot ).
        CAST cl_salv_column_table( lo_cols->get_column( 'RSNUM' ) )->set_cell_type( if_salv_c_cell_type=>hotspot ).
        " totals on the quantity columns
        DATA(lo_aggr) = lo_alv->get_aggregations( ).
        lo_aggr->add_aggregation( 'PO_OPEN' ).
        lo_aggr->add_aggregation( 'DRIFT' ).
        SET HANDLER on_link_click FOR lo_alv->get_event( ).
        lo_alv->display( ).
      CATCH cx_salv_msg cx_salv_not_found cx_salv_data_error cx_salv_existing INTO DATA(lx).
        MESSAGE lx->get_text( ) TYPE 'I'.
    ENDTRY.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD on_link_click.
    READ TABLE mt_out INDEX row ASSIGNING FIELD-SYMBOL(<r>).
    CHECK sy-subrc = 0.
    CASE column.
      WHEN 'AUFNR'.
        SET PARAMETER ID 'ANR' FIELD <r>-aufnr.
        CALL TRANSACTION 'CO03' WITH AUTHORITY-CHECK AND SKIP FIRST SCREEN.
      WHEN 'RSNUM'.
        CHECK <r>-rsnum IS NOT INITIAL.
        SET PARAMETER ID 'RES' FIELD <r>-rsnum.
        CALL TRANSACTION 'MB23' WITH AUTHORITY-CHECK AND SKIP FIRST SCREEN.
    ENDCASE.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD is_automation_active.
    SELECT SINGLE active FROM zmm_301_ctrl INTO @DATA(lv_a)
      WHERE werks_fr = @p_werk_fr AND werks_to = @p_werk_to.
    rv_active = xsdbool( sy-subrc = 0 AND lv_a = abap_true ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD schedule_next_run.
    " next start = now (end of this run) + interval
    DATA: lv_date TYPE d, lv_time TYPE t, lv_ts TYPE timestamp.
    lv_date = sy-datum. lv_time = sy-uzeit.
    CONVERT DATE lv_date TIME lv_time INTO TIME STAMP lv_ts TIME ZONE sy-zonlo.
    lv_ts = cl_abap_tstmp=>add( tstmp = lv_ts secs = interval_in_seconds( ) ).
    CONVERT TIME STAMP lv_ts TIME ZONE sy-zonlo INTO DATE lv_date TIME lv_time.

    DATA: lv_jobname  TYPE btcjob VALUE 'ZMM301R_CHAIN',
          lv_jobcount TYPE btcjobcnt.

    CALL FUNCTION 'JOB_OPEN'
      EXPORTING jobname = lv_jobname
      IMPORTING jobcount = lv_jobcount
      EXCEPTIONS OTHERS = 1.
    IF sy-subrc <> 0. RETURN. ENDIF.

    SUBMIT zmm_r_create_301_reserv
      WITH p_werk_fr = p_werk_fr
      WITH p_lgor_fr = p_lgor_fr
      WITH p_werk_to = p_werk_to
      WITH p_lgor_to = p_lgor_to
      WITH so_aufnr IN so_aufnr
      WITH so_auart IN so_auart
      WITH so_matnr IN so_matnr
      WITH so_dispo IN so_dispo
      WITH p_rsdat   = p_rsdat
      WITH p_move    = p_move
      WITH p_test    = p_test
      WITH p_erron   = p_erron
      WITH p_sched   = p_sched
      WITH p_freq    = p_freq
      WITH p_funit   = p_funit
      VIA JOB lv_jobname NUMBER lv_jobcount
      AND RETURN.

    CALL FUNCTION 'JOB_CLOSE'
      EXPORTING jobcount = lv_jobcount
                jobname  = lv_jobname
                sdlstrtdt = lv_date
                sdlstrttm = lv_time
      EXCEPTIONS OTHERS = 1.

    " next run recorded in the execution log by finish_run_log
    ms_counts-next_run_dt = lv_date.
    ms_counts-next_run_tm = lv_time.
    MESSAGE s013(zmm301) WITH lv_date lv_time.
  ENDMETHOD.

ENDCLASS.

*---------------------------------------------------------------------*
INITIALIZATION.
  CALL FUNCTION 'VRM_SET_VALUES'
    EXPORTING id     = 'P_FUNIT'
              values = VALUE vrm_values( ( key = 'MIN' text = 'Minutes' )
                                         ( key = 'HRS' text = 'Hours' )
                                         ( key = 'DAY' text = 'Days' ) ).

*---------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
  " frequency fields ready for input only when self-reschedule is set
  LOOP AT SCREEN.
    IF screen-group1 = 'SCH' AND p_sched = abap_false.
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.

*---------------------------------------------------------------------*
AT SELECTION-SCREEN.
  IF sscrfields-ucomm = 'ONLI' OR sy-batch = abap_true.
    lcl_app=>validate_selection( ).
  ENDIF.

*---------------------------------------------------------------------*
START-OF-SELECTION.
  DATA(go_app) = NEW lcl_app( ).
  go_app->run( ).
