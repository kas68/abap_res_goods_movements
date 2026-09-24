*&---------------------------------------------------------------------*
*& Report  ZMM_R_301_MOV_MONITOR   (txn ZMM301M)
*&---------------------------------------------------------------------*
*& E-xxx-SEG (FS-MM-301MOV-001) : Monitor & repost/catch-up utility for
*& the GR-triggered 301 transfers.
*&
*&  Mode M (Monitor) : display ZMM_301_MOV_LOG for the plant / GR posting
*&                     date window / orders (ALV)
*&  Mode P (Repost)  : re-post the entries in status E or W that have no
*&                     301 document yet, via Z_MM_301_POST_TRANSFER
*&  Mode C (Catch-up): scan MSEG/MKPF for 101 GRs in the window against
*&                     orders in the origin plant that have NO transfer
*&                     and post the missing 301s
*&
*& All filters use the GR POSTING DATE (MKPF-BUDAT), not the log date.
*& The catch-up frequency is parameter-driven (1 min .. 30 days) and uses
*& the same self-rescheduling pattern as R-xxx-SEG (ZMM_R_CREATE_301_RESERV).
*&---------------------------------------------------------------------*
REPORT zmm_r_301_mov_monitor.

TABLES sscrfields.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
PARAMETERS: p_werk_fr TYPE werks_d OBLIGATORY DEFAULT '8P01'.
SELECT-OPTIONS: so_budat FOR sy-datum OBLIGATORY,
                so_aufnr FOR ('AUFNR').
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.
PARAMETERS: p_mode TYPE c LENGTH 1 DEFAULT 'M' AS LISTBOX VISIBLE LENGTH 20
                   USER-COMMAND mod.
"          M = Monitor / P = Repost errors / C = Catch-up scan
SELECTION-SCREEN END OF BLOCK b2.

SELECTION-SCREEN BEGIN OF BLOCK b3 WITH FRAME TITLE TEXT-003.
PARAMETERS: p_sched AS CHECKBOX USER-COMMAND sch MODIF ID sch,
            p_freq  TYPE i DEFAULT 5 MODIF ID frq,
            p_funit TYPE c LENGTH 3 DEFAULT 'MIN' AS LISTBOX VISIBLE LENGTH 6
                    MODIF ID frq.
SELECTION-SCREEN END OF BLOCK b3.

CONSTANTS: gc_freq_min TYPE i VALUE 60,        " 1 minute floor (seconds)
           gc_freq_max TYPE i VALUE 2592000.   " 30 days ceiling (seconds)

*---------------------------------------------------------------------*
CLASS lcl_mon DEFINITION FINAL.
  PUBLIC SECTION.
    TYPES: BEGIN OF ty_src,
             mblnr TYPE mblnr,
             mjahr TYPE mjahr,
             zeile TYPE mblpo,
           END OF ty_src,
           tt_src TYPE STANDARD TABLE OF ty_src WITH DEFAULT KEY.
    CLASS-METHODS validate.
    CLASS-METHODS interval_secs RETURNING VALUE(rv) TYPE i.
    METHODS run.
  PRIVATE SECTION.
    DATA: ms_run    TYPE zmm_301_mov_run_log,
          mt_disp   TYPE STANDARD TABLE OF zmm_301_mov_log,
          mv_handle TYPE balloghndl.
    METHODS start_log IMPORTING iv_type TYPE c.
    METHODS finish_log IMPORTING iv_status TYPE c.
    METHODS select_log IMPORTING iv_errors_only TYPE abap_bool
                       RETURNING VALUE(rt_src)  TYPE tt_src.
    METHODS select_catchup RETURNING VALUE(rt_src) TYPE tt_src.
    METHODS repost IMPORTING it_src TYPE tt_src.
    METHODS count_display.
    METHODS display.
    METHODS bal_add IMPORTING iv_msgty TYPE symsgty iv_text TYPE csequence.
    METHODS schedule_next.
    METHODS run_id RETURNING VALUE(rv) TYPE sysuuid_c32.
ENDCLASS.

CLASS lcl_mon IMPLEMENTATION.

  METHOD validate.
    " plant must exist and carry an active control entry
    SELECT SINGLE werks FROM t001w INTO @DATA(lv_w) WHERE werks = @p_werk_fr.
    IF sy-subrc <> 0.
      MESSAGE e014(zmm301) WITH p_werk_fr.
    ENDIF.
    SELECT SINGLE werks_fr FROM zmm_301_ctrl INTO @lv_w
      WHERE werks_fr = @p_werk_fr AND active = @abap_true.
    IF sy-subrc <> 0.
      MESSAGE e026(zmm301) WITH p_werk_fr space.
    ENDIF.
    IF p_sched = abap_true.
      IF p_mode <> 'C'.
        MESSAGE e028(zmm301).            " self-reschedule only in mode C
      ENDIF.
      DATA(lv_s) = interval_secs( ).
      IF lv_s < gc_freq_min. MESSAGE e010(zmm301). ENDIF.
      IF lv_s > gc_freq_max. MESSAGE e011(zmm301). ENDIF.
    ENDIF.
  ENDMETHOD.

  METHOD run.
    start_log( p_mode ).

    CASE p_mode.
      WHEN 'M'.
        select_log( abap_false ).
        count_display( ).
      WHEN 'P'.
        repost( select_log( abap_true ) ).
        select_log( abap_false ).        " refresh display set
      WHEN 'C'.
        repost( select_catchup( ) ).
        select_log( abap_false ).
    ENDCASE.

    finish_log( COND #( WHEN ms_run-cnt_error > 0 THEN 'W' ELSE 'S' ) ).

    IF sy-batch = abap_false.
      display( ).
    ENDIF.

    IF p_sched = abap_true AND p_mode = 'C'.
      " only the catch-up mode self-reschedules; stop switch = ACTIVE flag
      SELECT SINGLE active FROM zmm_301_ctrl INTO @DATA(lv_a)
        WHERE werks_fr = @p_werk_fr AND active = @abap_true.
      IF sy-subrc = 0.
        schedule_next( ).
      ELSE.
        MESSAGE s012(zmm301).
      ENDIF.
    ENDIF.
  ENDMETHOD.

*-------------------------------------------------------------*
* select_log : movement-log rows for plant / GR posting date / orders.
*   iv_errors_only = X -> only E/W rows WITHOUT a 301 document (repost set)
*-------------------------------------------------------------*
  METHOD select_log.
    SELECT l~* FROM zmm_301_mov_log AS l
      INNER JOIN mkpf AS h ON h~mblnr = l~src_mblnr AND h~mjahr = l~src_mjahr
      INNER JOIN mseg AS s ON s~mblnr = l~src_mblnr AND s~mjahr = l~src_mjahr
                          AND s~zeile = l~src_zeile
      WHERE s~werks = @p_werk_fr
        AND h~budat IN @so_budat
        AND l~aufnr IN @so_aufnr
      INTO TABLE @mt_disp.

    IF iv_errors_only = abap_true.
      rt_src = VALUE #( FOR r IN mt_disp
                        WHERE ( ( status = 'E' OR status = 'W' ) AND mov_mblnr IS INITIAL )
                        ( mblnr = r-src_mblnr mjahr = r-src_mjahr zeile = r-src_zeile ) ).
      ms_run-cnt_scanned = lines( rt_src ).
    ENDIF.
  ENDMETHOD.

*-------------------------------------------------------------*
* select_catchup : 101 GR lines in the window with no 301 posted yet
*-------------------------------------------------------------*
  METHOD select_catchup.
    SELECT s~mblnr, s~mjahr, s~zeile
      FROM mseg AS s
      INNER JOIN mkpf AS h ON h~mblnr = s~mblnr AND h~mjahr = s~mjahr
      WHERE s~bwart = '101'
        AND s~werks = @p_werk_fr
        AND s~aufnr <> @space
        AND s~aufnr IN @so_aufnr
        AND h~budat IN @so_budat
      INTO TABLE @DATA(lt_gr).
    ms_run-cnt_scanned = lines( lt_gr ).

    LOOP AT lt_gr ASSIGNING FIELD-SYMBOL(<g>).
      SELECT SINGLE mov_mblnr FROM zmm_301_mov_log INTO @DATA(lv_doc)
        WHERE src_mblnr = @<g>-mblnr
          AND src_mjahr = @<g>-mjahr
          AND src_zeile = @<g>-zeile.
      IF sy-subrc = 0 AND lv_doc IS NOT INITIAL.
        ms_run-cnt_skipped = ms_run-cnt_skipped + 1.   " already transferred
        CONTINUE.
      ENDIF.
      APPEND VALUE #( mblnr = <g>-mblnr mjahr = <g>-mjahr zeile = <g>-zeile ) TO rt_src.
    ENDLOOP.
  ENDMETHOD.

*-------------------------------------------------------------*
* repost : call the posting FM per source item (idempotent) and count
*-------------------------------------------------------------*
  METHOD repost.
    LOOP AT it_src ASSIGNING FIELD-SYMBOL(<e>).
      CALL FUNCTION 'Z_MM_301_POST_TRANSFER'
        EXPORTING
          iv_mblnr    = <e>-mblnr
          iv_mjahr    = <e>-mjahr
          iv_zeile    = <e>-zeile
          iv_reversal = abap_false
          iv_run_id   = ms_run-run_id.
      " re-read outcome
      SELECT SINGLE status, mov_mblnr, message FROM zmm_301_mov_log INTO @DATA(ls_o)
        WHERE src_mblnr = @<e>-mblnr
          AND src_mjahr = @<e>-mjahr
          AND src_zeile = @<e>-zeile.
      IF ls_o-mov_mblnr IS NOT INITIAL.
        ms_run-cnt_posted = ms_run-cnt_posted + 1.
        IF ls_o-status = 'W'. ms_run-cnt_warning = ms_run-cnt_warning + 1. ENDIF.
      ELSEIF ls_o-status = 'W'.
        ms_run-cnt_warning = ms_run-cnt_warning + 1.
      ELSE.
        ms_run-cnt_error = ms_run-cnt_error + 1.
      ENDIF.
      bal_add( iv_msgty = SWITCH #( ls_o-status WHEN 'E' THEN 'E' WHEN 'W' THEN 'W' ELSE 'S' )
               iv_text  = |{ <e>-mblnr }/{ <e>-mjahr }/{ <e>-zeile }: { ls_o-message }| ).
    ENDLOOP.
  ENDMETHOD.

*-------------------------------------------------------------*
  METHOD count_display.
    ms_run-cnt_scanned = lines( mt_disp ).
    LOOP AT mt_disp ASSIGNING FIELD-SYMBOL(<d>).
      CASE <d>-status.
        WHEN 'S'. ms_run-cnt_posted   = ms_run-cnt_posted + 1.
        WHEN 'R'. ms_run-cnt_reversed = ms_run-cnt_reversed + 1.
        WHEN 'W'. ms_run-cnt_warning  = ms_run-cnt_warning + 1.
        WHEN 'E'. ms_run-cnt_error    = ms_run-cnt_error + 1.
      ENDCASE.
    ENDLOOP.
  ENDMETHOD.

*-------------------------------------------------------------*
  METHOD start_log.
    ms_run = VALUE #( run_id     = run_id( )
                      run_type   = iv_type
                      run_mode   = COND #( WHEN sy-batch = abap_true THEN 'B' ELSE 'O' )
                      start_date = sy-datum
                      start_time = sy-uzeit
                      status     = 'R'
                      ernam      = sy-uname ).
    IF sy-batch = abap_true.
      CALL FUNCTION 'GET_JOB_RUNTIME_INFO'
        IMPORTING  jobname  = ms_run-jobname
                   jobcount = ms_run-jobcount
        EXCEPTIONS OTHERS   = 1.
      " application log for background runs (ZMM / Z301MOV)
      DATA(ls_bal) = VALUE bal_s_log( object    = 'ZMM'
                                      subobject = 'Z301MOV'
                                      extnumber = |ZMM301M { ms_run-run_id }|
                                      aldate    = sy-datum
                                      altime    = sy-uzeit
                                      aluser    = sy-uname ).
      CALL FUNCTION 'BAL_LOG_CREATE'
        EXPORTING  i_s_log      = ls_bal
        IMPORTING  e_log_handle = mv_handle
        EXCEPTIONS OTHERS       = 1.
      IF sy-subrc <> 0. CLEAR mv_handle. ENDIF.
    ENDIF.
    MODIFY zmm_301_mov_run_log FROM @ms_run.
    COMMIT WORK.
  ENDMETHOD.

  METHOD finish_log.
    ms_run-end_date = sy-datum.
    ms_run-end_time = sy-uzeit.
    ms_run-status   = iv_status.
    DATA: t1 TYPE timestamp, t2 TYPE timestamp.
    CONVERT DATE ms_run-start_date TIME ms_run-start_time INTO TIME STAMP t1 TIME ZONE sy-zonlo.
    CONVERT DATE ms_run-end_date   TIME ms_run-end_time   INTO TIME STAMP t2 TIME ZONE sy-zonlo.
    ms_run-duration_s = cl_abap_tstmp=>subtract( tstmp1 = t2 tstmp2 = t1 ).
    ms_run-message = |Scanned { ms_run-cnt_scanned } posted { ms_run-cnt_posted } | &&
                     |skipped { ms_run-cnt_skipped } warn { ms_run-cnt_warning } err { ms_run-cnt_error }|.

    IF mv_handle IS NOT INITIAL.
      bal_add( iv_msgty = COND #( WHEN iv_status = 'W' THEN 'W' ELSE 'S' ) iv_text = ms_run-message ).
      DATA: lt_h TYPE bal_t_logh, lt_nr TYPE bal_t_lgnm.
      INSERT mv_handle INTO TABLE lt_h.
      CALL FUNCTION 'BAL_DB_SAVE'
        EXPORTING  i_t_log_handle   = lt_h
        IMPORTING  e_new_lognumbers = lt_nr
        EXCEPTIONS OTHERS           = 1.
      IF sy-subrc = 0 AND lt_nr IS NOT INITIAL.
        ms_run-ballognr = lt_nr[ 1 ]-lognumber.
      ENDIF.
    ENDIF.

    MODIFY zmm_301_mov_run_log FROM @ms_run.
    COMMIT WORK.
  ENDMETHOD.

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

  METHOD display.
    TRY.
        cl_salv_table=>factory(
          IMPORTING r_salv_table = DATA(lo)
          CHANGING  t_table      = mt_disp ).
        lo->get_functions( )->set_all( abap_true ).
        lo->get_columns( )->set_optimize( abap_true ).
        lo->display( ).
      CATCH cx_salv_msg INTO DATA(lx).
        MESSAGE lx->get_text( ) TYPE 'I'.
    ENDTRY.
  ENDMETHOD.

  METHOD interval_secs.
    CASE p_funit.
      WHEN 'MIN'. rv = p_freq * 60.
      WHEN 'HRS'. rv = p_freq * 3600.
      WHEN 'DAY'. rv = p_freq * 86400.
      WHEN OTHERS. rv = p_freq * 60.
    ENDCASE.
  ENDMETHOD.

  METHOD schedule_next.
    DATA: lv_date TYPE d, lv_time TYPE t, lv_ts TYPE timestamp,
          lv_job TYPE btcjob VALUE 'ZMM301M_CHAIN', lv_cnt TYPE btcjobcnt.
    lv_date = sy-datum. lv_time = sy-uzeit.
    CONVERT DATE lv_date TIME lv_time INTO TIME STAMP lv_ts TIME ZONE sy-zonlo.
    lv_ts = cl_abap_tstmp=>add( tstmp = lv_ts secs = interval_secs( ) ).
    CONVERT TIME STAMP lv_ts TIME ZONE sy-zonlo INTO DATE lv_date TIME lv_time.

    CALL FUNCTION 'JOB_OPEN'
      EXPORTING jobname = lv_job IMPORTING jobcount = lv_cnt
      EXCEPTIONS OTHERS = 1.
    IF sy-subrc <> 0. RETURN. ENDIF.
    SUBMIT zmm_r_301_mov_monitor
      WITH p_werk_fr = p_werk_fr
      WITH so_budat  IN so_budat
      WITH so_aufnr  IN so_aufnr
      WITH p_mode    = 'C'
      WITH p_sched   = p_sched
      WITH p_freq    = p_freq
      WITH p_funit   = p_funit
      VIA JOB lv_job NUMBER lv_cnt AND RETURN.
    CALL FUNCTION 'JOB_CLOSE'
      EXPORTING jobcount = lv_cnt jobname = lv_job
                sdlstrtdt = lv_date sdlstrttm = lv_time
      EXCEPTIONS OTHERS = 1.
    MESSAGE s013(zmm301) WITH lv_date lv_time.
  ENDMETHOD.

  METHOD run_id.
    TRY.
        rv = cl_system_uuid=>create_uuid_c32_static( ).
      CATCH cx_uuid_error.
        rv = |{ sy-datum }{ sy-uzeit }{ sy-index }|.
    ENDTRY.
  ENDMETHOD.

ENDCLASS.

*---------------------------------------------------------------------*
INITIALIZATION.
  " default posting-date window = current month
  DATA(gv_first) = CONV d( |{ sy-datum(6) }01| ).
  DATA(gv_last)  = gv_first.
  CALL FUNCTION 'RP_LAST_DAY_OF_MONTHS'
    EXPORTING  day_in            = gv_first
    IMPORTING  last_day_of_month = gv_last
    EXCEPTIONS OTHERS            = 1.
  so_budat[] = VALUE #( ( sign = 'I' option = 'BT' low = gv_first high = gv_last ) ).

  " listboxes
  CALL FUNCTION 'VRM_SET_VALUES'
    EXPORTING id     = 'P_MODE'
              values = VALUE vrm_values( ( key = 'M' text = 'Monitor' )
                                         ( key = 'P' text = 'Repost errors' )
                                         ( key = 'C' text = 'Catch-up scan' ) ).
  CALL FUNCTION 'VRM_SET_VALUES'
    EXPORTING id     = 'P_FUNIT'
              values = VALUE vrm_values( ( key = 'MIN' text = 'Minutes' )
                                         ( key = 'HRS' text = 'Hours' )
                                         ( key = 'DAY' text = 'Days' ) ).

*---------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
  LOOP AT SCREEN.
    IF screen-group1 = 'FRQ' AND p_sched = abap_false.
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.

AT SELECTION-SCREEN.
  IF sscrfields-ucomm = 'ONLI' OR sy-batch = abap_true.
    lcl_mon=>validate( ).
  ENDIF.

*---------------------------------------------------------------------*
START-OF-SELECTION.
  NEW lcl_mon( )->run( ).
