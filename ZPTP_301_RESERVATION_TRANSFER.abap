*&---------------------------------------------------------------------*
*& Report  ZPTP_301_RESERVATION_TRANSFER   (txn ZPTP_301_TRF)
*&---------------------------------------------------------------------*
*& Manual 301 transfer against reservations.
*&
*& Lists the OPEN 301 reservation items between two plants (default
*& 8P01 -> 8Q01 = finished products; run with 8Q01 -> 8P01 for the raw
*& material reservations) with material, open reservation quantity and
*& the available UNRESTRICTED stock in the source plant / storage location.
*&
*& The user selects the reservation items and presses POST: one 301 goods
*& movement is posted per item against the reservation
*& (Z_PTP_301_RES_TRANSFER_POST). The transfer quantity defaults to the open
*& reservation quantity and can be changed in the grid (as can the batch).
*&
*& The reservations are created / aligned by ZPTP_301_RESERVATION_GENERATOR;
*& this report consumes them.
*&
*& GUI status ZTRANSFER (copy of STANDARD_FULLSCREEN of SAPLKKBL) with the
*& extra function POST must exist in this program (SE41).
*&---------------------------------------------------------------------*
REPORT zptp_301_reservation_transfer.

TYPE-POOLS: abap, icon.

*---------------------------------------------------------------------*
* Selection screen
*---------------------------------------------------------------------*
DATA: gv_aufnr TYPE aufnr,
      gv_matnr TYPE matnr,
      gv_rsnum TYPE rsnum.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.   " Plants
PARAMETERS: p_werkfr TYPE werks_d OBLIGATORY DEFAULT '8P01',   " source plant (issuing)
            p_werkto TYPE werks_d OBLIGATORY DEFAULT '8Q01'.   " destination plant (receiving)
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.   " Reservation selection
SELECT-OPTIONS: so_rsnum FOR gv_rsnum,
                so_aufnr FOR gv_aufnr,                          " order (goods recipient)
                so_matnr FOR gv_matnr,
                so_bdter FOR sy-datum.                          " requirement date
PARAMETERS:     p_stock  AS CHECKBOX.                           " only items with stock
SELECTION-SCREEN END OF BLOCK b2.

SELECTION-SCREEN BEGIN OF BLOCK b3 WITH FRAME TITLE TEXT-003.   " Posting
PARAMETERS: p_budat TYPE budat DEFAULT sy-datum OBLIGATORY.
SELECTION-SCREEN END OF BLOCK b3.

*---------------------------------------------------------------------*
CONSTANTS: gc_mvt_301 TYPE bwart VALUE '301'.

*---------------------------------------------------------------------*
* Local class : application engine
*---------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.

  PUBLIC SECTION.
    TYPES: BEGIN OF ty_out,
             sel      TYPE abap_bool,
             icon     TYPE c LENGTH 4,
             rsnum    TYPE rsnum,
             rspos    TYPE rspos,
             aufnr    TYPE aufnr,                " goods recipient = production order
             matnr    TYPE matnr,
             maktx    TYPE maktx,
             werks_fr TYPE werks_d,
             lgort_fr TYPE lgort_d,
             werks_to TYPE werks_d,
             lgort_to TYPE lgort_d,
             bdter    TYPE bdter,
             bdmng    TYPE bdmng,
             enmng    TYPE enmng,
             res_open TYPE menge_d,               " BDMNG - ENMNG
             avail    TYPE menge_d,               " unrestricted stock in source
             menge    TYPE menge_d,               " quantity to post (editable)
             meins    TYPE meins,
             charg    TYPE charg_d,               " batch (editable)
             mblnr    TYPE mblnr,
             message  TYPE string,
           END OF ty_out.
    TYPES tt_out TYPE STANDARD TABLE OF ty_out WITH DEFAULT KEY.

    METHODS constructor.
    METHODS run.
    METHODS user_command
      IMPORTING iv_ucomm TYPE sy-ucomm.

  PRIVATE SECTION.
    DATA: mt_out    TYPE tt_out,
          mv_run_id TYPE sysuuid_c32.

    METHODS select_data.
    METHODS read_stock
      IMPORTING iv_matnr        TYPE matnr
                iv_werks        TYPE werks_d
                iv_lgort        TYPE lgort_d
                iv_charg        TYPE charg_d OPTIONAL
      RETURNING VALUE(rv_avail) TYPE menge_d.
    METHODS post_selected.
    METHODS refresh_row
      CHANGING cs_out TYPE ty_out.
    METHODS display_alv.

ENDCLASS.

DATA go_app TYPE REF TO lcl_app.

*---------------------------------------------------------------------*
CLASS lcl_app IMPLEMENTATION.

  METHOD constructor.
    TRY.
        mv_run_id = cl_system_uuid=>create_uuid_c32_static( ).
      CATCH cx_uuid_error.
        mv_run_id = |{ sy-datum }{ sy-uzeit }{ sy-index }|.
    ENDTRY.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD run.
    IF p_werkfr = p_werkto.
      MESSAGE e027(zptp_split_val) WITH p_werkfr p_werkto.
    ENDIF.
    select_data( ).
    IF mt_out IS INITIAL.
      MESSAGE s052(zptp_split_val).                    " no open 301 reservations found
      RETURN.
    ENDIF.
    display_alv( ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD select_data.
    " Open 301 reservation items from the source plant to the destination
    " plant. XWAOK = movement allowed; deleted / final-issued excluded.
    SELECT rsnum, rspos, matnr, werks, lgort, umwrk, umlgo,
           bdmng, enmng, meins, bdter, wempf, charg
      FROM resb
      INTO TABLE @DATA(lt_resb)
      WHERE bwart  = @gc_mvt_301
        AND werks  = @p_werkfr
        AND umwrk  = @p_werkto
        AND rsnum IN @so_rsnum
        AND matnr IN @so_matnr
        AND wempf IN @so_aufnr
        AND bdter IN @so_bdter
        AND xloek  = @space
        AND kzear  = @space
        AND xwaok  = @abap_true.
    IF lt_resb IS INITIAL.
      RETURN.
    ENDIF.

    " material descriptions
    SELECT matnr, maktx FROM makt
      FOR ALL ENTRIES IN @lt_resb
      WHERE matnr = @lt_resb-matnr AND spras = @sy-langu
      INTO TABLE @DATA(lt_makt).
    SORT lt_makt BY matnr.

    SORT lt_resb BY rsnum rspos.
    LOOP AT lt_resb ASSIGNING FIELD-SYMBOL(<r>).
      IF <r>-bdmng <= <r>-enmng.                       " nothing open any more
        CONTINUE.
      ENDIF.
      DATA(ls_out) = VALUE ty_out(
        rsnum    = <r>-rsnum
        rspos    = <r>-rspos
        aufnr    = <r>-wempf
        matnr    = <r>-matnr
        maktx    = VALUE #( lt_makt[ matnr = <r>-matnr ]-maktx OPTIONAL )
        werks_fr = <r>-werks
        lgort_fr = <r>-lgort
        werks_to = <r>-umwrk
        lgort_to = <r>-umlgo
        bdter    = <r>-bdter
        bdmng    = <r>-bdmng
        enmng    = <r>-enmng
        res_open = <r>-bdmng - <r>-enmng
        meins    = <r>-meins
        charg    = <r>-charg ).
      ls_out-avail = read_stock( iv_matnr = ls_out-matnr
                                 iv_werks = ls_out-werks_fr
                                 iv_lgort = ls_out-lgort_fr
                                 iv_charg = ls_out-charg ).
      IF p_stock = abap_true AND ls_out-avail <= 0.
        CONTINUE.
      ENDIF.
      ls_out-menge = ls_out-res_open.                  " default = reservation quantity
      APPEND ls_out TO mt_out.
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD read_stock.
    " Unrestricted-use stock only (LABST / CLABS); QI and blocked stock are
    " intentionally not counted. Blank storage location = whole plant.
    DATA lr_lgort TYPE RANGE OF lgort_d.
    IF iv_lgort IS NOT INITIAL.
      lr_lgort = VALUE #( ( sign = 'I' option = 'EQ' low = iv_lgort ) ).
    ENDIF.
    IF iv_charg IS NOT INITIAL.
      SELECT SUM( clabs ) FROM mchb
        WHERE matnr = @iv_matnr AND werks = @iv_werks AND charg = @iv_charg
          AND lgort IN @lr_lgort
        INTO @rv_avail.
    ELSE.
      SELECT SUM( labst ) FROM mard
        WHERE matnr = @iv_matnr AND werks = @iv_werks
          AND lgort IN @lr_lgort
        INTO @rv_avail.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD user_command.
    CASE iv_ucomm.
      WHEN 'POST'.
        post_selected( ).
    ENDCASE.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD post_selected.
    DATA: lv_count  TYPE i,
          lv_status TYPE c LENGTH 1,
          lv_msg    TYPE string,
          lv_mblnr  TYPE mblnr.

    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<o>) WHERE sel = abap_true.
      lv_count = lv_count + 1.
      CLEAR: <o>-mblnr, <o>-message.

      " quantity re-validated against current data (stock may have moved)
      IF <o>-menge <= 0.
        <o>-icon    = icon_led_red.
        <o>-message = 'Quantity must be greater than zero'.
        CONTINUE.
      ENDIF.
      IF <o>-menge > <o>-res_open.
        <o>-icon    = icon_led_red.
        <o>-message = |Quantity exceeds open reservation quantity { <o>-res_open }|.
        CONTINUE.
      ENDIF.
      DATA(lv_avail) = read_stock( iv_matnr = <o>-matnr
                                   iv_werks = <o>-werks_fr
                                   iv_lgort = <o>-lgort_fr
                                   iv_charg = <o>-charg ).
      <o>-avail = lv_avail.
      IF <o>-menge > lv_avail.
        <o>-icon    = icon_led_red.
        <o>-message = |Quantity exceeds unrestricted stock { lv_avail }|.
        CONTINUE.
      ENDIF.

      CALL FUNCTION 'Z_PTP_301_RES_TRANSFER_POST'
        EXPORTING
          iv_rsnum   = <o>-rsnum
          iv_rspos   = <o>-rspos
          iv_menge   = <o>-menge
          iv_charg   = <o>-charg
          iv_budat   = p_budat
          iv_run_id  = mv_run_id
        IMPORTING
          ev_status  = lv_status
          ev_message = lv_msg
          ev_mblnr   = lv_mblnr.

      <o>-message = lv_msg.
      IF lv_status = 'S'.
        <o>-icon  = icon_led_green.
        <o>-mblnr = lv_mblnr.
        <o>-sel   = abap_false.
        refresh_row( CHANGING cs_out = <o> ).          " new open qty / stock / default qty
      ELSE.
        <o>-icon = icon_led_red.
      ENDIF.
    ENDLOOP.

    IF lv_count = 0.
      MESSAGE s053(zptp_split_val) DISPLAY LIKE 'W'.   " no item selected
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD refresh_row.
    " re-read the reservation item and the stock after a successful posting
    SELECT SINGLE bdmng, enmng FROM resb INTO @DATA(ls_resb)
      WHERE rsnum = @cs_out-rsnum AND rspos = @cs_out-rspos.
    IF sy-subrc = 0.
      cs_out-bdmng    = ls_resb-bdmng.
      cs_out-enmng    = ls_resb-enmng.
      cs_out-res_open = ls_resb-bdmng - ls_resb-enmng.
    ENDIF.
    cs_out-avail = read_stock( iv_matnr = cs_out-matnr
                               iv_werks = cs_out-werks_fr
                               iv_lgort = cs_out-lgort_fr
                               iv_charg = cs_out-charg ).
    cs_out-menge = cs_out-res_open.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD display_alv.
    DATA: lt_fcat   TYPE lvc_t_fcat,
          ls_layout TYPE lvc_s_layo.

    DEFINE _col.
      APPEND VALUE lvc_s_fcat( fieldname = &1 coltext = &2 outputlen = &3 ) TO lt_fcat.
    END-OF-DEFINITION.

    _col 'ICON'     'St.'              4.
    _col 'RSNUM'    'Reservation'      10.
    _col 'RSPOS'    'Item'             4.
    _col 'AUFNR'    'Prod. order'      12.
    _col 'MATNR'    'Material'         18.
    _col 'MAKTX'    'Description'      30.
    _col 'WERKS_FR' 'From plant'       5.
    _col 'LGORT_FR' 'From SLoc'        5.
    _col 'WERKS_TO' 'To plant'         5.
    _col 'LGORT_TO' 'To SLoc'          5.
    _col 'BDTER'    'Req. date'        10.
    _col 'BDMNG'    'Req. qty'         13.
    _col 'ENMNG'    'Withdrawn'        13.
    _col 'RES_OPEN' 'Open res. qty'    13.
    _col 'AVAIL'    'Unrestr. stock'   13.
    _col 'MENGE'    'Qty to post'      13.
    _col 'MEINS'    'UoM'              3.
    _col 'CHARG'    'Batch'            10.
    _col 'MBLNR'    'Mat. doc'         10.
    _col 'MESSAGE'  'Message'          60.

    LOOP AT lt_fcat ASSIGNING FIELD-SYMBOL(<f>).
      CASE <f>-fieldname.
        WHEN 'ICON'.
          <f>-icon = abap_true.
        WHEN 'MENGE'.
          <f>-edit        = abap_true.
          <f>-qfieldname  = 'MEINS'.
          <f>-emphasize   = 'C310'.                    " highlighted: editable
        WHEN 'CHARG'.
          <f>-edit        = abap_true.
          <f>-emphasize   = 'C310'.
        WHEN 'BDMNG' OR 'ENMNG' OR 'RES_OPEN' OR 'AVAIL'.
          <f>-qfieldname  = 'MEINS'.
        WHEN 'MATNR'.
          <f>-ref_table = 'MARA'. <f>-ref_field = 'MATNR'.
      ENDCASE.
    ENDLOOP.

    ls_layout-box_fname  = 'SEL'.                       " row selection
    ls_layout-zebra      = abap_true.
    ls_layout-cwidth_opt = abap_true.

    CALL FUNCTION 'REUSE_ALV_GRID_DISPLAY_LVC'
      EXPORTING
        i_callback_program       = sy-repid
        i_callback_pf_status_set = 'SET_STATUS'
        i_callback_user_command  = 'USER_COMMAND'
        is_layout_lvc            = ls_layout
        it_fieldcat_lvc          = lt_fcat
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

*---------------------------------------------------------------------*
* ALV callbacks
*---------------------------------------------------------------------*
FORM set_status USING pt_extab TYPE slis_t_extab.
  SET PF-STATUS 'ZTRANSFER' EXCLUDING pt_extab.
ENDFORM.

FORM user_command USING pv_ucomm    LIKE sy-ucomm
                        ps_selfield TYPE slis_selfield.
  " take over the quantity / batch typed in the grid before processing
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
  go_app = NEW lcl_app( ).
  go_app->run( ).
