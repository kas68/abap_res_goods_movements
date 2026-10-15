*&---------------------------------------------------------------------*
*& Report  ZPTP_301_LOG_MANAGER   (txn ZPTP_301_LOG)
*&---------------------------------------------------------------------*
*& Log manager for the three log tables of the 301 reservation process:
*&   ZPTP_301_RES_LOG  item log of the reservation generator
*&   ZPTP_301_TRF_LOG  log of the 301 postings (and their reversals, status R)
*&   ZPTP_301_RUN_LOG  run log of the reservation generator
*&
*& Selection : production order, reservation, run ID, execution date.
*& The ALV list has a checkbox on every line; the DELETE function deletes the
*& log records of the ticked items.
*& Option    : 'Clean all logs' (after a warning) deletes ALL rows of the three
*&             log tables, whatever the selection.
*&
*& One line per reservation item of the logs (production order, kind, item,
*& reservation / item). For every line the report shows the kind and the last
*& status of the item in the generator log (both highlighted), the state of the
*& reservation item in RESB, the 301 postings and checks that the three log
*& tables are consistent with the status (and with RESB / MSEG):
*&   - last status closed (X) / complete (F) but the item is still open in RESB
*&   - reservation item not found in RESB, or deleted while the log does not say so
*&   - quantity of the log different from RESB (statuses R / N)
*&   - material document of a posting not found in MSEG
*&   - document reversed in MSEG but no reversal row (status R) in the transfer log
*&   - withdrawn quantity of RESB different from the 301 postings of the log
*&   - run ID of the item log missing in the run log
*&
*& Deleting an item removes ALL its rows of ZPTP_301_RES_LOG and
*& ZPTP_301_TRF_LOG, then the rows of ZPTP_301_RUN_LOG of the runs that have
*& no item row left. An item whose reservation still exists and is followed by
*& a 301 posting that is not reversed is BLOCKED (reverse the posting first with
*& ZPTP_301_RESERVATION_MANAGER).
*&
*& GUI status ZLOGMGR (copy of STANDARD_FULLSCREEN of SAPLKKBL) with the extra
*& function DELETE must exist in this program (SE41).
*&---------------------------------------------------------------------*
REPORT zptp_301_log_manager.

TYPE-POOLS: abap, icon.

*---------------------------------------------------------------------*
* Selection screen
*---------------------------------------------------------------------*
DATA: gv_aufnr TYPE aufnr,
      gv_rsnum TYPE rsnum,
      gv_runid TYPE sysuuid_c32.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.   " Selection
SELECT-OPTIONS: so_aufnr FOR gv_aufnr,                          " production order
                so_rsnum FOR gv_rsnum,                          " reservation
                so_runid FOR gv_runid NO INTERVALS,             " run ID
                so_erdat FOR sy-datum.                          " execution date
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.   " Options
PARAMETERS: p_clrlg AS CHECKBOX.                                " clean all logs (the 3 log tables)
SELECTION-SCREEN END OF BLOCK b2.

*---------------------------------------------------------------------*
* Local class : application engine
*---------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.

  PUBLIC SECTION.
    TYPES: BEGIN OF ty_out,
             sel        TYPE abap_bool,
             icon       TYPE c LENGTH 4,            " consistency: green / yellow / red
             aufnr      TYPE aufnr,
             res_kind   TYPE c LENGTH 1,            " H finished product / R component
             posnr      TYPE co_posnr,
             rsnum      TYPE rsnum,
             rspos      TYPE rspos,
             last_stat  TYPE c LENGTH 1,            " last status in ZPTP_301_RES_LOG
             stat_txt   TYPE c LENGTH 10,
             resb_state TYPE c LENGTH 8,            " Open / Closed / Deleted / Missing / -
             bdmng      TYPE bdmng,                 " RESB required quantity
             enmng      TYPE enmng,                 " RESB withdrawn quantity
             log_bdmng  TYPE menge_d,               " required quantity in the log (last row)
             mov_qty    TYPE menge_d,               " 301 postings not reversed
             mblnr      TYPE mblnr,                 " last 301 document not reversed
             n_res      TYPE i,                     " rows in ZPTP_301_RES_LOG
             n_trf      TYPE i,                     " rows in ZPTP_301_TRF_LOG
             n_run      TYPE i,                     " runs of the item found in ZPTP_301_RUN_LOG
             in_run     TYPE abap_bool,             " the record is in the run log
             in_res     TYPE abap_bool,             " the record is in the item log
             in_trf     TYPE abap_bool,             " the record is in the transfer log
             last_run   TYPE sysuuid_c32,
             last_date  TYPE erdat,
             meins      TYPE meins,
             blocked    TYPE abap_bool,             " active 301 posting: cannot be deleted
             done       TYPE abap_bool,             " log records deleted in this session
             check_txt  TYPE string,                " result of the consistency check
             coltab     TYPE lvc_t_scol,
           END OF ty_out.
    TYPES tt_out TYPE STANDARD TABLE OF ty_out WITH DEFAULT KEY.

    METHODS run.
    METHODS user_command
      IMPORTING iv_ucomm TYPE sy-ucomm.

  PRIVATE SECTION.
    TYPES: BEGIN OF ty_key,
             aufnr    TYPE aufnr,
             res_kind TYPE c LENGTH 1,
             posnr    TYPE co_posnr,
             rsnum    TYPE rsnum,
             rspos    TYPE rspos,
           END OF ty_key.
    TYPES tt_key TYPE SORTED TABLE OF ty_key WITH UNIQUE KEY aufnr res_kind posnr rsnum rspos.

    DATA mt_out TYPE tt_out.

    METHODS select_data.
    METHODS clear_logs
      RETURNING VALUE(rv_done) TYPE abap_bool.
    METHODS color_row
      CHANGING cs_out TYPE ty_out.
    METHODS delete_selected.
    METHODS display_alv.

ENDCLASS.

DATA go_app TYPE REF TO lcl_app.

*---------------------------------------------------------------------*
CLASS lcl_app IMPLEMENTATION.

  METHOD run.
    " Option 'Clean all logs': after the warning, all three tables are emptied
    IF p_clrlg = abap_true.
      IF clear_logs( ) = abap_true.
        RETURN.                                         " all logs deleted: nothing to list
      ELSE.
        MESSAGE 'Run cancelled, logs not cleaned' TYPE 'E'.
      ENDIF.
    ENDIF.

    select_data( ).
    IF mt_out IS INITIAL.
      MESSAGE 'No log record found for the selection' TYPE 'S'.
      RETURN.
    ENDIF.
    display_alv( ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD clear_logs.
    " Deletes ALL rows of the item log, the transfer log and the run log,
    " whatever the selection. The user must confirm.
    SELECT COUNT(*) FROM zptp_301_res_log INTO @DATA(lv_res).
    SELECT COUNT(*) FROM zptp_301_trf_log INTO @DATA(lv_trf).
    SELECT COUNT(*) FROM zptp_301_run_log INTO @DATA(lv_run).

    DATA lv_answer TYPE c LENGTH 1.
    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        titlebar              = 'Warning: clean all logs'
        text_question         = |WARNING: ALL rows of ZPTP_301_RES_LOG ({ lv_res }), ZPTP_301_TRF_LOG ({ lv_trf }) and ZPTP_301_RUN_LOG ({ lv_run }) will be deleted, whatever the selection. Not restorable. Continue?|
        text_button_1         = 'Continue'
        text_button_2         = 'Cancel run'
        icon_button_1         = 'ICON_OKAY'
        icon_button_2         = 'ICON_CANCEL'
        default_button        = '2'
        display_cancel_button = abap_false
        popup_type            = 'ICON_MESSAGE_WARNING'
      IMPORTING
        answer                = lv_answer
      EXCEPTIONS
        OTHERS                = 1.
    IF sy-subrc <> 0 OR lv_answer <> '1'.
      RETURN.
    ENDIF.

    DELETE FROM zptp_301_res_log.
    DELETE FROM zptp_301_trf_log.
    DELETE FROM zptp_301_run_log.
    COMMIT WORK.
    MESSAGE |All logs deleted: { lv_res } item log, { lv_trf } transfer log, { lv_run } run log rows| TYPE 'S'.
    rv_done = abap_true.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD select_data.
    " 1) items hit by the selection, in the item log and in the transfer log
    DATA lt_key TYPE tt_key.

    SELECT aufnr, res_kind, posnr, rsnum, rspos
      FROM zptp_301_res_log
      WHERE aufnr  IN @so_aufnr
        AND rsnum  IN @so_rsnum
        AND run_id IN @so_runid
        AND erdat  IN @so_erdat
      INTO TABLE @DATA(lt_hit_res).
    LOOP AT lt_hit_res ASSIGNING FIELD-SYMBOL(<h>).
      INSERT VALUE #( aufnr = <h>-aufnr res_kind = <h>-res_kind posnr = <h>-posnr
                      rsnum = <h>-rsnum rspos = <h>-rspos ) INTO TABLE lt_key.
    ENDLOOP.

    SELECT DISTINCT rsnum, rspos, aufnr
      FROM zptp_301_trf_log
      WHERE aufnr  IN @so_aufnr
        AND rsnum  IN @so_rsnum
        AND run_id IN @so_runid
        AND erdat  IN @so_erdat
      INTO TABLE @DATA(lt_hit_trf).
    " Items hit through the transfer log only: look for their item log rows (any
    " run / date) to get the real key (order, kind, item). Only when there are
    " none, the item stays a transfer-log-only line (no kind).
    TYPES: BEGIN OF ty_rp,
             rsnum TYPE rsnum,
             rspos TYPE rspos,
             aufnr TYPE aufnr,
           END OF ty_rp.
    DATA lt_only TYPE STANDARD TABLE OF ty_rp WITH DEFAULT KEY.
    LOOP AT lt_hit_trf ASSIGNING FIELD-SYMBOL(<ht>).
      IF <ht>-rsnum IS INITIAL.
        INSERT VALUE #( aufnr = <ht>-aufnr rsnum = <ht>-rsnum rspos = <ht>-rspos ) INTO TABLE lt_key.
      ELSEIF NOT line_exists( lt_key[ rsnum = <ht>-rsnum rspos = <ht>-rspos ] ).
        APPEND VALUE #( rsnum = <ht>-rsnum rspos = <ht>-rspos aufnr = <ht>-aufnr ) TO lt_only.
      ENDIF.
    ENDLOOP.
    IF lt_only IS NOT INITIAL.
      SELECT DISTINCT aufnr, res_kind, posnr, rsnum, rspos
        FROM zptp_301_res_log
        FOR ALL ENTRIES IN @lt_only
        WHERE rsnum = @lt_only-rsnum
          AND rspos = @lt_only-rspos
        INTO TABLE @DATA(lt_found).
      LOOP AT lt_found ASSIGNING FIELD-SYMBOL(<fd>).
        INSERT VALUE #( aufnr = <fd>-aufnr res_kind = <fd>-res_kind posnr = <fd>-posnr
                        rsnum = <fd>-rsnum rspos = <fd>-rspos ) INTO TABLE lt_key.
      ENDLOOP.
      LOOP AT lt_only ASSIGNING FIELD-SYMBOL(<on>).
        IF NOT line_exists( lt_found[ rsnum = <on>-rsnum rspos = <on>-rspos ] ).
          INSERT VALUE #( aufnr = <on>-aufnr rsnum = <on>-rsnum rspos = <on>-rspos ) INTO TABLE lt_key.
        ENDIF.
      ENDLOOP.
    ENDIF.
    IF lt_key IS INITIAL.
      RETURN.
    ENDIF.

    DATA lt_key_std TYPE STANDARD TABLE OF ty_key WITH DEFAULT KEY.
    lt_key_std = lt_key.

    " 2) complete history of these items (not only the rows hit by the selection)
    SELECT aufnr, res_kind, posnr, run_id, rsnum, rspos, res_bdmng, status, erdat, erzet, meins
      FROM zptp_301_res_log
      FOR ALL ENTRIES IN @lt_key_std
      WHERE aufnr    = @lt_key_std-aufnr
        AND res_kind = @lt_key_std-res_kind
        AND posnr    = @lt_key_std-posnr
        AND rsnum    = @lt_key_std-rsnum
        AND rspos    = @lt_key_std-rspos
      INTO TABLE @DATA(lt_res).
    SORT lt_res BY aufnr res_kind posnr rsnum rspos erdat DESCENDING erzet DESCENDING.

    SELECT rsnum, rspos, run_id, menge, status, mov_mblnr, mov_mjahr, erdat, erzet
      FROM zptp_301_trf_log
      FOR ALL ENTRIES IN @lt_key_std
      WHERE rsnum = @lt_key_std-rsnum
        AND rspos = @lt_key_std-rspos
        AND rsnum <> @space
      INTO TABLE @DATA(lt_trf).
    SORT lt_trf BY rsnum rspos erdat erzet.

    " 3) reservation items in RESB (also deleted ones: they must be told apart)
    SELECT rsnum, rspos, bdmng, enmng, kzear, xloek, meins, wempf
      FROM resb
      FOR ALL ENTRIES IN @lt_key_std
      WHERE rsnum = @lt_key_std-rsnum
        AND rspos = @lt_key_std-rspos
        AND rsnum <> @space
      INTO TABLE @DATA(lt_resb).
    SORT lt_resb BY rsnum rspos.

    " 4) run log rows of the runs found in the item log
    DATA lt_runid TYPE SORTED TABLE OF sysuuid_c32 WITH UNIQUE KEY table_line.
    LOOP AT lt_res ASSIGNING FIELD-SYMBOL(<r0>).
      INSERT <r0>-run_id INTO TABLE lt_runid.
    ENDLOOP.
    DATA lt_run_found TYPE SORTED TABLE OF sysuuid_c32 WITH UNIQUE KEY table_line.
    IF lt_runid IS NOT INITIAL.
      DATA lt_runid_std TYPE STANDARD TABLE OF sysuuid_c32 WITH DEFAULT KEY.
      lt_runid_std = lt_runid.
      SELECT run_id FROM zptp_301_run_log
        FOR ALL ENTRIES IN @lt_runid_std
        WHERE run_id = @lt_runid_std-table_line
        INTO TABLE @DATA(lt_run).
      LOOP AT lt_run ASSIGNING FIELD-SYMBOL(<ru>).
        INSERT <ru>-run_id INTO TABLE lt_run_found.
      ENDLOOP.
    ENDIF.

    " 5) material documents of the successful postings: existence / reversal
    TYPES: BEGIN OF ty_dk,
             mblnr TYPE mblnr,
             mjahr TYPE mjahr,
           END OF ty_dk.
    DATA: lt_dk      TYPE STANDARD TABLE OF ty_dk WITH DEFAULT KEY,
          lt_dk_ok   TYPE SORTED TABLE OF ty_dk WITH UNIQUE KEY mblnr mjahr,
          lt_dk_rev  TYPE SORTED TABLE OF ty_dk WITH UNIQUE KEY mblnr mjahr.
    LOOP AT lt_trf ASSIGNING FIELD-SYMBOL(<t0>) WHERE status = 'S' AND mov_mblnr IS NOT INITIAL.
      APPEND VALUE #( mblnr = <t0>-mov_mblnr mjahr = <t0>-mov_mjahr ) TO lt_dk.
    ENDLOOP.
    IF lt_dk IS NOT INITIAL.
      SELECT DISTINCT mblnr, mjahr FROM mseg
        FOR ALL ENTRIES IN @lt_dk
        WHERE mblnr = @lt_dk-mblnr AND mjahr = @lt_dk-mjahr
        INTO TABLE @DATA(lt_mseg).
      LOOP AT lt_mseg ASSIGNING FIELD-SYMBOL(<ms>).
        INSERT VALUE #( mblnr = <ms>-mblnr mjahr = <ms>-mjahr ) INTO TABLE lt_dk_ok.
      ENDLOOP.
      SELECT DISTINCT smbln, sjahr FROM mseg
        FOR ALL ENTRIES IN @lt_dk
        WHERE smbln = @lt_dk-mblnr AND sjahr = @lt_dk-mjahr
        INTO TABLE @DATA(lt_cancel).
      LOOP AT lt_cancel ASSIGNING FIELD-SYMBOL(<cn>).
        INSERT VALUE #( mblnr = <cn>-smbln mjahr = <cn>-sjahr ) INTO TABLE lt_dk_rev.
      ENDLOOP.
    ENDIF.

    " 6) one line per item with the consistency check
    LOOP AT lt_key ASSIGNING FIELD-SYMBOL(<k>).
      DATA(ls_out) = VALUE ty_out( aufnr = <k>-aufnr res_kind = <k>-res_kind posnr = <k>-posnr
                                   rsnum = <k>-rsnum rspos = <k>-rspos resb_state = '-' ).
      DATA: lv_red    TYPE abap_bool,
            lv_yellow TYPE abap_bool,
            lt_txt    TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
      CLEAR: lv_red, lv_yellow, lt_txt.

      " item log : count, last row
      DATA(lv_first) = abap_true.
      DATA lt_runs_of_item TYPE SORTED TABLE OF sysuuid_c32 WITH UNIQUE KEY table_line.
      CLEAR lt_runs_of_item.
      LOOP AT lt_res ASSIGNING FIELD-SYMBOL(<r>)
           WHERE aufnr = <k>-aufnr AND res_kind = <k>-res_kind AND posnr = <k>-posnr
             AND rsnum = <k>-rsnum AND rspos = <k>-rspos.
        ls_out-n_res = ls_out-n_res + 1.
        INSERT <r>-run_id INTO TABLE lt_runs_of_item.
        IF lv_first = abap_true.                       " rows are sorted: newest first
          lv_first        = abap_false.
          ls_out-last_stat = <r>-status.
          ls_out-last_run  = <r>-run_id.
          ls_out-last_date = <r>-erdat.
          ls_out-log_bdmng = <r>-res_bdmng.
          ls_out-meins     = <r>-meins.
        ENDIF.
      ENDLOOP.
      ls_out-stat_txt = SWITCH #( ls_out-last_stat
                                  WHEN 'C' THEN 'Created'
                                  WHEN 'R' THEN 'Realigned'
                                  WHEN 'X' THEN 'Closed'
                                  WHEN 'N' THEN 'Unchanged'
                                  WHEN 'F' THEN 'Complete'
                                  WHEN 'K' THEN 'Skipped'
                                  WHEN 'E' THEN 'Error'
                                  WHEN 'S' THEN 'Simulated'
                                  ELSE '' ).

      " run log : runs of the item that exist in ZPTP_301_RUN_LOG
      LOOP AT lt_runs_of_item ASSIGNING FIELD-SYMBOL(<ri>).
        IF line_exists( lt_run_found[ table_line = <ri> ] ).
          ls_out-n_run = ls_out-n_run + 1.
        ELSE.
          lv_yellow = abap_true.
          APPEND |Run { <ri>(8) }... of the item log is missing in the run log| TO lt_txt.
        ENDIF.
      ENDLOOP.

      " transfer log : postings not reversed
      DATA(lv_active_qty) = CONV menge_d( 0 ).
      IF <k>-rsnum IS NOT INITIAL.
        LOOP AT lt_trf ASSIGNING FIELD-SYMBOL(<t>) WHERE rsnum = <k>-rsnum AND rspos = <k>-rspos.
          ls_out-n_trf = ls_out-n_trf + 1.
          IF <t>-status <> 'S' OR <t>-mov_mblnr IS INITIAL.
            CONTINUE.
          ENDIF.
          IF NOT line_exists( lt_dk_ok[ mblnr = <t>-mov_mblnr mjahr = <t>-mov_mjahr ] ).
            lv_red = abap_true.
            APPEND |Material document { <t>-mov_mblnr }/{ <t>-mov_mjahr } of the transfer log not found in MSEG| TO lt_txt.
          ELSEIF line_exists( lt_dk_rev[ mblnr = <t>-mov_mblnr mjahr = <t>-mov_mjahr ] ).
            " reversed in SAP: the transfer log must hold a reversal row (status R)
            IF NOT line_exists( lt_trf[ rsnum = <k>-rsnum rspos = <k>-rspos status = 'R' ] ).
              lv_yellow = abap_true.
              APPEND |Document { <t>-mov_mblnr } is reversed in SAP, no reversal row in the transfer log| TO lt_txt.
            ENDIF.
          ELSE.
            lv_active_qty = lv_active_qty + <t>-menge.
            ls_out-mblnr  = <t>-mov_mblnr.
          ENDIF.
        ENDLOOP.
      ENDIF.
      ls_out-mov_qty = lv_active_qty.

      " reservation item in RESB
      IF <k>-rsnum IS NOT INITIAL.
        READ TABLE lt_resb ASSIGNING FIELD-SYMBOL(<b>)
             WITH KEY rsnum = <k>-rsnum rspos = <k>-rspos BINARY SEARCH.
        IF sy-subrc <> 0.
          ls_out-resb_state = 'Missing'.
          IF ls_out-last_stat CA 'CRNFX'.
            lv_red = abap_true.
            APPEND |Status { ls_out-stat_txt } but the reservation item is not in RESB| TO lt_txt.
          ENDIF.
        ELSE.
          ls_out-bdmng = <b>-bdmng.
          ls_out-enmng = <b>-enmng.
          IF ls_out-meins IS INITIAL.
            ls_out-meins = <b>-meins.
          ENDIF.
          IF <b>-xloek = abap_true.
            ls_out-resb_state = 'Deleted'.
            lv_yellow = abap_true.
            APPEND `Reservation item is deleted in SAP, the log does not say so` TO lt_txt.
          ELSEIF <b>-kzear = abap_true OR <b>-bdmng <= <b>-enmng.
            ls_out-resb_state = 'Closed'.
          ELSE.
            ls_out-resb_state = 'Open'.
          ENDIF.

          IF <b>-xloek = abap_false.
            " status of the log against the real state
            IF ls_out-last_stat = 'X' AND ls_out-resb_state = 'Open'.
              lv_red = abap_true.
              APPEND `Status Closed in the log, but the item is still open in RESB` TO lt_txt.
            ENDIF.
            IF ls_out-last_stat = 'F' AND ls_out-resb_state = 'Open'.
              lv_red = abap_true.
              APPEND `Status Complete in the log, but the item is still open in RESB` TO lt_txt.
            ENDIF.
            IF ls_out-last_stat CA 'RN' AND ls_out-resb_state = 'Closed'.
              lv_yellow = abap_true.
              APPEND |Status { ls_out-stat_txt } in the log, but the item is closed in RESB| TO lt_txt.
            ENDIF.
            IF ls_out-last_stat CA 'RN' AND ls_out-log_bdmng <> <b>-bdmng.
              lv_yellow = abap_true.
              APPEND |Required quantity { <b>-bdmng } in RESB, { ls_out-log_bdmng } in the log| TO lt_txt.
            ENDIF.
            IF ls_out-n_trf > 0 AND ls_out-mov_qty <> <b>-enmng.
              lv_yellow = abap_true.
              APPEND |Withdrawn { <b>-enmng } in RESB, 301 postings of the log { ls_out-mov_qty }| TO lt_txt.
            ENDIF.
            " active 301 posting on an existing reservation: no deletion of the logs
            IF ls_out-mov_qty > 0.
              ls_out-blocked = abap_true.
              APPEND `BLOCKED: followed by a 301 posting; reverse it first (reservation manager)` TO lt_txt.
            ENDIF.
          ENDIF.
        ENDIF.
      ELSEIF ls_out-last_stat CA 'CRNFX'.
        lv_red = abap_true.
        APPEND |Status { ls_out-stat_txt } but the log has no reservation number| TO lt_txt.
      ENDIF.

      ls_out-icon = COND #( WHEN lv_red = abap_true    THEN icon_led_red
                            WHEN lv_yellow = abap_true THEN icon_led_yellow
                            ELSE icon_led_green ).
      IF lt_txt IS INITIAL.
        ls_out-check_txt = 'Consistent'.
      ELSE.
        ls_out-check_txt = concat_lines_of( table = lt_txt sep = ` | ` ).
      ENDIF.

      " presence of the record in each log table
      ls_out-in_res = xsdbool( ls_out-n_res > 0 ).
      ls_out-in_trf = xsdbool( ls_out-n_trf > 0 ).
      ls_out-in_run = xsdbool( ls_out-n_run > 0 ).

      color_row( CHANGING cs_out = ls_out ).
      APPEND ls_out TO mt_out.
    ENDLOOP.
    SORT mt_out BY aufnr res_kind rsnum rspos.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD color_row.
    " Kind and last status are highlighted (palette colours of the ALV grid):
    "   kind   : H blue-green (4), R orange (7)
    "   status : C / N / F green (5), R yellow (3), X dark grey (1), K light grey (2),
    "            E red (6), S blue-green (4)
    DATA(lv_kind_col) = SWITCH i( cs_out-res_kind WHEN 'H' THEN 4 WHEN 'R' THEN 7 ELSE 0 ).
    IF lv_kind_col > 0.
      APPEND VALUE #( fname = 'RES_KIND' color = VALUE #( col = lv_kind_col int = 1 inv = 0 ) )
             TO cs_out-coltab.
    ENDIF.
    DATA(lv_st_col) = SWITCH i( cs_out-last_stat
                                WHEN 'C' THEN 5 WHEN 'N' THEN 5 WHEN 'F' THEN 5
                                WHEN 'R' THEN 3
                                WHEN 'X' THEN 1
                                WHEN 'K' THEN 2
                                WHEN 'E' THEN 6
                                WHEN 'S' THEN 4
                                ELSE 0 ).
    IF lv_st_col > 0.
      APPEND VALUE #( fname = 'LAST_STAT' color = VALUE #( col = lv_st_col int = 1 inv = 0 ) )
             TO cs_out-coltab.
      APPEND VALUE #( fname = 'STAT_TXT' color = VALUE #( col = lv_st_col int = 1 inv = 0 ) )
             TO cs_out-coltab.
    ENDIF.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD user_command.
    CASE iv_ucomm.
      WHEN 'DELETE'.
        delete_selected( ).
    ENDCASE.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD delete_selected.
    DATA lv_count TYPE i.
    LOOP AT mt_out TRANSPORTING NO FIELDS WHERE sel = abap_true AND blocked = abap_false
                                              AND done = abap_false.
      lv_count = lv_count + 1.
    ENDLOOP.
    IF lv_count = 0.
      MESSAGE 'No deletable item selected (blocked items cannot be deleted)' TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.

    DATA lv_answer TYPE c LENGTH 1.
    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        titlebar              = 'Delete log records'
        text_question         = |The log records of { lv_count } item(s) will be deleted from the item log, the transfer log and (for runs without items) the run log. This cannot be undone. Continue?|
        text_button_1         = 'Delete'
        text_button_2         = 'Cancel'
        icon_button_1         = 'ICON_DELETE'
        icon_button_2         = 'ICON_CANCEL'
        default_button        = '2'
        display_cancel_button = abap_false
        popup_type            = 'ICON_MESSAGE_WARNING'
      IMPORTING
        answer                = lv_answer
      EXCEPTIONS
        OTHERS                = 1.
    IF sy-subrc <> 0 OR lv_answer <> '1'.
      RETURN.
    ENDIF.

    DATA lt_runs TYPE SORTED TABLE OF sysuuid_c32 WITH UNIQUE KEY table_line.
    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<o>) WHERE sel = abap_true.
      IF <o>-blocked = abap_true.
        <o>-icon      = icon_led_red.
        <o>-check_txt = |{ <o>-check_txt } | && `(not deleted)`.
        CONTINUE.
      ENDIF.
      IF <o>-done = abap_true.
        CONTINUE.
      ENDIF.

      " runs of the item (their run log row goes when no item row is left)
      SELECT run_id FROM zptp_301_res_log
        WHERE aufnr = @<o>-aufnr AND res_kind = @<o>-res_kind AND posnr = @<o>-posnr
          AND rsnum = @<o>-rsnum AND rspos = @<o>-rspos
        INTO TABLE @DATA(lt_item_runs).
      LOOP AT lt_item_runs ASSIGNING FIELD-SYMBOL(<ir>).
        INSERT <ir>-run_id INTO TABLE lt_runs.
      ENDLOOP.

      DELETE FROM zptp_301_res_log
        WHERE aufnr = @<o>-aufnr AND res_kind = @<o>-res_kind AND posnr = @<o>-posnr
          AND rsnum = @<o>-rsnum AND rspos = @<o>-rspos.
      IF <o>-rsnum IS NOT INITIAL.
        DELETE FROM zptp_301_trf_log WHERE rsnum = @<o>-rsnum AND rspos = @<o>-rspos.
      ENDIF.

      <o>-icon       = icon_led_green.
      <o>-done       = abap_true.
      <o>-check_txt  = 'Log records deleted'.
      <o>-sel        = abap_false.
    ENDLOOP.

    " run log : only the runs that have no item row left
    LOOP AT lt_runs ASSIGNING FIELD-SYMBOL(<ru>).
      SELECT SINGLE run_id FROM zptp_301_res_log INTO @DATA(lv_left) WHERE run_id = @<ru>.
      IF sy-subrc <> 0.
        DELETE FROM zptp_301_run_log WHERE run_id = @<ru>.
      ENDIF.
    ENDLOOP.
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

    _col 'ICON'       'Check'            5.
    _col 'AUFNR'      'Prod. order'      12.
    _col 'RES_KIND'   'Kind'             4.
    _col 'POSNR'      'Order item'       6.
    _col 'RSNUM'      'Reservation'      10.
    _col 'RSPOS'      'Item'             4.
    _col 'LAST_STAT'  'St.'              3.
    _col 'STAT_TXT'   'Last status'      10.
    _col 'RESB_STATE' 'RESB state'       8.
    _col 'BDMNG'      'Req. qty (RESB)'  13.
    _col 'ENMNG'      'Withdrawn (RESB)' 13.
    _col 'LOG_BDMNG'  'Req. qty (log)'   13.
    _col 'MOV_QTY'    '301 posted'       13.
    _col 'MEINS'      'UoM'              3.
    _col 'MBLNR'      'Last 301 doc'     10.
    _col 'IN_RUN'     'In Run Log'       6.
    _col 'IN_RES'     'In Res Log'       6.
    _col 'IN_TRF'     'In TRF Log'       6.
    _col 'N_RES'      'Rows item log'    6.
    _col 'N_TRF'      'Rows transfer log' 6.
    _col 'N_RUN'      'Runs in run log'  6.
    _col 'LAST_RUN'   'Last run ID'      34.
    _col 'LAST_DATE'  'Last date'        10.
    _col 'CHECK_TXT'  'Consistency check' 80.

    LOOP AT lt_fcat ASSIGNING FIELD-SYMBOL(<f>).
      CASE <f>-fieldname.
        WHEN 'ICON'.
          <f>-icon = abap_true.
        WHEN 'RES_KIND' OR 'LAST_STAT'.
          <f>-just = 'C'.
        WHEN 'IN_RUN' OR 'IN_RES' OR 'IN_TRF'.        " shown as checkboxes
          <f>-checkbox = abap_true.
          <f>-just     = 'C'.
        WHEN 'BDMNG' OR 'ENMNG' OR 'LOG_BDMNG' OR 'MOV_QTY'.
          <f>-decimals_o = 3.
        WHEN 'MEINS'.
          <f>-ref_table = 'MARA'. <f>-ref_field = 'MEINS'.
          <f>-convexit  = 'CUNIT'.
      ENDCASE.
    ENDLOOP.

    lt_sort = VALUE #( ( spos = 1 fieldname = 'AUFNR'    up = abap_true group = 'UL' )
                       ( spos = 2 fieldname = 'RES_KIND' up = abap_true )
                       ( spos = 3 fieldname = 'RSNUM'    up = abap_true )
                       ( spos = 4 fieldname = 'RSPOS'    up = abap_true ) ).

    ls_layout-box_fname  = 'SEL'.                       " row selection
    ls_layout-ctab_fname = 'COLTAB'.                    " cell colours: kind and status
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
  SET PF-STATUS 'ZLOGMGR' EXCLUDING pt_extab.
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
