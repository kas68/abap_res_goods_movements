*&---------------------------------------------------------------------*
*& Report  ZPTP_301_RESERVATION_MANAGER   (txn ZPTP_301_MGR)
*&---------------------------------------------------------------------*
*& Management of the 301 reservations created by
*& ZPTP_301_RESERVATION_GENERATOR.
*&
*& The report finds the reservation items of the generator in three places:
*& the item log ZPTP_301_RES_LOG (latest reservation item per order / kind /
*& item), the transfer log ZPTP_301_TRF_LOG (items followed by a 301 posting,
*& still found when the item log has been cleaned) and RESB (301 items whose
*& goods recipient is the order number; only for a restricted selection).
*& Only items WITHOUT deletion indicator are listed, with
*&   - state          : Open / Closed (final issue, or required <= withdrawn)
*&   - followed by 301: Yes / No (successful posting in ZPTP_301_TRF_LOG,
*&                      material document not yet reversed)
*&   - reservation quantity (BDMNG), withdrawn (ENMNG) and the quantity of
*&     the 301 movement(s).
*&
*& The user selects items and presses POST (function POST):
*&   - no 301 movement      : the reservation item is flagged as deleted
*&                            (BAPI_RESERVATION_CHANGE, DELETE_IND).
*&   - followed by a 301    : every material document of the item is
*&     reversed first (BAPI_GOODSMVT_CANCEL); only when all reversals are
*&     successful the reservation item is flagged as deleted. The reversal
*&     is logged in ZPTP_301_TRF_LOG with status R.
*&
*& GUI status ZMANAGER (copy of STANDARD_FULLSCREEN of SAPLKKBL) with the
*& extra function POST must exist in this program (SE41).
*&---------------------------------------------------------------------*
REPORT zptp_301_reservation_manager.

TYPE-POOLS: abap, icon.

*---------------------------------------------------------------------*
* Selection screen
*---------------------------------------------------------------------*
DATA: gv_aufnr TYPE aufnr,
      gv_matnr TYPE matnr,
      gv_rsnum TYPE rsnum.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.   " Reservation selection
SELECT-OPTIONS: so_rsnum FOR gv_rsnum,
                so_aufnr FOR gv_aufnr,                          " order (goods recipient)
                so_matnr FOR gv_matnr,
                so_erdat FOR sy-datum.                          " creation date of the log entry
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.   " Reversal
PARAMETERS: p_budat TYPE budat DEFAULT sy-datum OBLIGATORY.     " posting date of the reversals
SELECTION-SCREEN END OF BLOCK b2.

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
             res_kind TYPE c LENGTH 1,           " H finished product / R component
             matnr    TYPE matnr,
             maktx    TYPE maktx,
             werks_fr TYPE werks_d,
             werks_to TYPE werks_d,
             state    TYPE c LENGTH 8,           " Open / Closed / Deleted
             followed TYPE c LENGTH 3,           " Yes / No : followed by a 301 movement
             bdmng    TYPE bdmng,                " reservation quantity
             enmng    TYPE enmng,                " withdrawn
             mov_qty  TYPE menge_d,              " quantity of the 301 movement(s)
             meins    TYPE meins,
             mblnr    TYPE mblnr,                " last material document
             mjahr    TYPE mjahr,
             origin   TYPE c LENGTH 14,          " where the item was found: log / transfer log / RESB
             action   TYPE c LENGTH 30,          " what POST will do
             message  TYPE string,
           END OF ty_out.
    TYPES tt_out TYPE STANDARD TABLE OF ty_out WITH DEFAULT KEY.

    METHODS constructor.
    METHODS run.
    METHODS user_command
      IMPORTING iv_ucomm TYPE sy-ucomm.

  PRIVATE SECTION.
    TYPES: BEGIN OF ty_doc,
             rsnum    TYPE rsnum,
             rspos    TYPE rspos,
             mblnr    TYPE mblnr,
             mjahr    TYPE mjahr,
             menge    TYPE menge_d,
             reversed TYPE abap_bool,
           END OF ty_doc.
    TYPES tt_doc TYPE STANDARD TABLE OF ty_doc WITH DEFAULT KEY.

    DATA: mt_out    TYPE tt_out,
          mt_doc    TYPE tt_doc,                " 301 documents posted per reservation item
          mv_run_id TYPE sysuuid_c32.

    METHODS select_data.
    METHODS post_selected.
    METHODS reverse_docs
      IMPORTING is_out        TYPE ty_out
      RETURNING VALUE(rv_err) TYPE string.
    METHODS delete_item
      IMPORTING is_out        TYPE ty_out
      RETURNING VALUE(rv_err) TYPE string.
    METHODS write_reversal_log
      IMPORTING is_out   TYPE ty_out
                is_doc   TYPE ty_doc
                iv_mblnr TYPE mblnr
                iv_mjahr TYPE mjahr.
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
    select_data( ).
    IF mt_out IS INITIAL.
      MESSAGE 'No reservation found for the selection (generator log, transfer log, RESB)' TYPE 'S'.
      RETURN.
    ENDIF.
    display_alv( ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD select_data.
    " Candidate reservation items. Three sources, in this order of priority:
    "   a) the generator log ZPTP_301_RES_LOG: the LATEST reservation item per
    "      order / kind / item;
    "   b) the transfer log ZPTP_301_TRF_LOG: items that were followed by a 301 posting
    "      (still found when the generator log has been cleaned);
    "   c) RESB: 301 reservation items whose goods recipient is the order number (the
    "      generator writes it there). Only when the selection is restricted
    "      (reservation, order or material), to avoid reading the whole table.
    TYPES: BEGIN OF ty_cand,
             rsnum    TYPE rsnum,
             rspos    TYPE rspos,
             aufnr    TYPE aufnr,
             res_kind TYPE c LENGTH 1,
             werks_fr TYPE werks_d,
             origin   TYPE c LENGTH 14,
           END OF ty_cand.
    DATA lt_cand TYPE SORTED TABLE OF ty_cand WITH UNIQUE KEY rsnum rspos.

    " a) generator log
    SELECT aufnr, res_kind, posnr, rsnum, rspos, erdat, erzet, werks_fr, werks_to
      FROM zptp_301_res_log
      WHERE rsnum  <> @space
        AND rsnum  IN @so_rsnum
        AND aufnr  IN @so_aufnr
        AND matnr  IN @so_matnr
        AND erdat  IN @so_erdat
      INTO TABLE @DATA(lt_log).
    SORT lt_log BY aufnr res_kind posnr ASCENDING erdat DESCENDING erzet DESCENDING.
    DELETE ADJACENT DUPLICATES FROM lt_log COMPARING aufnr res_kind posnr.
    LOOP AT lt_log ASSIGNING FIELD-SYMBOL(<l>).
      INSERT VALUE #( rsnum = <l>-rsnum rspos = <l>-rspos aufnr = <l>-aufnr
                      res_kind = <l>-res_kind werks_fr = <l>-werks_fr
                      origin = 'Generator log' ) INTO TABLE lt_cand.
    ENDLOOP.

    " b) transfer log: successful 301 postings
    SELECT DISTINCT rsnum, rspos, aufnr, werks_fr
      FROM zptp_301_trf_log
      WHERE status = 'S'
        AND mov_mblnr <> @space
        AND rsnum IN @so_rsnum
        AND aufnr IN @so_aufnr
        AND matnr IN @so_matnr
        AND erdat IN @so_erdat
      INTO TABLE @DATA(lt_tk).
    LOOP AT lt_tk ASSIGNING FIELD-SYMBOL(<k>).
      INSERT VALUE #( rsnum = <k>-rsnum rspos = <k>-rspos aufnr = <k>-aufnr
                      werks_fr = <k>-werks_fr origin = 'Transfer log' ) INTO TABLE lt_cand.
    ENDLOOP.

    " c) RESB goods recipient (only for a restricted selection)
    IF so_rsnum IS NOT INITIAL OR so_aufnr IS NOT INITIAL OR so_matnr IS NOT INITIAL.
      SELECT rsnum, rspos, wempf, werks
        FROM resb
        WHERE bwart  = '301'
          AND wempf <> @space
          AND xloek  = @space
          AND rsnum IN @so_rsnum
          AND wempf IN @so_aufnr
          AND matnr IN @so_matnr
        INTO TABLE @DATA(lt_wk).
      LOOP AT lt_wk ASSIGNING FIELD-SYMBOL(<w>).
        INSERT VALUE #( rsnum = <w>-rsnum rspos = <w>-rspos
                        aufnr = CONV aufnr( <w>-wempf ) werks_fr = <w>-werks
                        origin = 'RESB recipient' ) INTO TABLE lt_cand.
      ENDLOOP.
    ENDIF.

    IF lt_cand IS INITIAL.
      RETURN.
    ENDIF.

    " 2) the reservation items that still exist (deletion indicator not set)
    SELECT rsnum, rspos, matnr, werks, umwrk, bdmng, enmng, meins, wempf, kzear
      FROM resb
      FOR ALL ENTRIES IN @lt_cand
      WHERE rsnum = @lt_cand-rsnum
        AND rspos = @lt_cand-rspos
        AND xloek = @space
      INTO TABLE @DATA(lt_resb).
    IF lt_resb IS INITIAL.
      RETURN.
    ENDIF.
    SORT lt_resb BY rsnum rspos.

    " 3) 301 postings of these items (successful, material document known)
    SELECT rsnum, rspos, mov_mblnr, mov_mjahr, menge
      FROM zptp_301_trf_log
      FOR ALL ENTRIES IN @lt_resb
      WHERE rsnum  = @lt_resb-rsnum
        AND rspos  = @lt_resb-rspos
        AND status = 'S'
        AND mov_mblnr <> @space
      INTO TABLE @DATA(lt_trf).

    " documents that were already reversed (cancellation document points to them)
    IF lt_trf IS NOT INITIAL.
      SELECT smbln, sjahr FROM mseg
        FOR ALL ENTRIES IN @lt_trf
        WHERE smbln = @lt_trf-mov_mblnr
          AND sjahr = @lt_trf-mov_mjahr
        INTO TABLE @DATA(lt_rev).
      SORT lt_rev BY smbln sjahr.
    ENDIF.
    LOOP AT lt_trf ASSIGNING FIELD-SYMBOL(<t>).
      APPEND VALUE #( rsnum    = <t>-rsnum
                      rspos    = <t>-rspos
                      mblnr    = <t>-mov_mblnr
                      mjahr    = <t>-mov_mjahr
                      menge    = <t>-menge
                      reversed = xsdbool( line_exists( lt_rev[ smbln = <t>-mov_mblnr
                                                               sjahr = <t>-mov_mjahr ] ) )
                    ) TO mt_doc.
    ENDLOOP.

    " material descriptions
    SELECT matnr, maktx FROM makt
      FOR ALL ENTRIES IN @lt_resb
      WHERE matnr = @lt_resb-matnr AND spras = @sy-langu
      INTO TABLE @DATA(lt_makt).
    SORT lt_makt BY matnr.

    " 4) result lines (one per reservation item)
    LOOP AT lt_cand ASSIGNING FIELD-SYMBOL(<c>).
      READ TABLE lt_resb ASSIGNING FIELD-SYMBOL(<r>)
           WITH KEY rsnum = <c>-rsnum rspos = <c>-rspos BINARY SEARCH.
      IF sy-subrc <> 0.
        CONTINUE.                                      " deleted: not listed
      ENDIF.
      DATA(ls_out) = VALUE ty_out(
        rsnum    = <r>-rsnum
        rspos    = <r>-rspos
        aufnr    = <c>-aufnr
        res_kind = <c>-res_kind
        origin   = <c>-origin
        matnr    = <r>-matnr
        maktx    = VALUE #( lt_makt[ matnr = <r>-matnr ]-maktx OPTIONAL )
        werks_fr = <c>-werks_fr
        werks_to = <r>-umwrk
        bdmng    = <r>-bdmng
        enmng    = <r>-enmng
        meins    = <r>-meins
        state    = COND #( WHEN <r>-kzear = abap_true OR <r>-bdmng <= <r>-enmng
                           THEN 'Closed' ELSE 'Open' ) ).

      " 301 movements not yet reversed
      LOOP AT mt_doc ASSIGNING FIELD-SYMBOL(<d>)
           WHERE rsnum = ls_out-rsnum AND rspos = ls_out-rspos AND reversed = abap_false.
        ls_out-mov_qty = ls_out-mov_qty + <d>-menge.
        ls_out-mblnr   = <d>-mblnr.
        ls_out-mjahr   = <d>-mjahr.
        ls_out-followed = 'Yes'.
      ENDLOOP.
      IF ls_out-followed IS INITIAL.
        ls_out-followed = 'No'.
      ENDIF.
      ls_out-action = COND #( WHEN ls_out-followed = 'Yes'
                              THEN 'Reverse 301, then delete'
                              ELSE 'Delete reservation item' ).
      APPEND ls_out TO mt_out.
    ENDLOOP.
    SORT mt_out BY aufnr res_kind rsnum rspos.
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
    DATA lv_count TYPE i.
    LOOP AT mt_out TRANSPORTING NO FIELDS WHERE sel = abap_true AND state <> 'Deleted'.
      lv_count = lv_count + 1.
    ENDLOOP.
    IF lv_count = 0.
      MESSAGE 'No item selected' TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.

    DATA lv_answer TYPE c LENGTH 1.
    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        titlebar              = 'Delete reservation items'
        text_question         = |{ lv_count } reservation item(s) will be deleted; material documents of 301 movements are reversed first. Continue?|
        default_button        = '2'
        display_cancel_button = abap_false
      IMPORTING
        answer                = lv_answer
      EXCEPTIONS
        OTHERS                = 1.
    IF sy-subrc <> 0 OR lv_answer <> '1'.
      RETURN.
    ENDIF.

    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<o>) WHERE sel = abap_true AND state <> 'Deleted'.
      CLEAR <o>-message.

      " a) 301 movement(s): reverse the material document(s) first
      DATA(lv_err) = reverse_docs( <o> ).
      IF lv_err IS NOT INITIAL.
        <o>-icon    = icon_led_red.
        <o>-message = lv_err.
        CONTINUE.
      ENDIF.

      " b) flag the reservation item as deleted
      lv_err = delete_item( <o> ).
      IF lv_err IS NOT INITIAL.
        <o>-icon    = icon_led_yellow.
        <o>-message = COND #( WHEN <o>-followed = 'Yes'
                              THEN |Material document(s) reversed, but the item was not deleted: { lv_err }|
                              ELSE lv_err ).
        <o>-followed = 'No'.                           " the movements are reversed now
        CONTINUE.
      ENDIF.

      <o>-icon     = icon_led_green.
      <o>-state    = 'Deleted'.
      <o>-action   = space.
      <o>-message  = COND #( WHEN <o>-followed = 'Yes'
                             THEN 'Material document(s) reversed, reservation item deleted'
                             ELSE 'Reservation item deleted' ).
      <o>-sel      = abap_false.
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD reverse_docs.
    " Reverses every 301 material document of the item that is not reversed yet.
    " Stops at the first error (that document and the following ones stay).
    LOOP AT mt_doc ASSIGNING FIELD-SYMBOL(<d>)
         WHERE rsnum = is_out-rsnum AND rspos = is_out-rspos AND reversed = abap_false.

      DATA: ls_headret TYPE bapi2017_gm_head_ret,
            lt_ret     TYPE STANDARD TABLE OF bapiret2.
      CLEAR: ls_headret, lt_ret.

      CALL FUNCTION 'BAPI_GOODSMVT_CANCEL'
        EXPORTING
          materialdocument    = <d>-mblnr
          matdocumentyear     = <d>-mjahr
          goodsmvt_pstng_date = p_budat
        IMPORTING
          goodsmvt_headret    = ls_headret
        TABLES
          return              = lt_ret.

      DATA(ls_err) = VALUE bapiret2( lt_ret[ type = 'E' ] OPTIONAL ).
      IF ls_err IS INITIAL.
        ls_err = VALUE bapiret2( lt_ret[ type = 'A' ] OPTIONAL ).
      ENDIF.
      IF ls_err IS NOT INITIAL.
        CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
        rv_err = |Reversal of material document { <d>-mblnr }/{ <d>-mjahr } failed: | &&
                 |{ ls_err-message } ({ ls_err-id } { ls_err-number })|.
        RETURN.
      ENDIF.

      CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = abap_true.
      <d>-reversed = abap_true.
      write_reversal_log( is_out   = is_out
                          is_doc   = <d>
                          iv_mblnr = ls_headret-mat_doc
                          iv_mjahr = ls_headret-doc_year ).
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD delete_item.
    " Deletion indicator of the reservation item (RESB-XLOEK).
    DATA: lt_items  TYPE STANDARD TABLE OF bapi2093_res_item_change,
          lt_itemsx TYPE STANDARD TABLE OF bapi2093_res_item_changex,
          lt_return TYPE STANDARD TABLE OF bapiret2.

    lt_items  = VALUE #( ( res_item = is_out-rspos delete_ind = abap_true ) ).
    lt_itemsx = VALUE #( ( res_item = is_out-rspos delete_ind = abap_true ) ).

    TRY.
        CALL FUNCTION 'BAPI_RESERVATION_CHANGE'
          EXPORTING
            reservation               = is_out-rsnum
          TABLES
            reservationitems_changed  = lt_items
            reservationitems_changedx = lt_itemsx
            return                    = lt_return.
      CATCH cx_sy_dyn_call_error INTO DATA(lx_call).
        rv_err = lx_call->get_text( ).
        RETURN.
    ENDTRY.

    DATA(ls_err) = VALUE bapiret2( lt_return[ type = 'E' ] OPTIONAL ).
    IF ls_err IS INITIAL.
      ls_err = VALUE bapiret2( lt_return[ type = 'A' ] OPTIONAL ).
    ENDIF.
    IF ls_err IS NOT INITIAL.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      rv_err = |{ ls_err-message } ({ ls_err-id } { ls_err-number })|.
      RETURN.
    ENDIF.
    CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = abap_true.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD write_reversal_log.
    " Reversal of a 301 document, logged like a transfer attempt, status R.
    " (Key RSNUM / RSPOS / ERDAT / ERZET: two reversals of the same item in
    " the same second overwrite each other.)
    DATA(ls_log) = VALUE zptp_301_trf_log(
      rsnum     = is_out-rsnum
      rspos     = is_out-rspos
      aufnr     = is_out-aufnr
      matnr     = is_out-matnr
      werks_fr  = is_out-werks_fr
      werks_to  = is_out-werks_to
      menge     = is_doc-menge
      meins     = is_out-meins
      status    = 'R'
      message   = |Reversal of material document { is_doc-mblnr }/{ is_doc-mjahr }|
      mov_mblnr = iv_mblnr
      mov_mjahr = iv_mjahr
      run_id    = mv_run_id
      erdat     = sy-datum
      erzet     = sy-uzeit
      ernam     = sy-uname ).
    MODIFY zptp_301_trf_log FROM @ls_log.
    COMMIT WORK.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD display_alv.
    DATA: lt_fcat   TYPE lvc_t_fcat,
          ls_layout TYPE lvc_s_layo,
          lt_sort   TYPE lvc_t_sort.

    DEFINE _col.
      APPEND VALUE lvc_s_fcat( fieldname = &1 coltext = &2 outputlen = &3 ) TO lt_fcat.
    END-OF-DEFINITION.

    _col 'ICON'     'St.'              4.
    _col 'RSNUM'    'Reservation'      10.
    _col 'RSPOS'    'Item'             4.
    _col 'AUFNR'    'Prod. order'      12.
    _col 'RES_KIND' 'Kind'             4.
    _col 'MATNR'    'Material'         18.
    _col 'MAKTX'    'Description'      30.
    _col 'WERKS_FR' 'From plant'       5.
    _col 'WERKS_TO' 'To plant'         5.
    _col 'STATE'    'Open/Closed'      8.
    _col 'FOLLOWED' 'Followed by 301'  6.
    _col 'BDMNG'    'Res. qty'         13.
    _col 'ENMNG'    'Withdrawn'        13.
    _col 'MOV_QTY'  '301 mvt qty'      13.
    _col 'MEINS'    'UoM'              3.
    _col 'MBLNR'    'Mat. doc'         10.
    _col 'MJAHR'    'Year'             4.
    _col 'ORIGIN'   'Found via'        14.
    _col 'ACTION'   'Action on POST'   26.
    _col 'MESSAGE'  'Message'          60.

    LOOP AT lt_fcat ASSIGNING FIELD-SYMBOL(<f>).
      CASE <f>-fieldname.
        WHEN 'ICON'.
          <f>-icon = abap_true.
        WHEN 'BDMNG' OR 'ENMNG' OR 'MOV_QTY'.
          <f>-decimals_o = 3.                          " fields have 3 decimals whatever the unit
        WHEN 'MATNR'.
          <f>-ref_table = 'MARA'. <f>-ref_field = 'MATNR'.
        WHEN 'MEINS'.                                  " unit shown in the logon language
          <f>-ref_table = 'MARA'. <f>-ref_field = 'MEINS'.
          <f>-convexit  = 'CUNIT'.
      ENDCASE.
    ENDLOOP.

    lt_sort = VALUE #( ( spos = 1 fieldname = 'AUFNR'    up = abap_true group = 'UL' )
                       ( spos = 2 fieldname = 'RES_KIND' up = abap_true )
                       ( spos = 3 fieldname = 'RSNUM'    up = abap_true )
                       ( spos = 4 fieldname = 'RSPOS'    up = abap_true ) ).

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

*---------------------------------------------------------------------*
* ALV callbacks
*---------------------------------------------------------------------*
FORM set_status USING pt_extab TYPE slis_t_extab.
  SET PF-STATUS 'ZMANAGER' EXCLUDING pt_extab.
ENDFORM.

FORM user_command USING pv_ucomm    LIKE sy-ucomm
                        ps_selfield TYPE slis_selfield.
  go_app->user_command( pv_ucomm ).

  ps_selfield-refresh    = abap_true.
  ps_selfield-col_stable = abap_true.
  ps_selfield-row_stable = abap_true.
ENDFORM.

*---------------------------------------------------------------------*
START-OF-SELECTION.
  go_app = NEW lcl_app( ).
  go_app->run( ).
