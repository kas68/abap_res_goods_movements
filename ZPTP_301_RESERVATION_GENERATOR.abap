*&---------------------------------------------------------------------*
*& Report  ZPTP_301_RESERVATION_GENERATOR
*&---------------------------------------------------------------------*
*& Create / align 301 transfer reservations for open production orders
*& (origin plant 8P01 -> destination plant 8Q01).
*&
*& Reservation remaining (BDMNG - ENMNG) is kept equal to PO remaining
*& (PSMNG - WEMNG). The 301 movements that consume the reservation are posted
*& by report ZPTP_301_RESERVATION_TRANSFER, NOT by this program.
*&
*& Finished product (AFPO-MATNR, 8P01 -> 8Q01): released orders only.
*& Raw materials (P_KIND = R / A, 8Q01 -> 8P01): open orders (created
*& or released). The short components of an order go into their own
*& reservation, independent of the finished-product reservation.
*&
*& Storage locations: source = storage location of the order (AFPO-LGORT);
*& target = table ZPTP_301_LGORT (direction, plant pair, source storage
*& location, material type). Storage locations typed on the selection screen
*& override.
*&
*& Collective orders (option P_COLL): finished product only for the leading
*& order, components only for the lowest-level order.
*& Exclusion list (option P_EXCL): orders listed in table ZPTP_301_EXCL get
*& no finished-product / component reservation; the list is loaded from a
*& local .xlsx at an online run and then read from the table by every run.
*&
*& NOTE: BAPI field names for the reservation change/close path should be
*&       verified against the target release.
*&---------------------------------------------------------------------*
REPORT zptp_301_reservation_generator.

TYPE-POOLS abap.

*---------------------------------------------------------------------*
* Selection screen
*---------------------------------------------------------------------*
" derived switches for the reservation kind (P_KIND)
DATA: gv_do_h TYPE abap_bool,    " process finished products
      gv_do_r TYPE abap_bool.    " process raw-material components

SELECTION-SCREEN BEGIN OF BLOCK b3 WITH FRAME TITLE TEXT-003. " Run control
SELECTION-SCREEN BEGIN OF BLOCK b3c WITH FRAME TITLE TEXT-009. " Reservation kind
PARAMETERS: p_kind TYPE char1 DEFAULT 'A'               " H finished products / R components / A all
                   AS LISTBOX VISIBLE LENGTH 20 USER-COMMAND kin.
SELECTION-SCREEN COMMENT /1(70) TEXT-010.                      " H = finished products
SELECTION-SCREEN COMMENT /1(70) TEXT-011.                      " R = components (raw materials)
SELECTION-SCREEN COMMENT /1(70) TEXT-012.                      " A = all
SELECTION-SCREEN END OF BLOCK b3c.
SELECTION-SCREEN BEGIN OF BLOCK b3a WITH FRAME TITLE TEXT-007. " Run mode
PARAMETERS: r_test RADIOBUTTON GROUP mod,                      " 1 test: simulation, nothing created
            r_onl  RADIOBUTTON GROUP mod DEFAULT 'X',          " 2 online: simulation first, create the ticked orders
            r_back RADIOBUTTON GROUP mod.                      " 3 background: all reservations are created
SELECTION-SCREEN END OF BLOCK b3a.
SELECTION-SCREEN BEGIN OF BLOCK b3b WITH FRAME TITLE TEXT-008. " Options
PARAMETERS: p_move  AS CHECKBOX DEFAULT 'X',                   " movement-relevant
            p_erron AS CHECKBOX,                               " reprocess errors only
            p_extsl AS CHECKBOX DEFAULT 'X',                   " extend material to the target storage location
            p_clrlg AS CHECKBOX.                               " clean all logs (run log + item log) before the run
SELECTION-SCREEN END OF BLOCK b3b.
SELECTION-SCREEN END OF BLOCK b3.

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
SELECTION-SCREEN BEGIN OF BLOCK b6 WITH FRAME TITLE TEXT-006. " Collective orders / exclusions
PARAMETERS: p_coll AS CHECKBOX DEFAULT 'X',                               " collective orders: leading / lowest level only
            p_excl AS CHECKBOX USER-COMMAND exl,               " apply the exclusion list (ZPTP_301_EXCL)
            p_file TYPE rlgrap-filename MODIF ID exl.          " spreadsheet (.xlsx) to upload from local PC
SELECTION-SCREEN END OF BLOCK b6.
SELECTION-SCREEN END OF BLOCK b2.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001. " Plants / locations
PARAMETERS: p_werkfr TYPE werks_d OBLIGATORY DEFAULT '8P01', " origin plant
            p_lgorfr TYPE lgort_d,                            " origin stor.loc
            p_werkto TYPE werks_d OBLIGATORY DEFAULT '8Q01', " destination plant
            p_lgorto TYPE lgort_d.                            " destination stor.loc
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b5 WITH FRAME TITLE TEXT-005. " Raw materials
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
           gc_kind_r    TYPE c VALUE 'R'.         " raw-material comp (8Q01 -> 8P01)

*---------------------------------------------------------------------*
* Local class : application engine
*---------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.

  PUBLIC SECTION.
    TYPES: BEGIN OF ty_out,
             sel          TYPE abap_bool,     " online mode: create the reservations of this order
             res_kind     TYPE c LENGTH 1,   " H = finished product / R = raw material
             aufnr        TYPE aufnr,
             lead_aufnr   TYPE aufnr,         " leading order of the collective order (blank if none)
             is_lead      TYPE abap_bool,     " X = this order is the leading order of a collective order
             auart        TYPE aufart,
             posnr        TYPE co_posnr,      " 0001 (H) or component RSPOS (R)
             matnr        TYPE matnr,
             maktx        TYPE maktx,         " material description (ALV only)
             mtart        TYPE mtart,         " material type (ALV only)
             charg        TYPE charg_d,       " batch of the production order / component (set on the reservation)
             in_target    TYPE abap_bool,     " X = material is extended to the target plant (ALV only)
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
             coltab       TYPE lvc_t_scol,    " ALV row colour
             cellstyle    TYPE lvc_t_styl,    " ALV cell style (bold)
           END OF ty_out.
    TYPES tt_out TYPE STANDARD TABLE OF ty_out WITH DEFAULT KEY.

    METHODS constructor.
    METHODS run.
    " ALV function codes of the online mode
    METHODS user_command
      IMPORTING iv_ucomm TYPE sy-ucomm.

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
             lgort TYPE lgort_d,            " storage location of the order item (AFPO-LGORT)
             charg TYPE charg_d,            " batch of the order item (AFPO-CHARG)
             rel   TYPE abap_bool,          " order released (REL)
           END OF ty_ord.
    TYPES tt_ord TYPE STANDARD TABLE OF ty_ord WITH DEFAULT KEY.

    TYPES: BEGIN OF ty_coll,
             aufnr  TYPE aufnr,
             coll   TYPE abap_bool,          " order is part of a collective order
             leader TYPE aufnr,              " leading order of the collective order
             lead   TYPE abap_bool,          " leading (top) order, or not collective
             lowest TYPE abap_bool,          " lowest-level order, or not collective
           END OF ty_coll.

    TYPES: BEGIN OF ty_lgort,
             kind     TYPE c LENGTH 1,
             matnr    TYPE matnr,
             werks_fr TYPE werks_d,
             werks_to TYPE werks_d,
             src      TYPE lgort_d,          " source storage location as given (lookup key)
             lgort_fr TYPE lgort_d,          " source storage location determined
             lgort_to TYPE lgort_d,          " target storage location determined
           END OF ty_lgort.

    DATA: mt_lgort  TYPE SORTED TABLE OF ty_lgort
                         WITH UNIQUE KEY kind matnr werks_fr werks_to src,       " cache
          mt_coll   TYPE SORTED TABLE OF ty_coll WITH UNIQUE KEY aufnr,   " cache
          mt_excl   TYPE SORTED TABLE OF zptp_301_excl WITH UNIQUE KEY aufnr,
          mt_out    TYPE tt_out,
          mt_orders TYPE tt_ord,          " open orders of the run (online mode creates from them)
          mv_simulate TYPE abap_bool,     " X = nothing is created or changed (test, online first pass)
          mv_run_id TYPE sysuuid_c32,
          mv_mode   TYPE c LENGTH 1,    " O / B
          ms_counts TYPE zptp_301_run_log.

    METHODS validate_selection.
    " Process a list of orders: finished product (released) and raw materials
    METHODS process_list
      IMPORTING it_orders TYPE tt_ord.
    METHODS roll_up.
    " Online mode: create the reservations of the orders ticked in the ALV
    METHODS create_selected.
    METHODS build_fcat
      RETURNING VALUE(rt_fcat) TYPE lvc_t_fcat.
    METHODS enrich_out.
    " Storage locations of a reservation item. Source: the storage location of
    " the order (IV_SRC) unless overridden on the screen. Target: table
    " ZPTP_301_LGORT read with the source storage location, unless overridden.
    METHODS resolve_lgort
      IMPORTING iv_kind     TYPE c
                iv_matnr    TYPE matnr
                iv_werks_fr TYPE werks_d
                iv_werks_to TYPE werks_d
                iv_src      TYPE lgort_d
                iv_ovr_fr   TYPE lgort_d
                iv_ovr_to   TYPE lgort_d
      EXPORTING ev_lgor_fr  TYPE lgort_d
                ev_lgor_to  TYPE lgort_d.
    METHODS check_lgort_table.
    " Target storage location from ZPTP_301_LGORT for one source storage location
    METHODS lookup_target
      IMPORTING iv_kind          TYPE c
                iv_mtart         TYPE mtart
                iv_werks_fr      TYPE werks_d
                iv_werks_to      TYPE werks_d
                iv_lgort_fr      TYPE lgort_d
      RETURNING VALUE(rv_lgort_to) TYPE lgort_d.
    METHODS select_open_orders
      RETURNING VALUE(rt_orders) TYPE tt_ord.
    " Option 1 : collective orders (leading order / lowest level)
    METHODS collective_role
      IMPORTING iv_aufnr TYPE aufnr
      RETURNING VALUE(rs_role) TYPE ty_coll.
    " Option 2 : exclusion list (uploaded spreadsheet, kept in ZPTP_301_EXCL)
    METHODS load_exclusions.
    METHODS upload_exclusions.
    " Reason text if the order must NOT get a reservation of this kind, else blank
    METHODS exclusion_reason
      IMPORTING iv_kind        TYPE c
                iv_aufnr       TYPE aufnr
      RETURNING VALUE(rv_text) TYPE string.
    METHODS log_skip
      IMPORTING is_order TYPE ty_ord
                iv_kind  TYPE c
                iv_text  TYPE string.
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
                iv_charg    TYPE charg_d OPTIONAL   " batch of the order / component
      CHANGING  ct_new      TYPE tt_out OPTIONAL.
    " One reservation with one item per row of CT_OUT
    " Empty table for the mandatory table parameter PROFITABILITYSEGMENT of
    " BAPI_RESERVATION_CREATE1 (type taken from the function interface)
    METHODS profit_table
      RETURNING VALUE(rr_tab) TYPE REF TO data.
    " Extend the material to the target storage location (storage location view),
    " copying the data of the source storage location. EV_MSG is filled on error.
    METHODS extend_sloc
      IMPORTING iv_matnr    TYPE matnr
                iv_werks_fr TYPE werks_d
                iv_lgort_fr TYPE lgort_d
                iv_werks_to TYPE werks_d
                iv_lgort_to TYPE lgort_d
      EXPORTING ev_msg      TYPE string
                ev_done     TYPE abap_bool.
    METHODS create_reservation
      CHANGING  ct_out   TYPE tt_out.
    METHODS change_reservation
      IMPORTING iv_close TYPE abap_bool
      CHANGING  cs_out   TYPE ty_out.
    METHODS clear_logs.
    METHODS start_run_log.
    METHODS finish_run_log IMPORTING iv_status TYPE c.
    METHODS write_detail_log IMPORTING is_out TYPE ty_out.
    METHODS display_alv.

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
    " Run modes:  r_test   test: simulation, nothing is created or changed
    "             r_back   background: all reservations are created / aligned / closed
    "             r_onl    online: simulation first, the user ticks orders in the
    "                      ALV and the reservations of those orders are created
    mv_simulate = xsdbool( r_back = abap_false ).

    validate_selection( ).
    clear_logs( ).
    start_run_log( ).

    load_exclusions( ).
    mt_orders = select_open_orders( ).
    ms_counts-cnt_selected = lines( mt_orders ).

    IF mt_orders IS INITIAL.
      MESSAGE s028(zptp_split_val).
    ENDIF.

    process_list( mt_orders ).

    IF r_onl = abap_true.
      display_alv( ).                              " interactive: creates the ticked orders
    ENDIF.

    roll_up( ).
    DATA(lv_final) = COND char1( WHEN ms_counts-cnt_error > 0 THEN 'W' ELSE 'S' ).
    finish_run_log( lv_final ).

    IF r_onl = abap_false AND mv_mode = 'O'.
      display_alv( ).
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD process_list.
    LOOP AT it_orders ASSIGNING FIELD-SYMBOL(<order>).
      IF <order>-rel = abap_true AND gv_do_h = abap_true.
        process_order( <order> ).               " finished product (8P01 -> 8Q01)
      ENDIF.
      IF gv_do_r = abap_true.
        process_raw_components( <order> ).      " raw materials (8Q01 -> 8P01)
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD roll_up.
    " counters from the result table
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
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD user_command.
    CASE iv_ucomm.
      WHEN 'CREATE'.
        create_selected( ).
    ENDCASE.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD create_selected.
    " Ticked lines -> distinct production orders. All lines of those orders
    " (finished product and raw materials) are processed again for real and
    " replace their simulated lines.
    DATA lt_sel  TYPE SORTED TABLE OF aufnr WITH UNIQUE KEY table_line.
    DATA lt_todo TYPE tt_ord.

    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<s>) WHERE sel = abap_true.
      INSERT <s>-aufnr INTO TABLE lt_sel.
    ENDLOOP.
    IF lt_sel IS INITIAL.
      MESSAGE 'No production order selected' TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.

    LOOP AT mt_orders INTO DATA(ls_ord).
      IF line_exists( lt_sel[ table_line = ls_ord-aufnr ] ).
        APPEND ls_ord TO lt_todo.
      ENDIF.
    ENDLOOP.

    LOOP AT lt_sel INTO DATA(lv_aufnr).
      DELETE mt_out WHERE aufnr = lv_aufnr.
    ENDLOOP.

    mv_simulate = abap_false.
    process_list( lt_todo ).
    mv_simulate = abap_true.

    enrich_out( ).
    MESSAGE |{ lines( lt_todo ) } production order(s) processed| TYPE 'S'.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD validate_selection.
    IF r_onl = abap_true AND sy-batch = abap_true.
      MESSAGE 'Online mode cannot run in the background' TYPE 'E'.
    ENDIF.
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
    " raw-material plants (only relevant when the option is active)
    IF gv_do_r = abap_true.
      IF p_werkrf IS INITIAL OR p_werkrt IS INITIAL OR p_werkrf = p_werkrt.
        MESSAGE e042(zptp_split_val) WITH p_werkrf p_werkrt.   " RM plants required and must differ
      ENDIF.
      SELECT SINGLE werks FROM t001w INTO @lv_w WHERE werks = @p_werkrf.
      IF sy-subrc <> 0. MESSAGE e040(zptp_split_val) WITH p_werkrf. ENDIF.
      SELECT SINGLE werks FROM t001w INTO @lv_w WHERE werks = @p_werkrt.
      IF sy-subrc <> 0. MESSAGE e040(zptp_split_val) WITH p_werkrt. ENDIF.
    ENDIF.
    check_lgort_table( ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD check_lgort_table.
    " Storage locations maintained in ZPTP_301_LGORT for the plant pair(s) of
    " this run must exist in the plant.
    DATA lt_chk TYPE STANDARD TABLE OF zptp_301_lgort WITH DEFAULT KEY.

    IF gv_do_h = abap_true.
      SELECT * FROM zptp_301_lgort INTO TABLE @lt_chk
        WHERE res_kind = @gc_kind_h
          AND werks_fr = @p_werkfr
          AND werks_to = @p_werkto.
    ENDIF.
    IF gv_do_r = abap_true.
      SELECT * FROM zptp_301_lgort APPENDING TABLE @lt_chk
        WHERE res_kind = @gc_kind_r
          AND werks_fr = @p_werkrf
          AND werks_to = @p_werkrt.
    ENDIF.

    LOOP AT lt_chk ASSIGNING FIELD-SYMBOL(<l>).
      IF <l>-lgort_fr IS NOT INITIAL.
        SELECT SINGLE lgort FROM t001l INTO @DATA(lv_l)
          WHERE werks = @<l>-werks_fr AND lgort = @<l>-lgort_fr.
        IF sy-subrc <> 0. MESSAGE e041(zptp_split_val) WITH <l>-lgort_fr <l>-werks_fr. ENDIF.
      ENDIF.
      IF <l>-lgort_to IS NOT INITIAL.
        SELECT SINGLE lgort FROM t001l INTO @lv_l
          WHERE werks = @<l>-werks_to AND lgort = @<l>-lgort_to.
        IF sy-subrc <> 0. MESSAGE e041(zptp_split_val) WITH <l>-lgort_to <l>-werks_to. ENDIF.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD resolve_lgort.
    " Source storage location: screen override, else the one given by the order.
    " Target storage location: screen override, else table ZPTP_301_LGORT read with
    "   kind + plant pair + source storage location + material type (most specific
    "   entry wins: source storage location first, blank = any; then material
    "   type, blank = all).
    " Fallback when no source storage location is known: the storage locations
    "   of the source plant holding the material (most unrestricted stock first)
    "   are tried one after the other. The first one that gives a target in the
    "   table is used as source and target. If none gives a target, the source is
    "   the storage location with the most unrestricted stock (if any) and the
    "   target stays blank.
    DATA(lv_src) = COND lgort_d( WHEN iv_ovr_fr IS NOT INITIAL THEN iv_ovr_fr ELSE iv_src ).

    READ TABLE mt_lgort INTO DATA(ls_c)
         WITH KEY kind = iv_kind matnr = iv_matnr
                  werks_fr = iv_werks_fr werks_to = iv_werks_to src = lv_src.
    IF sy-subrc <> 0.
      ls_c = VALUE #( kind = iv_kind matnr = iv_matnr
                      werks_fr = iv_werks_fr werks_to = iv_werks_to
                      src = lv_src lgort_fr = lv_src ).

      " candidates for the source storage location
      DATA lt_cand TYPE STANDARD TABLE OF lgort_d WITH EMPTY KEY.
      DATA(lv_stock_first) = VALUE lgort_d( ).
      IF lv_src IS NOT INITIAL.
        lt_cand = VALUE #( ( lv_src ) ).
      ELSE.
        SELECT lgort, labst FROM mard
          WHERE matnr = @iv_matnr AND werks = @iv_werks_fr
          INTO TABLE @DATA(lt_mard).
        SORT lt_mard BY labst DESCENDING.
        lt_cand = VALUE #( FOR m IN lt_mard ( m-lgort ) ).
        IF lt_mard IS NOT INITIAL AND lt_mard[ 1 ]-labst > 0.
          lv_stock_first = lt_mard[ 1 ]-lgort.
        ENDIF.
        IF lt_cand IS INITIAL.
          APPEND space TO lt_cand.        " rows with a blank source storage location still match
        ENDIF.
      ENDIF.

      IF iv_ovr_to IS INITIAL.
        SELECT SINGLE mtart FROM mara INTO @DATA(lv_mtart) WHERE matnr = @iv_matnr.
        LOOP AT lt_cand INTO DATA(lv_cand).
          DATA(lv_to) = lookup_target( iv_kind     = iv_kind
                                       iv_mtart    = lv_mtart
                                       iv_werks_fr = iv_werks_fr
                                       iv_werks_to = iv_werks_to
                                       iv_lgort_fr = lv_cand ).
          IF lv_to IS NOT INITIAL.
            ls_c-lgort_fr = lv_cand.
            ls_c-lgort_to = lv_to.
            EXIT.
          ENDIF.
        ENDLOOP.
      ENDIF.
      " nothing mapped: keep the given source, or the one with the most stock
      IF ls_c-lgort_to IS INITIAL AND ls_c-lgort_fr IS INITIAL.
        ls_c-lgort_fr = lv_stock_first.
      ENDIF.
      INSERT ls_c INTO TABLE mt_lgort.
    ENDIF.

    ev_lgor_fr = ls_c-lgort_fr.
    ev_lgor_to = COND #( WHEN iv_ovr_to IS NOT INITIAL THEN iv_ovr_to ELSE ls_c-lgort_to ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD lookup_target.
    " Most specific row wins: source storage location (blank = any), then
    " material type (blank = all). Sorted here to keep the SELECT simple.
    SELECT lgort_fr, mtart, lgort_to FROM zptp_301_lgort
      WHERE res_kind = @iv_kind
        AND werks_fr = @iv_werks_fr
        AND werks_to = @iv_werks_to
        AND ( lgort_fr = @iv_lgort_fr OR lgort_fr = @space )
        AND ( mtart    = @iv_mtart    OR mtart    = @space )
      INTO TABLE @DATA(lt_map).
    IF lt_map IS INITIAL.
      RETURN.
    ENDIF.
    SORT lt_map BY lgort_fr DESCENDING mtart DESCENDING.
    rv_lgort_to = lt_map[ 1 ]-lgort_to.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD select_open_orders.
    DATA lt_ord TYPE tt_ord.

    SELECT k~aufnr, k~auart, k~objnr,
           p~posnr, p~matnr, p~psmng, p~wemng, p~meins, p~elikz, p~lgort, p~charg,
           f~dispo
      FROM aufk AS k
      INNER JOIN afko AS f ON f~aufnr = k~aufnr
      INNER JOIN afpo AS p ON p~aufnr = k~aufnr
      INTO CORRESPONDING FIELDS OF TABLE @lt_ord
      WHERE k~werks   = @p_werkfr
        AND k~aufnr  IN @so_aufnr
        AND k~auart  IN @so_auart
        AND p~posnr   = '0001'                " header item only (no co-products)
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
      IF gv_do_r = abap_false AND ( <ord>-rel = abap_false OR gv_do_h = abap_false ).
        DELETE lt_ord.  " not released (or finished products not wanted) and no RM -> ignore
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

    DATA(lv_skip) = exclusion_reason( iv_kind = gc_kind_h iv_aufnr = is_order-aufnr ).
    IF lv_skip IS NOT INITIAL.
      log_skip( is_order = is_order iv_kind = gc_kind_h iv_text = lv_skip ).
      RETURN.
    ENDIF.

    resolve_lgort( EXPORTING iv_kind     = gc_kind_h
                             iv_matnr    = is_order-matnr
                             iv_werks_fr = p_werkfr
                             iv_werks_to = p_werkto
                             iv_src      = is_order-lgort
                             iv_ovr_fr   = p_lgorfr
                             iv_ovr_to   = p_lgorto
                   IMPORTING ev_lgor_fr  = DATA(lv_lgor_fr)
                             ev_lgor_to  = DATA(lv_lgor_to) ).

    reconcile_item(
      iv_kind     = gc_kind_h
      iv_aufnr    = is_order-aufnr
      iv_posnr    = '0001'
      iv_matnr    = is_order-matnr
      iv_basis    = lv_po_open
      iv_meins    = is_order-meins
      iv_werks_fr = p_werkfr
      iv_lgor_fr  = lv_lgor_fr
      iv_werks_to = p_werkto
      iv_lgor_to  = lv_lgor_to
      iv_to_close = lv_to_close
      iv_wemng    = is_order-wemng
      iv_charg    = is_order-charg ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD process_raw_components.
    " Raw-material components (8Q01 -> 8P01) that are SHORT in the production
    " plant. Components not yet reserved are created together in one
    " reservation per order, separate from the finished-product reservation.
    DATA lt_new TYPE tt_out.
    DATA(lv_to_close) = xsdbool( is_order-elikz = 'C' ).

    DATA(lv_skip) = exclusion_reason( iv_kind = gc_kind_r iv_aufnr = is_order-aufnr ).
    IF lv_skip IS NOT INITIAL.
      log_skip( is_order = is_order iv_kind = gc_kind_r iv_text = lv_skip ).
      RETURN.
    ENDIF.

    " Open component requirements of the production order.
    " POSTP = 'L' -> stock item only (excludes non-stock 'N', text 'T', phantom).
    SELECT rspos, matnr, bdmng, enmng, meins, werks, bdter, charg
      FROM resb INTO TABLE @DATA(lt_comp)
      WHERE aufnr = @is_order-aufnr
        AND werks = @p_werkrt          " requirement at the production plant
        AND matnr <> @space
        AND postp = 'L'                " stock item
        AND shkzg = 'H'                " issue only (excludes by-products, receipts)
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

      resolve_lgort( EXPORTING iv_kind     = gc_kind_r
                               iv_matnr    = <c>-matnr
                               iv_werks_fr = p_werkrf
                               iv_werks_to = p_werkrt
                               iv_src      = space      " no source location in the order (8Q01 side)
                               iv_ovr_fr   = p_lgorrf
                               iv_ovr_to   = p_lgorrt
                     IMPORTING ev_lgor_fr  = DATA(lv_rm_fr)
                               ev_lgor_to  = DATA(lv_rm_to) ).

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
          iv_lgor_fr  = lv_rm_fr
          iv_werks_to = p_werkrt         " receiving = production plant (8P01)
          iv_lgor_to  = lv_rm_to
          iv_to_close = COND #( WHEN lv_short <= 0 THEN abap_true ELSE lv_to_close )
          iv_charg    = <c>-charg
        CHANGING
          ct_new      = lt_new ).
    ENDLOOP.

    " One RM reservation for all newly short components of this order. The
    " receiving storage location is a reservation header field, so components
    " with a different receiving storage location go into separate reservations.
    IF lt_new IS NOT INITIAL.
      DATA: lt_grp  TYPE tt_out,
            lt_done TYPE tt_out.
      SORT lt_new BY lgort_to.
      LOOP AT lt_new ASSIGNING FIELD-SYMBOL(<n>).
        IF lt_grp IS NOT INITIAL AND <n>-lgort_to <> lt_grp[ 1 ]-lgort_to.
          create_reservation( CHANGING ct_out = lt_grp ).
          APPEND LINES OF lt_grp TO lt_done.
          CLEAR lt_grp.
        ENDIF.
        APPEND <n> TO lt_grp.
      ENDLOOP.
      IF lt_grp IS NOT INITIAL.
        create_reservation( CHANGING ct_out = lt_grp ).
        APPEND LINES OF lt_grp TO lt_done.
      ENDIF.
      LOOP AT lt_done ASSIGNING FIELD-SYMBOL(<d>).
        APPEND <d> TO mt_out.
        write_detail_log( <d> ).
      ENDLOOP.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD collective_role.
    " Collective order hierarchy from AFKO:
    "   PRODNET = 'X' : order is part of a collective order
    "   MAUFNR        : number of the superior order (blank on the leading order)
    "   leading order : part of a collective order, no superior order
    "   lowest level  : part of a collective order, no order has it as superior
    " An order that is not part of a collective order is both (normal behaviour).
    READ TABLE mt_coll INTO rs_role WITH KEY aufnr = iv_aufnr.
    IF sy-subrc = 0.
      RETURN.
    ENDIF.

    rs_role-aufnr  = iv_aufnr.
    rs_role-lead   = abap_true.
    rs_role-lowest = abap_true.

    SELECT SINGLE maufnr, prodnet FROM afko INTO @DATA(ls_afko)
      WHERE aufnr = @iv_aufnr.
    IF sy-subrc = 0 AND ls_afko-prodnet = abap_true.
      rs_role-coll = abap_true.
      SELECT SINGLE aufnr FROM afko INTO @DATA(lv_below)
        WHERE maufnr = @iv_aufnr.
      rs_role-lowest = xsdbool( sy-subrc <> 0 ).
      rs_role-lead   = xsdbool( ls_afko-maufnr IS INITIAL ).
      " leading order: climb the superior orders up to the top
      DATA(lv_cur) = iv_aufnr.
      DATA(lv_up)  = ls_afko-maufnr.
      DO 20 TIMES.
        IF lv_up IS INITIAL.
          EXIT.
        ENDIF.
        lv_cur = lv_up.
        SELECT SINGLE maufnr FROM afko INTO @lv_up WHERE aufnr = @lv_cur.
      ENDDO.
      rs_role-leader = lv_cur.
    ENDIF.
    INSERT rs_role INTO TABLE mt_coll.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD exclusion_reason.
    " Option 1 : collective orders
    IF p_coll = abap_true.
      DATA(ls_role) = collective_role( iv_aufnr ).
      IF iv_kind = gc_kind_h AND ls_role-lead = abap_false.
        rv_text = 'Collective order: not the leading order'.
        RETURN.
      ENDIF.
      IF iv_kind = gc_kind_r AND ls_role-lowest = abap_false.
        rv_text = 'Collective order: not the lowest-level order'.
        RETURN.
      ENDIF.
    ENDIF.
    " Option 2 : exclusion list
    IF p_excl = abap_true.
      READ TABLE mt_excl INTO DATA(ls_excl) WITH KEY aufnr = iv_aufnr.
      IF sy-subrc = 0.
        IF ( iv_kind = gc_kind_h AND ls_excl-excl_h = abap_true )
        OR ( iv_kind = gc_kind_r AND ls_excl-exclr = abap_true ).
          rv_text = 'Order on exclusion list'.
        ENDIF.
      ENDIF.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD log_skip.
    " Visible in the ALV and the detail log, like 'Fully received'.
    " Existing reservations of a skipped order are left untouched.
    DATA(ls_out) = VALUE ty_out(
      res_kind = iv_kind
      aufnr    = is_order-aufnr
      auart    = is_order-auart
      posnr    = COND #( WHEN iv_kind = gc_kind_h THEN '0001' ELSE '0000' )
      matnr    = COND #( WHEN iv_kind = gc_kind_h THEN is_order-matnr )
      meins    = is_order-meins
      status   = gc_skipped
      statxt   = iv_text ).
    APPEND ls_out TO mt_out.
    write_detail_log( ls_out ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD load_exclusions.
    IF p_excl = abap_false.
      RETURN.
    ENDIF.
    " online run with a file: replace the stored list with the spreadsheet
    IF p_file IS NOT INITIAL.
      upload_exclusions( ).
    ENDIF.
    " every run (online / background chain) reads the stored list
    SELECT * FROM zptp_301_excl INTO TABLE @mt_excl.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD upload_exclusions.
    " Spreadsheet (.xlsx) layout - column A, row 1 may be a header:
    "   worksheet 1 : production orders WITHOUT finished-product reservation (8P01 -> 8Q01)
    "   worksheet 2 : production orders WITHOUT component reservation        (8Q01 -> 8P01)
    " The upload REPLACES the stored list (the file is the complete list).
    IF sy-batch = abap_true.
      MESSAGE 'The exclusion file can only be uploaded online' TYPE 'E'.
    ENDIF.

    DATA: lt_bin  TYPE solix_tab,
          lv_len  TYPE i,
          lt_new  TYPE SORTED TABLE OF zptp_301_excl WITH UNIQUE KEY aufnr.

    cl_gui_frontend_services=>gui_upload(
      EXPORTING  filename   = CONV string( p_file )
                 filetype   = 'BIN'
      IMPORTING  filelength = lv_len
      CHANGING   data_tab   = lt_bin
      EXCEPTIONS OTHERS     = 1 ).
    IF sy-subrc <> 0.
      MESSAGE 'Exclusion file cannot be read' TYPE 'E'.
    ENDIF.
    DATA(lv_xstr) = cl_bcs_convert=>solix_to_xstring( it_solix = lt_bin iv_size = lv_len ).

    TRY.
        DATA(lo_xl) = NEW cl_fdt_xl_spreadsheet( document_name = CONV string( p_file )
                                                 xdocument     = lv_xstr ).
        lo_xl->if_fdt_doc_spreadsheet~get_worksheet_names(
          IMPORTING worksheet_names = DATA(lt_sheets) ).
        IF lines( lt_sheets ) < 2.
          MESSAGE 'The file needs two worksheets (finished product / components)' TYPE 'E'.
        ENDIF.

        DO 2 TIMES.
          DATA(lv_sheet) = sy-index.
          DATA(lr_data) = lo_xl->if_fdt_doc_spreadsheet~get_itab_from_worksheet(
                            lt_sheets[ lv_sheet ] ).
          ASSIGN lr_data->* TO FIELD-SYMBOL(<tab>).
          LOOP AT <tab> ASSIGNING FIELD-SYMBOL(<row>).
            ASSIGN COMPONENT 1 OF STRUCTURE <row> TO FIELD-SYMBOL(<cell>).
            IF sy-subrc <> 0.
              CONTINUE.
            ENDIF.
            DATA(lv_txt) = condense( CONV string( <cell> ) ).
            REPLACE PCRE '\.0+$' IN lv_txt WITH ''.         " 1000123.0 -> 1000123
            IF lv_txt IS INITIAL OR lv_txt CN '0123456789'.   " header / junk row
              CONTINUE.
            ENDIF.
            DATA lv_aufnr TYPE aufnr.
            CALL FUNCTION 'CONVERSION_EXIT_ALPHA_INPUT'
              EXPORTING input  = lv_txt
              IMPORTING output = lv_aufnr.
            ASSIGN lt_new[ aufnr = lv_aufnr ] TO FIELD-SYMBOL(<n>).
            IF sy-subrc <> 0.
              INSERT VALUE #( aufnr = lv_aufnr ) INTO TABLE lt_new ASSIGNING <n>.
            ENDIF.
            IF lv_sheet = 1. <n>-excl_h = abap_true. ELSE. <n>-exclr = abap_true. ENDIF.
          ENDLOOP.
        ENDDO.
      CATCH cx_root INTO DATA(lx).
        MESSAGE lx->get_text( ) TYPE 'E'.
    ENDTRY.

    LOOP AT lt_new ASSIGNING FIELD-SYMBOL(<u>).
      <u>-upl_date = sy-datum.
      <u>-upl_by   = sy-uname.
    ENDLOOP.

    DELETE FROM zptp_301_excl.
    INSERT zptp_301_excl FROM TABLE @( VALUE #( FOR u IN lt_new ( u ) ) ).
    COMMIT WORK.
    MESSAGE |Exclusion list uploaded: { lines( lt_new ) } orders| TYPE 'S'.
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
    ls_out-charg    = iv_charg.        " batch of the order (finished product) / component
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
    " goods recipient (RESB-WEMPF) at creation. MATNR/WERKS/XLOEK match RESB
    " secondary index M. Deleted items are ignored (as if never created);
    " closed items (final issue) are found so that nothing is done for them.
    IF lv_link_rsnum IS INITIAL.
      SELECT rsnum, rspos FROM resb ##NULL_VALUES
        WHERE matnr = @iv_matnr
          AND werks = @iv_werks_fr
          AND xloek = @space
          AND wempf = @iv_aufnr
          AND umwrk = @iv_werks_to
          AND bwart = @gc_mvt_301
        ORDER BY rsnum DESCENDING, rspos
        INTO (@lv_link_rsnum, @lv_link_rspos)
        UP TO 1 ROWS.
      ENDSELECT.
    ENDIF.

    DATA: lv_has_res TYPE abap_bool,
          lv_closed  TYPE abap_bool.
    IF lv_link_rsnum IS NOT INITIAL.
      SELECT SINGLE bdmng, enmng, xloek, kzear FROM resb INTO @DATA(ls_resb)
        WHERE rsnum = @lv_link_rsnum AND rspos = @lv_link_rspos.
      " A deleted item counts as never created (a new reservation is made for
      " the open quantity) and is never changed; a closed item (final issue)
      " counts as completed.
      IF sy-subrc = 0 AND ls_resb-xloek = abap_false.
        lv_closed        = ls_resb-kzear.
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
      IF lv_closed = abap_true.
        " closed reservation item (final issue): completed, nothing to do
        ls_out-status  = gc_complete.
        ls_out-statxt  = 'Complete'.
        ls_out-message = 'Reservation item is closed (final issue)'.
      ELSEIF iv_to_close = abap_true OR iv_basis <= 0.
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
  METHOD profit_table.
    " The line type of PROFITABILITYSEGMENT is read from the interface of the
    " function module, so no type name has to be hard-coded.
    DATA: lt_exc TYPE STANDARD TABLE OF rsexc,
          lt_exp TYPE STANDARD TABLE OF rsexp,
          lt_imp TYPE STANDARD TABLE OF rsimp,
          lt_cha TYPE STANDARD TABLE OF rscha,
          lt_tbl TYPE STANDARD TABLE OF rstbl.

    CALL FUNCTION 'FUNCTION_IMPORT_INTERFACE'
      EXPORTING
        funcname           = 'BAPI_RESERVATION_CREATE1'
      TABLES
        exception_list     = lt_exc
        export_parameter   = lt_exp
        import_parameter   = lt_imp
        changing_parameter = lt_cha
        tables_parameter   = lt_tbl
      EXCEPTIONS
        OTHERS             = 1.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    READ TABLE lt_tbl INTO DATA(ls_tbl) WITH KEY parameter = 'PROFITABILITYSEGMENT'.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    DATA(lv_type) = CONV string( COND #( WHEN ls_tbl-dbstruct IS NOT INITIAL
                                         THEN ls_tbl-dbstruct
                                         ELSE ls_tbl-typ ) ).
    TRY.
        CREATE DATA rr_tab TYPE STANDARD TABLE OF (lv_type).
      CATCH cx_sy_create_data_error.
        CLEAR rr_tab.
    ENDTRY.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD create_reservation.
    " All rows share one direction: finished product (8P01 -> 8Q01) or
    " raw materials (8Q01 -> 8P01); they are never mixed in one reservation.
    FIELD-SYMBOLS <o> TYPE ty_out.

    IF mv_simulate = abap_true.
      LOOP AT ct_out ASSIGNING <o>.
        <o>-status = gc_simulated.
        <o>-statxt = 'Simulated (create)'.
        " announce a missing storage location view of the target
        IF <o>-lgort_to IS NOT INITIAL.
          SELECT SINGLE lgort FROM mard INTO @DATA(lv_there)
            WHERE matnr = @<o>-matnr AND werks = @<o>-werks_to AND lgort = @<o>-lgort_to.
          IF sy-subrc <> 0.
            <o>-statxt = COND #( WHEN p_extsl = abap_true
                                 THEN 'Simulated (create; material will be extended to target SLoc)'
                                 ELSE 'Simulated (create; material missing in target SLoc)' ).
          ENDIF.
        ENDIF.
      ENDLOOP.
      RETURN.
    ENDIF.

    DATA: ls_head   TYPE bapi2093_res_head,
          lt_items  TYPE STANDARD TABLE OF bapi2093_res_item,
          ls_item   TYPE bapi2093_res_item,
          lt_return TYPE STANDARD TABLE OF bapiret2,
          lv_resno  TYPE rsnum,
          lt_rspos  TYPE STANDARD TABLE OF rspos WITH EMPTY KEY,
          lt_valid  TYPE STANDARD TABLE OF i WITH EMPTY KEY,   " lines of CT_OUT sent to the BAPI
          lt_ext    TYPE STANDARD TABLE OF i WITH EMPTY KEY.   " lines whose material was extended

    " Movement type and receiving plant/stor.loc are header data in
    " BAPI_RESERVATION_CREATE1 (as on the MB21 initial screen). All rows share
    " one direction, so they are taken from the first row.
    DATA(ls_first) = ct_out[ 1 ].
    ls_head-res_date   = p_rsdat.
    ls_head-move_type  = gc_mvt_301.
    ls_head-move_plant = ls_first-werks_to.
    ls_head-move_stloc = ls_first-lgort_to.

    LOOP AT ct_out ASSIGNING <o>.
      DATA(lv_tabix) = sy-tabix.

      " material data must exist in the target storage location
      extend_sloc( EXPORTING iv_matnr    = <o>-matnr
                             iv_werks_fr = <o>-werks_fr
                             iv_lgort_fr = <o>-lgort_fr
                             iv_werks_to = <o>-werks_to
                             iv_lgort_to = <o>-lgort_to
                   IMPORTING ev_msg      = DATA(lv_ext_msg)
                             ev_done     = DATA(lv_ext_done) ).
      IF lv_ext_msg IS NOT INITIAL.
        <o>-status  = gc_error.
        <o>-statxt  = 'Create error'.
        <o>-message = lv_ext_msg.
        CONTINUE.
      ENDIF.
      IF lv_ext_done = abap_true.
        APPEND lv_tabix TO lt_ext.
      ENDIF.

      CLEAR ls_item.
      ls_item-material_long = <o>-matnr.         " S/4: 40-char MATNR
      ls_item-plant         = <o>-werks_fr.
      ls_item-stge_loc      = <o>-lgort_fr.
      ls_item-entry_qnt     = <o>-po_open.       " basis qty; initial ENMNG = 0
      ls_item-entry_uom     = <o>-meins.
      ls_item-req_date      = p_rsdat.
      ls_item-movement      = p_move.            " movement allowed (RESB-XWAOK)
      ls_item-gr_rcpt       = <o>-aufnr.         " order no. -> RESB-WEMPF (2nd link)
      ls_item-batch         = <o>-charg.         " batch of the production order
      APPEND ls_item TO lt_items.
      APPEND lv_tabix TO lt_valid.
    ENDLOOP.

    IF lt_items IS INITIAL.
      RETURN.                                    " every line failed before the BAPI
    ENDIF.

    " BAPI_RESERVATION_CREATE1 has the mandatory table PROFITABILITYSEGMENT (not
    " used for a plain 301 reservation, passed empty).
    FIELD-SYMBOLS <lt_prof> TYPE STANDARD TABLE.
    DATA(lr_prof) = profit_table( ).
    IF lr_prof IS NOT BOUND.
      LOOP AT lt_valid INTO DATA(lv_i).
        ASSIGN ct_out[ lv_i ] TO <o>.
        <o>-status  = gc_error.
        <o>-statxt  = 'Create error'.
        <o>-message = 'Table type of BAPI_RESERVATION_CREATE1 parameter PROFITABILITYSEGMENT not found'.
      ENDLOOP.
      RETURN.
    ENDIF.
    ASSIGN lr_prof->* TO <lt_prof>.

    TRY.
        CALL FUNCTION 'BAPI_RESERVATION_CREATE1'
          EXPORTING
            reservationheader    = ls_head
          IMPORTING
            reservation          = lv_resno
          TABLES
            reservationitems     = lt_items
            return               = lt_return
            profitabilitysegment = <lt_prof>.
      CATCH cx_sy_dyn_call_error INTO DATA(lx_call).
        " interface mismatch with this release: report it on the lines, no dump
        LOOP AT lt_valid INTO lv_i.
          ASSIGN ct_out[ lv_i ] TO <o>.
          <o>-status  = gc_error.
          <o>-statxt  = 'Create error'.
          <o>-message = lx_call->get_text( ).
        ENDLOOP.
        RETURN.
    ENDTRY.

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
      LOOP AT lt_valid INTO lv_i.
        ASSIGN ct_out[ lv_i ] TO <o>.
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
      LOOP AT lt_valid INTO lv_i.
        DATA(lv_idx) = sy-tabix.
        ASSIGN ct_out[ lv_i ] TO <o>.
        <o>-rsnum   = lv_resno.
        <o>-rspos   = VALUE #( lt_rspos[ lv_idx ] DEFAULT lv_idx ).
        <o>-status  = gc_created.
        <o>-statxt  = 'Created'.
        <o>-message = |Reservation { lv_resno } created|
                   && COND string( WHEN line_exists( lt_ext[ table_line = lv_i ] )
                                   THEN ', material extended to target SLoc' ).
      ENDLOOP.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD extend_sloc.
    " Extends the material to the target storage location when the storage
    " location view (MARD) does not exist yet: BAPI_MATERIAL_SAVEDATA, the
    " storage location data are copied from the source storage location.
    " The material must already exist in the target plant (MARC).
    CLEAR: ev_msg, ev_done.
    IF iv_matnr IS INITIAL OR iv_lgort_to IS INITIAL.
      RETURN.
    ENDIF.

    SELECT SINGLE lgort FROM mard INTO @DATA(lv_there)
      WHERE matnr = @iv_matnr AND werks = @iv_werks_to AND lgort = @iv_lgort_to.
    IF sy-subrc = 0.
      RETURN.                                    " already extended
    ENDIF.
    IF p_extsl = abap_false.
      RETURN.                                    " option off: the BAPI reports it
    ENDIF.

    SELECT SINGLE werks FROM marc INTO @DATA(lv_plant)
      WHERE matnr = @iv_matnr AND werks = @iv_werks_to.
    IF sy-subrc <> 0.
      ev_msg = |Material { iv_matnr } is not extended to plant { iv_werks_to }|.
      RETURN.
    ENDIF.
    SELECT SINGLE lgort FROM t001l INTO @DATA(lv_exists)
      WHERE werks = @iv_werks_to AND lgort = @iv_lgort_to.
    IF sy-subrc <> 0.
      ev_msg = |Storage location { iv_lgort_to } does not exist in plant { iv_werks_to }|.
      RETURN.
    ENDIF.

    " data of the source storage location (if there is one)
    DATA ls_src TYPE mard.
    IF iv_lgort_fr IS NOT INITIAL.
      SELECT SINGLE * FROM mard INTO @ls_src
        WHERE matnr = @iv_matnr AND werks = @iv_werks_fr AND lgort = @iv_lgort_fr.
    ENDIF.

    DATA: ls_head TYPE bapimathead,
          ls_sl   TYPE bapi_mard,
          ls_slx  TYPE bapi_mardx,
          ls_ret  TYPE bapiret2,
          lt_ret  TYPE STANDARD TABLE OF bapiret2.

    ls_head-material_long = iv_matnr.            " S/4: 40-char MATNR
    ls_head-storage_view  = abap_true.
    ls_sl-plant    = iv_werks_to.
    ls_sl-stge_loc = iv_lgort_to.
    ls_slx-plant    = iv_werks_to.
    ls_slx-stge_loc = iv_lgort_to.

    " fields copied from the source storage location: BAPI component <- MARD column.
    " Components that do not exist in the BAPI structure are skipped.
    TYPES: BEGIN OF ty_map,
             bapi TYPE string,
             mard TYPE string,
           END OF ty_map.
    TYPES tt_map TYPE STANDARD TABLE OF ty_map WITH EMPTY KEY.
    DATA(lt_map) = VALUE tt_map(
      ( bapi = 'STGE_BIN'     mard = 'LGPBE' )      " storage bin
      ( bapi = 'MRP_IND'      mard = 'DISKZ' )      " storage location MRP indicator
      ( bapi = 'SPEC_PROC'    mard = 'LSOBS' )      " special procurement type
      ( bapi = 'REORDER_PT'   mard = 'LMINB' )      " reorder point
      ( bapi = 'REPLEN_QTY'   mard = 'LBSTF' )      " replenishment quantity
      ( bapi = 'INV_CORR_FAC' mard = 'BSKRF' ) ).   " inventory correction factor

    LOOP AT lt_map ASSIGNING FIELD-SYMBOL(<m>).
      ASSIGN COMPONENT <m>-mard OF STRUCTURE ls_src TO FIELD-SYMBOL(<src>).
      IF sy-subrc <> 0 OR <src> IS INITIAL.
        CONTINUE.
      ENDIF.
      ASSIGN COMPONENT <m>-bapi OF STRUCTURE ls_sl TO FIELD-SYMBOL(<dst>).
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      ASSIGN COMPONENT <m>-bapi OF STRUCTURE ls_slx TO FIELD-SYMBOL(<flag>).
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      <dst>  = <src>.
      <flag> = abap_true.
    ENDLOOP.

    TRY.
        CALL FUNCTION 'BAPI_MATERIAL_SAVEDATA'
          EXPORTING
            headdata             = ls_head
            storagelocationdata  = ls_sl
            storagelocationdatax = ls_slx
          IMPORTING
            return               = ls_ret
          TABLES
            returnmessages       = lt_ret.
      CATCH cx_sy_dyn_call_error INTO DATA(lx_call).
        ev_msg = lx_call->get_text( ).
        RETURN.
    ENDTRY.

    IF ls_ret-type CA 'EA' OR line_exists( lt_ret[ type = 'E' ] ) OR line_exists( lt_ret[ type = 'A' ] ).
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      ev_msg = |Material { iv_matnr }: extension to { iv_werks_to }/{ iv_lgort_to } failed: |
            && COND string( WHEN ls_ret-message IS NOT INITIAL THEN ls_ret-message
                            ELSE VALUE #( lt_ret[ type = 'E' ]-message DEFAULT `unknown error` ) ).
      RETURN.
    ENDIF.

    CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X'.
    ev_done = abap_true.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD change_reservation.
    " Realign (BDMNG = target) or close (BDMNG = ENMNG).
    " NOTE: verify BAPI_RESERVATION_CHANGE item/itemX field names for the
    "       target release. MB22 FM/BDC is the fallback.
    DATA(lv_newqty) = COND menge_d(
        WHEN iv_close = abap_true THEN cs_out-res_enmng
        ELSE cs_out-target_bdmng ).

    IF mv_simulate = abap_true.
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

    TRY.
        CALL FUNCTION 'BAPI_RESERVATION_CHANGE'
          EXPORTING
            reservation               = cs_out-rsnum
          TABLES
            reservationitems_changed  = lt_items
            reservationitems_changedx = lt_itemsx
            return                    = lt_return.
      CATCH cx_sy_dyn_call_error INTO DATA(lx_call).
        " interface mismatch with this release: report it on the line, no dump
        cs_out-status  = gc_error.
        cs_out-statxt  = 'Change error'.
        cs_out-message = lx_call->get_text( ).
        RETURN.
    ENDTRY.

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
  METHOD clear_logs.
    " Deletes ALL rows of the run log (ZPTP_301_RUN_LOG) and of the item log
    " (ZPTP_301_RES_LOG) before the run. A test run changes nothing, so it
    " never cleans. Existing reservations are still found through the
    " goods recipient (RESB-WEMPF) when their log row is gone.
    IF p_clrlg = abap_false.
      RETURN.
    ENDIF.
    IF r_test = abap_true.
      MESSAGE 'Logs are not cleaned in test mode' TYPE 'S'.
      RETURN.
    ENDIF.

    IF sy-batch = abap_false.
      DATA lv_answer TYPE c LENGTH 1.
      CALL FUNCTION 'POPUP_TO_CONFIRM'
        EXPORTING
          titlebar              = 'Clean logs'
          text_question         = 'All run logs and reservation logs will be deleted. Continue?'
          default_button        = '2'
          display_cancel_button = abap_false
        IMPORTING
          answer                = lv_answer
        EXCEPTIONS
          OTHERS                = 1.
      IF sy-subrc <> 0 OR lv_answer <> '1'.
        MESSAGE 'Run cancelled, logs not cleaned' TYPE 'E'.
      ENDIF.
    ENDIF.

    DELETE FROM zptp_301_res_log.
    DELETE FROM zptp_301_run_log.
    COMMIT WORK.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD start_run_log.
    ms_counts = VALUE #( run_id     = mv_run_id
                         run_mode   = mv_mode
                         jobname    = COND #( WHEN mv_mode = 'B' THEN sy-msgv1 )
                         werks_fr   = p_werkfr
                         werks_to   = p_werkto
                         test_run   = r_test
                         start_date = sy-datum
                         start_time = sy-uzeit
                         status     = 'R'
                         ernam      = sy-uname
                         sel_text   = |FR { p_werkfr } TO { p_werkto } DATE { p_rsdat } MODE { COND string( WHEN r_test = abap_true THEN 'TEST' WHEN r_back = abap_true THEN 'BACKGROUND' ELSE 'ONLINE' ) } COLL { p_coll } EXCL { p_excl }| ).
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
    " Simulated lines (test mode, first pass of the online mode) are not logged.
    IF mv_simulate = abap_true.
      RETURN.
    ENDIF.
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
  METHOD build_fcat.
    DEFINE _col.
      APPEND VALUE lvc_s_fcat( fieldname = &1 coltext = &2 outputlen = &3 ) TO rt_fcat.
    END-OF-DEFINITION.

    IF r_onl = abap_true.
      _col 'SEL'        'Create'           6.
    ENDIF.
    _col 'AUFNR'        'Prod. order'      12.
    _col 'LEAD_AUFNR'   'Lead coll. order' 12.
    _col 'IS_LEAD'      'Coll.Order Lead'  6.
    _col 'POSNR'        'Item'             6.
    _col 'RES_KIND'     'Kind'             4.
    _col 'MATNR'        'Material'         18.
    _col 'MAKTX'        'Description'      30.
    _col 'MTART'        'Mat. type'        4.
    _col 'CHARG'        'Batch (order)'    10.
    _col 'IN_TARGET'    'Ext. to target plant' 8.
    _col 'PO_OPEN'      'Open qty basis'   13.
    _col 'RES_BDMNG'    'Req. qty'         13.
    _col 'RES_ENMNG'    'Withdrawn'        13.
    _col 'TARGET_BDMNG' 'Target req. qty'  13.
    _col 'MEINS'        'UoM'              3.
    _col 'WERKS_FR'     'From plant'       5.
    _col 'LGORT_FR'     'From SLoc'        5.
    _col 'WERKS_TO'     'To plant'         5.
    _col 'LGORT_TO'     'To SLoc'          5.
    _col 'RSNUM'        'Reservation'      10.
    _col 'RSPOS'        'Res. item'        5.
    _col 'STATUS'       'St.'              3.
    _col 'STATXT'       'Status'           25.
    _col 'MESSAGE'      'Message'          60.

    LOOP AT rt_fcat ASSIGNING FIELD-SYMBOL(<f>).
      IF <f>-fieldname = 'SEL'.              " online mode: tick an order to create it
        <f>-checkbox = abap_true.
        <f>-edit     = abap_true.
        <f>-just     = 'C'.
      ENDIF.
      IF <f>-fieldname = 'PO_OPEN' OR <f>-fieldname = 'RES_BDMNG'
      OR <f>-fieldname = 'RES_ENMNG' OR <f>-fieldname = 'TARGET_BDMNG'.
        <f>-qfieldname = 'MEINS'.
      ENDIF.
      IF <f>-fieldname = 'IN_TARGET'.        " tag, shown as a checkbox
        <f>-checkbox = abap_true.
        <f>-just     = 'C'.
      ENDIF.
      IF <f>-fieldname = 'IS_LEAD'.          " tag, shown as a checkbox
        <f>-checkbox = abap_true.
        <f>-just     = 'C'.
      ENDIF.
      IF <f>-fieldname = 'MEINS'.            " unit shown in the logon language
        <f>-ref_table = 'MARA'.
        <f>-ref_field = 'MEINS'.
        <f>-convexit  = 'CUNIT'.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD enrich_out.
    " Display data of the result lines: material description / type, batch,
    " collective-order information and row colour. Rows of the lowest-level order
    " of a collective order get a light-grey background, rows of the other
    " (not lowest-level) orders of a collective order are shown in grey font.

    " material description and material type
    DATA lt_mat TYPE SORTED TABLE OF matnr WITH UNIQUE KEY table_line.
    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<m>) WHERE matnr IS NOT INITIAL.
      INSERT <m>-matnr INTO TABLE lt_mat.
    ENDLOOP.
    IF lt_mat IS NOT INITIAL.
      SELECT matnr, mtart FROM mara
        FOR ALL ENTRIES IN @lt_mat
        WHERE matnr = @lt_mat-table_line
        INTO TABLE @DATA(lt_mara).
      SELECT matnr, maktx FROM makt
        FOR ALL ENTRIES IN @lt_mat
        WHERE matnr = @lt_mat-table_line AND spras = @sy-langu
        INTO TABLE @DATA(lt_makt).
      SORT: lt_mara BY matnr, lt_makt BY matnr.
      LOOP AT mt_out ASSIGNING <m> WHERE matnr IS NOT INITIAL.
        <m>-mtart = VALUE #( lt_mara[ matnr = <m>-matnr ]-mtart OPTIONAL ).
        <m>-maktx = VALUE #( lt_makt[ matnr = <m>-matnr ]-maktx OPTIONAL ).
      ENDLOOP.
    ENDIF.

    " is the material extended to the target plant (plant data MARC)?
    TYPES: BEGIN OF ty_pair,
             matnr TYPE matnr,
             werks TYPE werks_d,
           END OF ty_pair.
    DATA lt_pair TYPE SORTED TABLE OF ty_pair WITH UNIQUE KEY matnr werks.
    LOOP AT mt_out ASSIGNING <m> WHERE matnr IS NOT INITIAL AND werks_to IS NOT INITIAL.
      INSERT VALUE #( matnr = <m>-matnr werks = <m>-werks_to ) INTO TABLE lt_pair.
    ENDLOOP.
    IF lt_pair IS NOT INITIAL.
      SELECT matnr, werks FROM marc
        FOR ALL ENTRIES IN @lt_pair
        WHERE matnr = @lt_pair-matnr AND werks = @lt_pair-werks
        INTO TABLE @DATA(lt_marc).
      SORT lt_marc BY matnr werks.
    ENDIF.

    LOOP AT mt_out ASSIGNING <m>.
      <m>-in_target = xsdbool( <m>-matnr IS NOT INITIAL
                           AND line_exists( lt_marc[ matnr = <m>-matnr werks = <m>-werks_to ] ) ).
    ENDLOOP.

    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<o>).
      DATA(ls_role) = collective_role( <o>-aufnr ).
      IF ls_role-coll = abap_false.
        CONTINUE.
      ENDIF.
      <o>-lead_aufnr = ls_role-leader.
      <o>-is_lead    = ls_role-lead.          " only collective orders get the tag
      IF ls_role-lowest = abap_true.
        " lowest-level order: light grey background for the whole row (col 2 = light grey)
        <o>-coltab = VALUE #( ( color = VALUE #( col = 2 int = 0 inv = 0 ) ) ).
      ELSE.
        " not the lowest-level order: grey font on a neutral background
        " (inv = 1 applies the palette colour to the text; col 1 = grey)
        <o>-coltab = VALUE #( ( color = VALUE #( col = 1 int = 0 inv = 1 ) ) ).
      ENDIF.
    ENDLOOP.

    " Colour by status (palette colours of the ALV grid; text colour cannot be chosen):
    "   C created / F complete / N unchanged -> green   (col 5)
    "   X closed               -> dark grey    (col 1 intensified, nearest to dark grey)
    "   R realigned            -> yellow       (col 3)
    " The status colour wins over the collective-order grey.
    LOOP AT mt_out ASSIGNING <o>.
      CASE <o>-status.
        WHEN gc_created OR gc_complete OR gc_unchanged.
          <o>-coltab = VALUE #( ( color = VALUE #( col = 5 int = 0 inv = 0 ) ) ).
        WHEN gc_closed.
          <o>-coltab = VALUE #( ( color = VALUE #( col = 1 int = 1 inv = 0 ) ) ).
        WHEN gc_realigned.
          <o>-coltab = VALUE #( ( color = VALUE #( col = 3 int = 0 inv = 0 ) ) ).
      ENDCASE.
    ENDLOOP.

    " error lines (status E): red text on white, whatever the collective-order colour
    " (col 6 = red, inv = 1: the colour is applied to the text, the background stays neutral)
    LOOP AT mt_out ASSIGNING <o> WHERE status = gc_error.
      <o>-coltab = VALUE #( ( color = VALUE #( col = 6 int = 0 inv = 1 ) ) ).
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD display_alv.
    " Result list: grouped by production order, then by item, then by kind.
    " Test / background mode: display only.
    " Online mode: the same list with a checkbox on the left of each line;
    " the user ticks production orders and presses 'Create reservations'.
    DATA: lt_sort   TYPE lvc_t_sort,
          ls_layout TYPE lvc_s_layo,
          lv_status TYPE slis_formname,
          lv_ucomm  TYPE slis_formname.

    enrich_out( ).
    DATA(lt_fcat) = build_fcat( ).

    lt_sort = VALUE #( ( spos = 1 fieldname = 'AUFNR'    up = abap_true group = 'UL' )
                       ( spos = 2 fieldname = 'POSNR'    up = abap_true group = '*' )
                       ( spos = 3 fieldname = 'RES_KIND' up = abap_true ) ).

    ls_layout-ctab_fname = 'COLTAB'.
    ls_layout-stylefname = 'CELLSTYLE'.
    ls_layout-cwidth_opt = abap_true.

    IF r_onl = abap_true.
      lv_status = 'SET_STATUS'.
      lv_ucomm  = 'USER_COMMAND'.
    ENDIF.

    CALL FUNCTION 'REUSE_ALV_GRID_DISPLAY_LVC'
      EXPORTING
        i_callback_program       = sy-repid
        i_callback_pf_status_set = lv_status
        i_callback_user_command  = lv_ucomm
        is_layout_lvc            = ls_layout
        it_fieldcat_lvc          = lt_fcat
        it_sort_lvc              = lt_sort
        i_save                   = 'A'
      TABLES
        t_outtab                 = mt_out
      EXCEPTIONS
        OTHERS                   = 1.
    IF sy-subrc <> 0.
      MESSAGE 'ALV display error' TYPE 'I'.
    ENDIF.
  ENDMETHOD.


ENDCLASS.

DATA go_app TYPE REF TO lcl_app.

*---------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
  " listbox values for the reservation kind
  CALL FUNCTION 'VRM_SET_VALUES'
    EXPORTING
      id     = 'P_KIND'
      values = VALUE vrm_values( ( key = 'A' text = TEXT-l06 )
                                 ( key = 'H' text = TEXT-l04 )
                                 ( key = 'R' text = TEXT-l05 ) )
    EXCEPTIONS
      OTHERS = 1.

  " enable the raw-material plant/loc fields only when components are in scope (P_KIND = R / A)
  LOOP AT SCREEN.
    IF screen-group1 = 'RAW'.
      screen-input = COND i( WHEN p_kind = 'R' OR p_kind = 'A' THEN 1 ELSE 0 ).
      MODIFY SCREEN.
    ENDIF.
    IF screen-group1 = 'EXL'.
      screen-input = COND i( WHEN p_excl = abap_true THEN 1 ELSE 0 ).
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.

*---------------------------------------------------------------------*
AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  " local PC file picker for the exclusion spreadsheet
  DATA: lt_files TYPE filetable, lv_rc TYPE i.
  cl_gui_frontend_services=>file_open_dialog(
    EXPORTING  file_filter = |Excel (*.xlsx)\|*.xlsx|
    CHANGING   file_table  = lt_files
               rc          = lv_rc
    EXCEPTIONS OTHERS      = 1 ).
  IF sy-subrc = 0 AND lv_rc = 1.
    p_file = lt_files[ 1 ]-filename.
  ENDIF.

*---------------------------------------------------------------------*
AT SELECTION-SCREEN.
  " field-level validations run here in the real build
  " (delegated to LCL_APP->validate_selection at START-OF-SELECTION)

*---------------------------------------------------------------------*
* ALV callbacks (online mode)
*---------------------------------------------------------------------*
FORM set_status USING pt_extab TYPE slis_t_extab.
  " GUI status ZGENERATOR: copy of STANDARD_FULLSCREEN of SAPLKKBL plus function CREATE
  SET PF-STATUS 'ZGENERATOR' EXCLUDING pt_extab.
ENDFORM.

FORM user_command USING pv_ucomm    LIKE sy-ucomm
                        ps_selfield TYPE slis_selfield.
  " take over the ticks typed in the grid before processing
  DATA lo_grid TYPE REF TO cl_gui_alv_grid.
  CALL FUNCTION 'GET_GLOBALS_FROM_SLVC_FULLSCR'
    IMPORTING
      e_grid = lo_grid.
  IF lo_grid IS BOUND.
    lo_grid->check_changed_data( ).
  ENDIF.

  go_app->user_command( pv_ucomm ).

  ps_selfield-refresh    = abap_true.
  ps_selfield-col_stable = abap_true.
  ps_selfield-row_stable = abap_true.
ENDFORM.

*---------------------------------------------------------------------*
START-OF-SELECTION.
  " H = finished products, R = components, A = all
  gv_do_h = xsdbool( p_kind = 'H' OR p_kind = 'A' ).
  gv_do_r = xsdbool( p_kind = 'R' OR p_kind = 'A' ).
  go_app = NEW lcl_app( ).
  go_app->run( ).
