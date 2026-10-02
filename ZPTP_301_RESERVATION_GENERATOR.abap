*&---------------------------------------------------------------------*
*& Report  ZPTP_301_RESERVATION_GENERATOR
*&---------------------------------------------------------------------*
*& FS-MM-301RES-001 : Create / align 301 transfer reservations for open
*&                    production orders (origin plant -> destination plant)
*&
*& Migration 8P01 -> 8Q01. Reservation remaining (BDMNG - ENMNG) is kept
*& equal to PO remaining (PSMNG - WEMNG). The physical 301 movements that
*& consume the reservation are posted by the companion object
*& (FS-MM-301MOV-001), NOT by this program.
*&
*& Finished product (AFPO-MATNR, 8P01 -> 8Q01): released orders only.
*& Optional raw materials (P_RAWMAT, 8Q01 -> 8P01): open orders (created
*& or released). The short components of an order go into their own
*& reservation, independent of the finished-product reservation.
*&
*& NOTE: BAPI field names for the reservation change/close path should be
*&       verified against the target release (see FS Open Issue O4).
*&---------------------------------------------------------------------*
REPORT zptp_301_reservation_generator.

TYPE-POOLS abap.

*---------------------------------------------------------------------*
* Selection screen
*---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001. " Plants / locations
PARAMETERS: p_werkfr TYPE werks_d OBLIGATORY DEFAULT '8P01', " origin plant
            p_lgorfr TYPE lgort_d,                            " origin stor.loc
            p_werkto TYPE werks_d OBLIGATORY DEFAULT '8Q01', " destination plant
            p_lgorto TYPE lgort_d.                            " destination stor.loc
SELECTION-SCREEN END OF BLOCK b1.

" typing references for the select-options
DATA: gv_aufnr TYPE aufnr,
      gv_auart TYPE aufart,
      gv_matnr TYPE matnr,
      gv_dispo TYPE dispo.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002. " Order selection
SELECT-OPTIONS: so_aufnr FOR gv_aufnr,
                so_auart FOR gv_auart,
                so_matnr FOR gv_matnr,
                so_dispo FOR gv_dispo.
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
PARAMETERS: p_rawmat AS CHECKBOX USER-COMMAND raw.             " also reserve raw materials
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
           " reservation kind (log key)
           gc_kind_h    TYPE c VALUE 'H',         " finished product (8P01 -> 8Q01)
           gc_kind_r    TYPE c VALUE 'R',         " raw-material comp (8Q01 -> 8P01)
           gc_freq_min  TYPE i VALUE 60,          " 1 minute floor (seconds)
           gc_freq_max  TYPE i VALUE 2592000.     " 30 days ceiling (seconds)

*---------------------------------------------------------------------*
* Local class : application engine
*---------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.

  PUBLIC SECTION.
    TYPES: BEGIN OF ty_out,
             res_kind     TYPE c LENGTH 1,   " H = finished product / R = raw material
             aufnr        TYPE aufnr,
             auart        TYPE aufart,
             posnr        TYPE co_posnr,      " 0001 (H) or component RSPOS (R)
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
             psmng TYPE afpo-psmng,
             wemng TYPE afpo-wemng,
             meins TYPE meins,
             elikz TYPE elikz,
             dispo TYPE dispo,
             rel   TYPE abap_bool,          " order released (REL)
           END OF ty_ord.
    TYPES tt_ord TYPE STANDARD TABLE OF ty_ord WITH DEFAULT KEY.

    DATA: mt_out    TYPE tt_out,
          mv_run_id TYPE sysuuid_c32,
          mv_mode   TYPE c LENGTH 1,    " O / B
          ms_counts TYPE zptp_301_run_log.

    METHODS validate_selection.
    METHODS interval_in_seconds RETURNING VALUE(rv_secs) TYPE i.
    METHODS select_open_orders
      RETURNING VALUE(rt_orders) TYPE tt_ord.
    METHODS process_order
      IMPORTING is_order TYPE ty_ord.
    METHODS process_raw_components
      IMPORTING is_order TYPE ty_ord.
    " Create/realign/close for one reservation item (finished product or RM).
    " CT_NEW supplied: items to create are collected by the caller instead.
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
                iv_wemng    TYPE menge_d DEFAULT 0
      CHANGING  ct_new      TYPE tt_out OPTIONAL.
    " One reservation with one item per row of CT_OUT
    METHODS create_reservation
      CHANGING  ct_out   TYPE tt_out.
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
      MESSAGE s028(zptp_split_val).
    ENDIF.

    LOOP AT lt_orders ASSIGNING FIELD-SYMBOL(<order>).
      IF <order>-rel = abap_true.
        process_order( <order> ).               " finished product (8P01 -> 8Q01)
      ENDIF.
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
        MESSAGE s038(zptp_split_val).               " chain stopped
      ENDIF.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD validate_selection.
    IF p_werkfr = p_werkto.
      MESSAGE e027(zptp_split_val) WITH p_werkfr p_werkto.
    ENDIF.
    " plant existence
    SELECT SINGLE werks FROM t001w INTO @DATA(lv_w) WHERE werks = @p_werkfr.
    IF sy-subrc <> 0. MESSAGE e040(zptp_split_val) WITH p_werkfr. ENDIF.
    SELECT SINGLE werks FROM t001w INTO @lv_w WHERE werks = @p_werkto.
    IF sy-subrc <> 0. MESSAGE e040(zptp_split_val) WITH p_werkto. ENDIF.
    " storage location existence (only if entered)
    IF p_lgorfr IS NOT INITIAL.
      SELECT SINGLE lgort FROM t001l INTO @DATA(lv_l)
        WHERE werks = @p_werkfr AND lgort = @p_lgorfr.
      IF sy-subrc <> 0. MESSAGE e041(zptp_split_val) WITH p_lgorfr p_werkfr. ENDIF.
    ENDIF.
    IF p_lgorto IS NOT INITIAL.
      SELECT SINGLE lgort FROM t001l INTO @lv_l
        WHERE werks = @p_werkto AND lgort = @p_lgorto.
      IF sy-subrc <> 0. MESSAGE e041(zptp_split_val) WITH p_lgorto p_werkto. ENDIF.
    ENDIF.
    " frequency floor / ceiling (only relevant with self-reschedule)
    IF p_sched = abap_true.
      DATA(lv_secs) = interval_in_seconds( ).
      IF lv_secs < gc_freq_min. MESSAGE e036(zptp_split_val). ENDIF.
      IF lv_secs > gc_freq_max. MESSAGE e037(zptp_split_val). ENDIF.
    ENDIF.
    " raw-material plants (only relevant when the option is active)
    IF p_rawmat = abap_true.
      IF p_werkrf IS INITIAL OR p_werkrt IS INITIAL OR p_werkrf = p_werkrt.
        MESSAGE e042(zptp_split_val) WITH p_werkrf p_werkrt.   " RM plants required and must differ
      ENDIF.
      SELECT SINGLE werks FROM t001w INTO @lv_w WHERE werks = @p_werkrf.
      IF sy-subrc <> 0. MESSAGE e040(zptp_split_val) WITH p_werkrf. ENDIF.
      SELECT SINGLE werks FROM t001w INTO @lv_w WHERE werks = @p_werkrt.
      IF sy-subrc <> 0. MESSAGE e040(zptp_split_val) WITH p_werkrt. ENDIF.
    ENDIF.

    " authorization: create goods movement/reservation for the plants & mvt 301
    AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'
      ID 'ACTVT' FIELD '01'
      ID 'BWART' FIELD gc_mvt_301
      ID 'WERKS' FIELD p_werkfr.
    IF sy-subrc <> 0. MESSAGE e044(zptp_split_val) WITH p_werkfr. ENDIF.
    AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'
      ID 'ACTVT' FIELD '01'
      ID 'BWART' FIELD gc_mvt_301
      ID 'WERKS' FIELD p_werkto.
    IF sy-subrc <> 0. MESSAGE e044(zptp_split_val) WITH p_werkto. ENDIF.
    IF p_rawmat = abap_true.
      AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'
        ID 'ACTVT' FIELD '01'
        ID 'BWART' FIELD gc_mvt_301
        ID 'WERKS' FIELD p_werkrf.
      IF sy-subrc <> 0. MESSAGE e044(zptp_split_val) WITH p_werkrf. ENDIF.
      AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'
        ID 'ACTVT' FIELD '01'
        ID 'BWART' FIELD gc_mvt_301
        ID 'WERKS' FIELD p_werkrt.
      IF sy-subrc <> 0. MESSAGE e044(zptp_split_val) WITH p_werkrt. ENDIF.
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

    SELECT k~aufnr, k~auart, k~objnr,
           p~posnr, p~matnr, p~psmng, p~wemng, p~meins, p~elikz,
           f~dispo
      FROM aufk AS k
      INNER JOIN afko AS f ON f~aufnr = k~aufnr
      INNER JOIN afpo AS p ON p~aufnr = k~aufnr
      INTO CORRESPONDING FIELDS OF TABLE @lt_ord
      WHERE k~werks   = @p_werkfr
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

    SELECT objnr, stat FROM jest
      INTO TABLE @DATA(lt_jest)
      FOR ALL ENTRIES IN @lt_objnr
      WHERE objnr = @lt_objnr-table_line
        AND inact = @space.
    SORT lt_jest BY objnr stat.

    LOOP AT lt_ord ASSIGNING FIELD-SYMBOL(<ord>).
      <ord>-rel     = xsdbool( line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_rel  ] ) ).
      DATA(lv_stop) = xsdbool(
             line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_teco ] )
          OR line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_clsd ] )
          OR line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_dlfl ] )
          OR line_exists( lt_jest[ objnr = <ord>-objnr stat = gc_stat_dlt  ] ) ).

      " Finished products need a released order; raw materials only need an
      " open one (created or released). A TECO/CLSD order that still has a
      " reservation is picked for a CLOSE action by the process methods.
      IF <ord>-rel = abap_false AND p_rawmat = abap_false.
        DELETE lt_ord.  " not released and no RM option -> ignore
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
    " Finished product (8P01 -> 8Q01). Basis qty = PO open = PSMNG - WEMNG.
    DATA(lv_to_close) = xsdbool( is_order-elikz = 'C' ).   " TECO/CLSD flag
    DATA(lv_po_open)  = CONV menge_d( is_order-psmng - is_order-wemng ).

    reconcile_item(
      iv_kind     = gc_kind_h
      iv_aufnr    = is_order-aufnr
      iv_posnr    = '0001'
      iv_matnr    = is_order-matnr
      iv_basis    = lv_po_open
      iv_meins    = is_order-meins
      iv_werks_fr = p_werkfr
      iv_lgor_fr  = p_lgorfr
      iv_werks_to = p_werkto
      iv_lgor_to  = p_lgorto
      iv_to_close = lv_to_close
      iv_wemng    = is_order-wemng ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD process_raw_components.
    " Raw-material components (8Q01 -> 8P01) that are SHORT in the production
    " plant. Components not yet reserved are created together in one
    " reservation per order, separate from the finished-product reservation.
    DATA lt_new TYPE tt_out.
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

      " short = 0 -> reconcile_item closes an existing RM item;
      " short > 0 -> realigns it, or collects the component in LT_NEW.
      reconcile_item(
        EXPORTING
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
          iv_to_close = COND #( WHEN lv_short <= 0 THEN abap_true ELSE lv_to_close )
        CHANGING
          ct_new      = lt_new ).
    ENDLOOP.

    " one RM reservation for all newly short components of this order
    IF lt_new IS NOT INITIAL.
      create_reservation( CHANGING ct_out = lt_new ).
      LOOP AT lt_new ASSIGNING FIELD-SYMBOL(<n>).
        APPEND <n> TO mt_out.
        write_detail_log( <n> ).
      ENDLOOP.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD reconcile_item.
    " Create / realign / close / unchanged for one reservation item.
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
    SELECT rsnum, rspos FROM zptp_301_res_log
      WHERE aufnr = @iv_aufnr AND res_kind = @iv_kind AND posnr = @iv_posnr
        AND rsnum <> @space
      ORDER BY erdat DESCENDING, erzet DESCENDING
      INTO (@lv_link_rsnum, @lv_link_rspos)
      UP TO 1 ROWS.
    ENDSELECT.

    " Fallback when the log row is missing: the order number is stored as
    " goods recipient (RESB-WEMPF) at creation. MATNR/WERKS/XLOEK/KZEAR
    " match RESB secondary index M.
    IF lv_link_rsnum IS INITIAL.
      SELECT rsnum, rspos FROM resb ##NULL_VALUES
        WHERE matnr = @iv_matnr
          AND werks = @iv_werks_fr
          AND xloek = @space
          AND kzear = @space
          AND wempf = @iv_aufnr
          AND umwrk = @iv_werks_to
          AND bwart = @gc_mvt_301
        ORDER BY rsnum DESCENDING, rspos
        INTO (@lv_link_rsnum, @lv_link_rspos)
        UP TO 1 ROWS.
      ENDSELECT.
    ENDIF.

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
      SELECT status FROM zptp_301_res_log
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
      ELSEIF ct_new IS SUPPLIED.
        " created later by the caller, together with the other new items
        APPEND ls_out TO ct_new.
        RETURN.
      ELSE.
        DATA(lt_one) = VALUE tt_out( ( ls_out ) ).
        create_reservation( CHANGING ct_out = lt_one ).
        ls_out = lt_one[ 1 ].
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
    " All rows share one direction: finished product (8P01 -> 8Q01) or
    " raw materials (8Q01 -> 8P01); they are never mixed in one reservation.
    FIELD-SYMBOLS <o> TYPE ty_out.

    IF p_test = abap_true.
      LOOP AT ct_out ASSIGNING <o>.
        <o>-status = gc_simulated.
        <o>-statxt = 'Simulated (create)'.
      ENDLOOP.
      RETURN.
    ENDIF.

    DATA: ls_head   TYPE bapi2093_res_head,
          lt_items  TYPE STANDARD TABLE OF bapi2093_res_item,
          ls_item   TYPE bapi2093_res_item,
          lt_return TYPE STANDARD TABLE OF bapiret2,
          lv_resno  TYPE rsnum,
          lt_rspos  TYPE STANDARD TABLE OF rspos WITH EMPTY KEY.

    " Movement type and receiving plant/stor.loc are header data in
    " BAPI_RESERVATION_CREATE1 (as on the MB21 initial screen). All rows share
    " one direction, so they are taken from the first row.
    DATA(ls_first) = ct_out[ 1 ].
    ls_head-res_date   = p_rsdat.
    ls_head-move_type  = gc_mvt_301.
    ls_head-move_plant = ls_first-werks_to.
    ls_head-move_stloc = ls_first-lgort_to.

    LOOP AT ct_out ASSIGNING <o>.
      CLEAR ls_item.
      ls_item-material_long = <o>-matnr.         " S/4: 40-char MATNR
      ls_item-plant         = <o>-werks_fr.
      ls_item-stge_loc      = <o>-lgort_fr.
      ls_item-entry_qnt     = <o>-po_open.       " basis qty; initial ENMNG = 0
      ls_item-entry_uom     = <o>-meins.
      ls_item-req_date      = p_rsdat.
      ls_item-movement      = p_move.            " movement allowed (RESB-XWAOK)
      ls_item-gr_rcpt       = <o>-aufnr.         " order no. -> RESB-WEMPF (2nd link)
      APPEND ls_item TO lt_items.
    ENDLOOP.

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
      DATA(lv_msg) = VALUE string( lt_return[ type = 'E' ]-message OPTIONAL ).
      LOOP AT ct_out ASSIGNING <o>.
        <o>-status  = gc_error.
        <o>-statxt  = 'Create error'.
        <o>-message = lv_msg.
      ENDLOOP.
    ELSE.
      CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X'.
      " item numbers are assigned in the sequence of LT_ITEMS
      SELECT rspos FROM resb INTO TABLE @lt_rspos
        WHERE rsnum = @lv_resno
        ORDER BY rspos.
      LOOP AT ct_out ASSIGNING <o>.
        DATA(lv_idx) = sy-tabix.
        <o>-rsnum   = lv_resno.
        <o>-rspos   = VALUE #( lt_rspos[ lv_idx ] DEFAULT lv_idx ).
        <o>-status  = gc_created.
        <o>-statxt  = 'Created'.
        <o>-message = |Reservation { lv_resno } created|.
      ENDLOOP.
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

    DATA: lt_items  TYPE STANDARD TABLE OF bapi2093_res_item_change,
          lt_itemsx TYPE STANDARD TABLE OF bapi2093_res_item_changex,
          lt_return TYPE STANDARD TABLE OF bapiret2,
          ls_i      TYPE bapi2093_res_item_change,
          ls_ix     TYPE bapi2093_res_item_changex.

    " Items are created in base UoM (ENTRY_UOM = MEINS), so changing ENTRY_QNT
    " sets the requirement quantity RESB-BDMNG.
    ls_i-res_item  = cs_out-rspos.
    ls_i-entry_qnt = lv_newqty.
    APPEND ls_i TO lt_items.

    ls_ix-res_item  = cs_out-rspos.
    ls_ix-entry_qnt = 'X'.
    APPEND ls_ix TO lt_itemsx.

    CALL FUNCTION 'BAPI_RESERVATION_CHANGE'
      EXPORTING
        reservation               = cs_out-rsnum
      TABLES
        reservationitems_changed  = lt_items
        reservationitems_changedx = lt_itemsx
        return                    = lt_return.

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
                         werks_fr   = p_werkfr
                         werks_to   = p_werkto
                         test_run   = p_test
                         self_sched = p_sched
                         freq_value = p_freq
                         freq_unit  = p_funit
                         start_date = sy-datum
                         start_time = sy-uzeit
                         status     = 'R'
                         ernam      = sy-uname
                         sel_text   = |FR { p_werkfr } TO { p_werkto } DATE { p_rsdat }| ).
    MODIFY zptp_301_run_log FROM @ms_counts.
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
    MODIFY zptp_301_run_log FROM @ms_counts.
    COMMIT WORK.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD write_detail_log.
    DATA ls_log TYPE zptp_301_res_log.
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
    MODIFY zptp_301_res_log FROM @ls_log.
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
    SELECT SINGLE active FROM zptp_301_ctrl INTO @DATA(lv_a)
      WHERE werks_fr = @p_werkfr AND werks_to = @p_werkto.
    rv_active = xsdbool( sy-subrc = 0 AND lv_a = abap_true ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD schedule_next_run.
    " next start = now + interval
    DATA: lv_date TYPE d, lv_time TYPE t, lv_ts TYPE timestamp.
    lv_date = sy-datum. lv_time = sy-uzeit.
    CONVERT DATE lv_date TIME lv_time INTO TIME STAMP lv_ts TIME ZONE sy-zonlo.
    lv_ts = cl_abap_tstmp=>add_to_short( tstmp = lv_ts secs = interval_in_seconds( ) ).
    CONVERT TIME STAMP lv_ts TIME ZONE sy-zonlo INTO DATE lv_date TIME lv_time.

    DATA: lv_jobname  TYPE btcjob VALUE 'ZPTP_301_RES_CHAIN',
          lv_jobcount TYPE btcjobcnt.

    CALL FUNCTION 'JOB_OPEN'
      EXPORTING jobname = lv_jobname
      IMPORTING jobcount = lv_jobcount
      EXCEPTIONS OTHERS = 1.
    IF sy-subrc <> 0. RETURN. ENDIF.

    SUBMIT zptp_301_reservation_generator
      WITH p_werkfr = p_werkfr
      WITH p_lgorfr = p_lgorfr
      WITH p_werkto = p_werkto
      WITH p_lgorto = p_lgorto
      WITH p_rsdat   = p_rsdat
      WITH p_move    = p_move
      WITH p_test    = p_test
      WITH p_erron   = p_erron
      WITH p_sched   = p_sched
      WITH p_freq    = p_freq
      WITH p_funit   = p_funit
      WITH p_rawmat  = p_rawmat
      WITH p_werkrf  = p_werkrf
      WITH p_lgorrf  = p_lgorrf
      WITH p_werkrt  = p_werkrt
      WITH p_lgorrt  = p_lgorrt
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
    MODIFY zptp_301_run_log FROM @ms_counts.
    COMMIT WORK.
    MESSAGE s039(zptp_split_val) WITH lv_date lv_time.
  ENDMETHOD.

ENDCLASS.

*---------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
  " listbox values for the frequency unit
  CALL FUNCTION 'VRM_SET_VALUES'
    EXPORTING
      id     = 'P_FUNIT'
      values = VALUE vrm_values( ( key = 'MIN' text = TEXT-l01 )
                                 ( key = 'HRS' text = TEXT-l02 )
                                 ( key = 'DAY' text = TEXT-l03 ) )
    EXCEPTIONS
      OTHERS = 1.

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
