*&---------------------------------------------------------------------*
*& Report  ZMM_R_CREATE_301_RESERV
*&---------------------------------------------------------------------*
*& FS-MM-301RES-001 : Create / align 301 transfer reservations for open
*&                    production orders (origin plant -> destination plant)
*&
*& Migration 8P01 -> 8Q01. Reservation remaining (BDMNG - ENMNG) is kept
*& equal to PO remaining (PSMNG - WEMNG). The physical 301 movements that
*& consume the reservation are posted by the companion object
*& (FS-MM-301MOV-001), NOT by this program.
*&
*& NOTE: BAPI field names for the reservation change/close path should be
*&       verified against the target release (see FS Open Issue O4).
*&---------------------------------------------------------------------*
REPORT zmm_r_create_301_reserv.

TYPE-POOLS abap.

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
                so_auart FOR   ('AUART'),
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
PARAMETERS: p_sched AS CHECKBOX,                               " self-reschedule
            p_freq  TYPE i DEFAULT 5,                          " frequency value
            p_funit TYPE c LENGTH 3 DEFAULT 'MIN'              " MIN / HRS / DAY
                    AS LISTBOX VISIBLE LENGTH 6.
SELECTION-SCREEN END OF BLOCK b4.

SELECTION-SCREEN BEGIN OF BLOCK b5 WITH FRAME TITLE TEXT-005. " Raw materials
PARAMETERS: p_rawmat AS CHECKBOX.                              " also reserve raw materials
PARAMETERS: p_werkrf TYPE werks_d DEFAULT '8Q01'              " RM source plant (new plant)
                     MODIF ID raw,
            p_lgorrf TYPE lgort_d MODIF ID raw,               " RM source stor.loc
            p_werkrt TYPE werks_d DEFAULT '8P01'              " RM target plant (prod.plant)
                     MODIF ID raw,
            p_lgorrt TYPE lgort_d MODIF ID raw.               " RM target stor.loc
SELECTION-SCREEN END OF BLOCK b5.

*---------------------------------------------------------------------*
* Global constants
*---------------------------------------------------------------------*
CONSTANTS: gc_mvt_301 TYPE bwart VALUE '301',
           " system status codes
           gc_stat_rel  TYPE j_status VALUE 'I0002', " REL
           gc_stat_teco TYPE j_status VALUE 'I0045', " TECO
           gc_stat_clsd TYPE j_status VALUE 'I0046', " CLSD
           gc_stat_dlfl TYPE j_status VALUE 'I0043', " DLFL
           gc_stat_dlt  TYPE j_status VALUE 'I0076', " deletion indicator
           " result status
           gc_created   TYPE c VALUE 'C',
           gc_realigned TYPE c VALUE 'R',
           gc_closed    TYPE c VALUE 'X',
           gc_unchanged TYPE c VALUE 'N',
           gc_complete  TYPE c VALUE 'F',
           gc_error     TYPE c VALUE 'E',
           gc_simulated TYPE c VALUE 'S',
           gc_skipped   TYPE c VALUE 'K',
           " reservation kind
           gc_kind_h    TYPE c VALUE 'H',         " header material  (8P01 -> 8Q01)
           gc_kind_r    TYPE c VALUE 'R',         " raw-material comp (8Q01 -> 8P01)
           gc_freq_min  TYPE i VALUE 60,          " 1 minute floor (seconds)
           gc_freq_max  TYPE i VALUE 2592000.     " 30 days ceiling (seconds)

*---------------------------------------------------------------------*
* Local class : application engine
*---------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.

  PUBLIC SECTION.
    TYPES: BEGIN OF ty_out,
             res_kind     TYPE c LENGTH 1,   " H = header / R = raw material
             aufnr        TYPE aufnr,
             auart        TYPE aufart,
             posnr        TYPE co_posnr,      " 0001 (header) or component RSPOS
             matnr        TYPE matnr,
             po_open      TYPE menge_d,       " basis qty: PO open (H) or shortage (R)
             res_bdmng    TYPE menge_d,
             res_enmng    TYPE menge_d,
             target_bdmng TYPE menge_d,
             meins        TYPE meins,
             werks_fr     TYPE werks_d,
             lgort_fr     TYPE lgort_d,
             werks_to     TYPE werks_d,
             lgort_to     TYPE lgort_d,
             rsnum        TYPE rsnum,
             rspos        TYPE rspos,
             status       TYPE c LENGTH 1,
             statxt       TYPE string,
             message      TYPE string,
           END OF ty_out.
    TYPES tt_out TYPE STANDARD TABLE OF ty_out WITH DEFAULT KEY.

    METHODS constructor.
    METHODS run.

  PRIVATE SECTION.
    TYPES: BEGIN OF ty_ord,
             aufnr TYPE aufnr,
             auart TYPE aufart,
             objnr TYPE j_objnr,
             posnr TYPE co_posnr,
             matnr TYPE matnr,
             psmng TYPE psmng,
             wemng TYPE wemng,
             meins TYPE meins,
             elikz TYPE elikz,
             dispo TYPE dispo,
           END OF ty_ord.
    TYPES tt_ord TYPE STANDARD TABLE OF ty_ord WITH DEFAULT KEY.

    DATA: mt_out    TYPE tt_out,
          mv_run_id TYPE sysuuid_c32,
          mv_mode   TYPE c LENGTH 1,    " O / B
          ms_counts TYPE zmm_301_run_log.

    METHODS validate_selection.
    METHODS interval_in_seconds RETURNING VALUE(rv_secs) TYPE i.
    METHODS select_open_orders
      RETURNING VALUE(rt_orders) TYPE tt_ord.
    METHODS process_order
      IMPORTING is_order TYPE ty_ord.
    METHODS process_raw_components
      IMPORTING is_order TYPE ty_ord.
    " Generic create/realign/close for one reservation item (header or RM)
    METHODS reconcile_item
      IMPORTING iv_kind     TYPE c
                iv_aufnr    TYPE aufnr
                iv_posnr    TYPE co_posnr
                iv_matnr    TYPE matnr
                iv_basis    TYPE menge_d      " PO open (H) or shortage (R)
                iv_meins    TYPE meins
                iv_werks_fr TYPE werks_d
                iv_lgor_fr  TYPE lgort_d
                iv_werks_to TYPE werks_d
                iv_lgor_to  TYPE lgort_d
                iv_to_close TYPE abap_bool DEFAULT abap_false
                iv_wemng    TYPE menge_d DEFAULT 0.
    METHODS create_reservation
      IMPORTING is_out   TYPE ty_out
      CHANGING  cs_out   TYPE ty_out.
    METHODS change_reservation
      IMPORTING iv_close TYPE abap_bool
      CHANGING  cs_out   TYPE ty_out.
    METHODS start_run_log.
    METHODS finish_run_log IMPORTING iv_status TYPE c.
    METHODS write_detail_log IMPORTING is_out TYPE ty_out.
    METHODS display_alv.
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
    validate_selection( ).
    start_run_log( ).

    DATA(lt_orders) = select_open_orders( ).
    ms_counts-cnt_selected = lines( lt_orders ).

    IF lt_orders IS INITIAL.
      MESSAGE s002(zmm301).
    ENDIF.

    LOOP AT lt_orders ASSIGNING FIELD-SYMBOL(<order>).
      process_order( <order> ).                 " header material (8P01 -> 8Q01)
      IF p_rawmat = abap_true.
        process_raw_components( <order> ).      " raw materials (8Q01 -> 8P01)
      ENDIF.
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
    ENDLOOP.

    DATA(lv_final) = COND char1( WHEN ms_counts-cnt_error > 0 THEN 'W' ELSE 'S' ).
    finish_run_log( lv_final ).

    IF mv_mode = 'O'.
      display_alv( ).
    ENDIF.

    " self-rescheduling chain (background, live or test)
    IF p_sched = abap_true.
      IF is_automation_active( ) = abap_true.
        schedule_next_run( ).
      ELSE.
        MESSAGE s012(zmm301).                       " chain stopped
      ENDIF.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD validate_selection.
    IF p_werk_fr = p_werk_to.
      MESSAGE e001(zmm301) WITH p_werk_fr p_werk_to.
    ENDIF.
    " plant existence
    SELECT SINGLE werks FROM t001w INTO @DATA(lv_w) WHERE werks = @p_werk_fr.
    IF sy-subrc <> 0. MESSAGE e014(zmm301) WITH p_werk_fr. ENDIF.
    SELECT SINGLE werks FROM t001w INTO @lv_w WHERE werks = @p_werk_to.
    IF sy-subrc <> 0. MESSAGE e014(zmm301) WITH p_werk_to. ENDIF.
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
    " frequency floor / ceiling (only relevant with self-reschedule)
    IF p_sched = abap_true.
      DATA(lv_secs) = interval_in_seconds( ).
      IF lv_secs < gc_freq_min. MESSAGE e010(zmm301). ENDIF.
      IF lv_secs > gc_freq_max. MESSAGE e011(zmm301). ENDIF.
    ENDIF.
    " raw-material plants (only relevant when the option is active)
    IF p_rawmat = abap_true.
      IF p_werkrf IS INITIAL OR p_werkrt IS INITIAL OR p_werkrf = p_werkrt.
        MESSAGE e016(zmm301) WITH p_werkrf p_werkrt.   " RM plants required and must differ
      ENDIF.
      SELECT SINGLE werks FROM t001w INTO @lv_w WHERE werks = @p_werkrf.
      IF sy-subrc <> 0. MESSAGE e014(zmm301) WITH p_werkrf. ENDIF.
      SELECT SINGLE werks FROM t001w INTO @lv_w WHERE werks = @p_werkrt.
      IF sy-subrc <> 0. MESSAGE e014(zmm301) WITH p_werkrt. ENDIF.
    ENDIF.

    " authorization: create goods movement/reservation for the plants & mvt 301
    AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'
      ID 'ACTVT' FIELD '01'
      ID 'BWART' FIELD gc_mvt_301
      ID 'WERKS' FIELD p_werk_fr.
    IF sy-subrc <> 0. MESSAGE e018(zmm301) WITH p_werk_fr. ENDIF.
    AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'
      ID 'ACTVT' FIELD '01'
      ID 'BWART' FIELD gc_mvt_301
      ID 'WERKS' FIELD p_werk_to.
    IF sy-subrc <> 0. MESSAGE e018(zmm301) WITH p_werk_to. ENDIF.
    IF p_rawmat = abap_true.
      AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'
        ID 'ACTVT' FIELD '01'
        ID 'BWART' FIELD gc_mvt_301
        ID 'WERKS' FIELD p_werkrf.
      IF sy-subrc <> 0. MESSAGE e018(zmm301) WITH p_werkrf. ENDIF.
      AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'
        ID 'ACTVT' FIELD '01'
        ID 'BWART' FIELD gc_mvt_301
        ID 'WERKS' FIELD p_werkrt.
      IF sy-subrc <> 0. MESSAGE e018(zmm301) WITH p_werkrt. ENDIF.
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
  METHOD select_open_orders.
    DATA lt_ord TYPE tt_ord.

    SELECT k~aufnr k~auart k~objnr
           p~posnr p~matnr p~psmng p~wemng p~meins p~elikz
           f~dispo
      FROM aufk AS k
      INNER JOIN afko AS f ON f~aufnr = k~aufnr
      INNER JOIN afpo AS p ON p~aufnr = k~aufnr
      INTO CORRESPONDING FIELDS OF TABLE @lt_ord
      WHERE k~werks   = @p_werk_fr
        AND k~aufnr  IN @so_aufnr
        AND k~auart  IN @so_auart
        AND p~matnr  IN @so_matnr
        AND f~dispo  IN @so_dispo
        AND p~elikz   = @space.               " delivery not completed

    IF lt_ord IS INITIAL.
      RETURN.
    ENDIF.

    " status filter: released, not TECO/CLSD/DLFL/deletion
    DATA lt_objnr TYPE STANDARD TABLE OF j_objnr.
    lt_objnr = VALUE #( FOR l IN lt_ord ( l-objnr ) ).
    SORT lt_objnr. DELETE ADJACENT DUPLICATES FROM lt_objnr.

    SELECT objnr stat FROM jest
      INTO TABLE @DATA(lt_jest)
      FOR ALL ENTRIES IN @lt_objnr
      WHERE objnr = @lt_objnr-table_line
        AND inact = @space.
    SORT lt_jest BY objnr stat.

    LOOP AT lt_ord ASSIGNING FIELD-SYMBOL(<ord>).
      DATA(lv_rel)  = xsdbool( line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_rel  ] ) ).
      DATA(lv_stop) = xsdbool(
             line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_teco ] )
          OR line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_clsd ] )
          OR line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_dlfl ] )
          OR line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_dlt  ] ) ).

      " Keep released & not closed orders; a TECO/CLSD order that still has a
      " reservation will be picked for a CLOSE action inside process_order.
      IF lv_rel = abap_false.
        DELETE lt_ord.  " not released -> ignore
        CONTINUE.
      ENDIF.
      IF lv_stop = abap_true.
        <ord>-elikz = 'C'.  " mark as 'to be closed' (reuse field as flag)
      ENDIF.
    ENDLOOP.

    rt_orders = lt_ord.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD process_order.
    " Header material (8P01 -> 8Q01). Basis qty = PO open = PSMNG - WEMNG.
    DATA(lv_to_close) = xsdbool( is_order-elikz = 'C' ).   " TECO/CLSD flag
    DATA(lv_po_open)  = CONV menge_d( is_order-psmng - is_order-wemng ).

    reconcile_item(
      iv_kind     = gc_kind_h
      iv_aufnr    = is_order-aufnr
      iv_posnr    = '0001'
      iv_matnr    = is_order-matnr
      iv_basis    = lv_po_open
      iv_meins    = is_order-meins
      iv_werks_fr = p_werk_fr
      iv_lgor_fr  = p_lgor_fr
      iv_werks_to = p_werk_to
      iv_lgor_to  = p_lgor_to
      iv_to_close = lv_to_close
      iv_wemng    = is_order-wemng ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD process_raw_components.
    " Raw-material components (8Q01 -> 8P01). One reservation per component
    " that is SHORT in the target (production) plant.
    DATA(lv_to_close) = xsdbool( is_order-elikz = 'C' ).

    " Open component requirements of the production order.
    " POSTP = 'L' -> stock item only (excludes non-stock 'N', text 'T', phantom).
    SELECT rspos, matnr, bdmng, enmng, meins, werks, bdter
      FROM resb INTO TABLE @DATA(lt_comp)
      WHERE aufnr = @is_order-aufnr
        AND werks = @p_werkrt          " requirement at the production plant
        AND matnr <> @space
        AND postp = 'L'                " stock item
        AND xloek = @space             " not deleted
        AND dumps = @space             " not a phantom assembly
        AND kzear = @space.            " not final-issued

    LOOP AT lt_comp ASSIGNING FIELD-SYMBOL(<c>).
      DATA(lv_req) = CONV menge_d( <c>-bdmng - <c>-enmng ).   " open requirement

      " available unrestricted stock of the component in the target plant
      SELECT SUM( labst ) FROM mard INTO @DATA(lv_stock)
        WHERE matnr = @<c>-matnr AND werks = @p_werkrt.

      DATA(lv_short) = CONV menge_d( lv_req - lv_stock ).
      IF lv_short < 0. lv_short = 0. ENDIF.

      " If component now fully covered (short = 0) reconcile_item will CLOSE
      " any existing RM reservation; if short > 0 it creates/realigns.
      reconcile_item(
        iv_kind     = gc_kind_r
        iv_aufnr    = is_order-aufnr
        iv_posnr    = <c>-rspos
        iv_matnr    = <c>-matnr
        iv_basis    = lv_short
        iv_meins    = <c>-meins
        iv_werks_fr = p_werkrf         " issuing = new plant (8Q01)
        iv_lgor_fr  = p_lgorrf
        iv_werks_to = p_werkrt         " receiving = production plant (8P01)
        iv_lgor_to  = p_lgorrt
        iv_to_close = COND #( WHEN lv_short <= 0 THEN abap_true ELSE lv_to_close ) ).
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD reconcile_item.
    " Generic create / realign / close / unchanged for one reservation item.
    DATA ls_out TYPE ty_out.
    ls_out-res_kind = iv_kind.
    ls_out-aufnr    = iv_aufnr.
    ls_out-posnr    = iv_posnr.
    ls_out-matnr    = iv_matnr.
    ls_out-po_open  = iv_basis.        " PO open (H) or shortage (R)
    ls_out-meins    = iv_meins.
    ls_out-werks_fr = iv_werks_fr.
    ls_out-lgort_fr = iv_lgor_fr.
    ls_out-werks_to = iv_werks_to.
    ls_out-lgort_to = iv_lgor_to.

    " Existing reservation via link table (latest row for order+kind+item).
    " ORDER BY needs a set read + UP TO 1 ROWS (SELECT SINGLE cannot ORDER BY).
    DATA: lv_link_rsnum TYPE rsnum,
          lv_link_rspos TYPE rspos.
    SELECT rsnum, rspos FROM zmm_301_resv_log
      WHERE aufnr = @iv_aufnr AND res_kind = @iv_kind AND posnr = @iv_posnr
        AND rsnum <> @space
      ORDER BY erdat DESCENDING, erzet DESCENDING
      INTO (@lv_link_rsnum, @lv_link_rspos)
      UP TO 1 ROWS.
    ENDSELECT.

    DATA lv_has_res TYPE abap_bool.
    IF lv_link_rsnum IS NOT INITIAL.
      SELECT SINGLE bdmng, enmng FROM resb INTO @DATA(ls_resb)
        WHERE rsnum = @lv_link_rsnum AND rspos = @lv_link_rspos.
      IF sy-subrc = 0.
        lv_has_res       = abap_true.
        ls_out-rsnum     = lv_link_rsnum.
        ls_out-rspos     = lv_link_rspos.
        ls_out-res_bdmng = ls_resb-bdmng.
        ls_out-res_enmng = ls_resb-enmng.
      ENDIF.
    ENDIF.

    " reprocess-errors-only filter (latest logged status for this item)
    IF p_erron = abap_true AND lv_has_res = abap_true.
      DATA lv_last TYPE char1.
      SELECT status FROM zmm_301_resv_log
        WHERE aufnr = @iv_aufnr AND res_kind = @iv_kind AND posnr = @iv_posnr
        ORDER BY erdat DESCENDING, erzet DESCENDING
        INTO @lv_last
        UP TO 1 ROWS.
      ENDSELECT.
      IF lv_last <> gc_error.
        RETURN.
      ENDIF.
    ENDIF.

    " target requirement qty : reservation open must equal the basis qty
    DATA(lv_target) = CONV menge_d( iv_basis + ls_out-res_enmng ).
    ls_out-target_bdmng = lv_target.

    " ---------------- decision matrix ----------------
    IF lv_has_res = abap_false.
      IF iv_basis <= 0.
        " Nothing to reserve. Header: show/log as 'Fully received'.
        " Raw material: stay silent (avoid logging every covered component).
        IF iv_kind = gc_kind_r.
          RETURN.
        ENDIF.
        ls_out-status = gc_skipped.
        ls_out-statxt = 'Fully received'.
      ELSE.
        create_reservation( EXPORTING is_out = ls_out CHANGING cs_out = ls_out ).
      ENDIF.
    ELSE.
      IF iv_to_close = abap_true OR iv_basis <= 0.
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
      ENDIF.
    ENDIF.

    " drift indicator (header only): GR received but not yet transferred
    IF iv_kind = gc_kind_h AND lv_has_res = abap_true
       AND iv_wemng - ls_out-res_enmng > 0.
      ms_counts-cnt_drift = ms_counts-cnt_drift + 1.
    ENDIF.

    APPEND ls_out TO mt_out.
    write_detail_log( ls_out ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD create_reservation.
    cs_out = is_out.

    IF p_test = abap_true.
      cs_out-status = gc_simulated.
      cs_out-statxt = 'Simulated (create)'.
      RETURN.
    ENDIF.

    DATA: ls_head   TYPE bapi2093_res_head_c1,
          lt_items  TYPE STANDARD TABLE OF bapi2093_res_item_c1,
          ls_item   TYPE bapi2093_res_item_c1,
          lt_return TYPE STANDARD TABLE OF bapiret2,
          lv_resno  TYPE rsnum.

    ls_head-res_date = p_rsdat.
    ls_head-movement = p_move.

    " Plants/locations come from the item (header: 8P01->8Q01, RM: 8Q01->8P01)
    ls_item-material_long = is_out-matnr.
    ls_item-material      = is_out-matnr.        " 18-char legacy field
    ls_item-plant         = is_out-werks_fr.
    ls_item-stge_loc      = is_out-lgort_fr.
    ls_item-move_type     = gc_mvt_301.
    ls_item-entry_qnt     = is_out-po_open.      " basis qty; initial ENMNG = 0
    ls_item-entry_uom     = is_out-meins.
    ls_item-req_date      = p_rsdat.
    ls_item-move_plant    = is_out-werks_to.
    ls_item-move_stloc    = is_out-lgort_to.
    APPEND ls_item TO lt_items.

    CALL FUNCTION 'BAPI_RESERVATION_CREATE1'
      EXPORTING
        reservationheader = ls_head
      IMPORTING
        reservation       = lv_resno
      TABLES
        reservationitems  = lt_items
        return            = lt_return.

    READ TABLE lt_return TRANSPORTING NO FIELDS
         WITH KEY type = 'E'.
    DATA(lv_err) = xsdbool( sy-subrc = 0 ).
    IF lv_err = abap_false.
      READ TABLE lt_return TRANSPORTING NO FIELDS WITH KEY type = 'A'.
      lv_err = xsdbool( sy-subrc = 0 ).
    ENDIF.

    IF lv_err = abap_true.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      cs_out-status  = gc_error.
      cs_out-statxt  = 'Create error'.
      cs_out-message = VALUE #( lt_return[ type = 'E' ]-message OPTIONAL ).
    ELSE.
      CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X'.
      cs_out-rsnum   = lv_resno.
      cs_out-rspos   = '0001'.
      cs_out-status  = gc_created.
      cs_out-statxt  = 'Created'.
      cs_out-message = |Reservation { lv_resno } created|.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD change_reservation.
    " Realign (BDMNG = target) or close (BDMNG = ENMNG).
    " NOTE: verify BAPI_RESERVATION_CHANGE item/itemX field names for the
    "       target release (FS Open Issue O4). MB22 FM/BDC is the fallback.
    DATA(lv_newqty) = COND menge_d(
        WHEN iv_close = abap_true THEN cs_out-res_enmng
        ELSE cs_out-target_bdmng ).

    IF p_test = abap_true.
      cs_out-status = gc_simulated.
      cs_out-statxt = COND #( WHEN iv_close = abap_true
                              THEN 'Simulated (close)' ELSE 'Simulated (realign)' ).
      RETURN.
    ENDIF.

    DATA: lt_items  TYPE STANDARD TABLE OF bapi2093_res_item_c,
          lt_itemsx TYPE STANDARD TABLE OF bapi2093_res_item_cx,
          lt_return TYPE STANDARD TABLE OF bapiret2,
          ls_i      TYPE bapi2093_res_item_c,
          ls_ix     TYPE bapi2093_res_item_cx.

    " The reservation requirement quantity (RESB-BDMNG) is carried in REQ_QUAN
    " in these BAPI structures; ENTRY_QNT is the entry-UoM quantity. Set both
    " and flag both in the X-structure so the requirement actually changes.
    " *** verify REQ_QUAN/ENTRY_QNT field names for the target release (O4) ***
    ls_i-res_item  = cs_out-rspos.
    ls_i-req_quan  = lv_newqty.
    ls_i-entry_qnt = lv_newqty.
    APPEND ls_i TO lt_items.

    ls_ix-res_item  = cs_out-rspos.
    ls_ix-req_quan  = 'X'.
    ls_ix-entry_qnt = 'X'.
    APPEND ls_ix TO lt_itemsx.

    CALL FUNCTION 'BAPI_RESERVATION_CHANGE'
      EXPORTING
        reservation       = cs_out-rsnum
      TABLES
        reservationitems  = lt_items
        reservationitemsx = lt_itemsx
        return            = lt_return.

    READ TABLE lt_return TRANSPORTING NO FIELDS WITH KEY type = 'E'.
    IF sy-subrc = 0.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      cs_out-status  = gc_error.
      cs_out-statxt  = 'Change error'.
      cs_out-message = VALUE #( lt_return[ type = 'E' ]-message OPTIONAL ).
    ELSE.
      CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X'.
      IF iv_close = abap_true.
        cs_out-status = gc_closed.
        cs_out-statxt = 'Closed'.
      ELSE.
        cs_out-status = gc_realigned.
        cs_out-statxt = 'Realigned'.
      ENDIF.
      cs_out-res_bdmng = lv_newqty.
      cs_out-message   = |Reservation { cs_out-rsnum } set to { lv_newqty }|.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD start_run_log.
    ms_counts = VALUE #( run_id     = mv_run_id
                         run_mode   = mv_mode
                         jobname    = COND #( WHEN mv_mode = 'B' THEN sy-msgv1 )
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
    MODIFY zmm_301_run_log FROM @ms_counts.
    COMMIT WORK.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD write_detail_log.
    DATA ls_log TYPE zmm_301_resv_log.
    ls_log = VALUE #( aufnr     = is_out-aufnr
                      res_kind  = is_out-res_kind
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
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD display_alv.
    DATA lo_alv TYPE REF TO cl_salv_table.
    TRY.
        cl_salv_table=>factory(
          IMPORTING r_salv_table = lo_alv
          CHANGING  t_table      = mt_out ).
        lo_alv->get_functions( )->set_all( abap_true ).
        lo_alv->get_columns( )->set_optimize( abap_true ).
        lo_alv->display( ).
      CATCH cx_salv_msg INTO DATA(lx).
        MESSAGE lx->get_text( ) TYPE 'I'.
    ENDTRY.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD is_automation_active.
    SELECT SINGLE active FROM zmm_301_ctrl INTO @DATA(lv_a)
      WHERE werks_fr = @p_werk_fr AND werks_to = @p_werk_to.
    rv_active = xsdbool( sy-subrc = 0 AND lv_a = abap_true ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD schedule_next_run.
    " next start = now + interval
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

    " record next run in the execution log
    ms_counts-next_run_dt = lv_date.
    ms_counts-next_run_tm = lv_time.
    MODIFY zmm_301_run_log FROM @ms_counts.
    COMMIT WORK.
    MESSAGE s013(zmm301) WITH lv_date lv_time.
  ENDMETHOD.

ENDCLASS.

*---------------------------------------------------------------------*
INITIALIZATION.
  " listbox values for frequency unit (P_FUNIT) and any texts
  " (populate via VRM_SET_VALUES in a real build; omitted for brevity)

*---------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
  " enable the raw-material plant/loc fields only when P_RAWMAT is ticked
  LOOP AT SCREEN.
    IF screen-group1 = 'RAW'.
      screen-input = COND i( WHEN p_rawmat = abap_true THEN 1 ELSE 0 ).
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.

*---------------------------------------------------------------------*
AT SELECTION-SCREEN.
  " field-level validations run here in the real build
  " (delegated to LCL_APP->validate_selection at START-OF-SELECTION)

*---------------------------------------------------------------------*
START-OF-SELECTION.
  DATA(go_app) = NEW lcl_app( ).
  go_app->run( ).
