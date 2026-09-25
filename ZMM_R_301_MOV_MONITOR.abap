*&---------------------------------------------------------------------*
*& Report  ZMM_R_301_MOV_MONITOR   (txn ZMM301M)
*&---------------------------------------------------------------------*
*& FS-MM-301MOV-001 : Monitor & repost/catch-up utility for the
*& GR-triggered 301 transfers.
*&
*&  Mode M (Monitor) : display ZMM_301_MOV_LOG (ALV)
*&  Mode P (Repost)  : re-post failed / warning entries via
*&                     Z_MM_301_POST_TRANSFER (idempotent)
*&  Mode C (Catch-up): scan MSEG for 101 GRs in the window against orders
*&                     in the origin plant that have NO successful transfer,
*&                     and post the missing 301s
*&
*& The catch-up frequency is parameter-driven (1 min .. days) and uses the
*& same self-rescheduling pattern as FS-MM-301RES-001 §6.9.
*&---------------------------------------------------------------------*
REPORT zmm_r_301_mov_monitor.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
PARAMETERS: p_werk_fr TYPE werks_d OBLIGATORY DEFAULT '8P01'.
SELECT-OPTIONS: so_budat FOR sy-datum,
                so_aufnr FOR ('AUFNR').
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.
PARAMETERS: p_mode TYPE c LENGTH 1 DEFAULT 'M' AS LISTBOX VISIBLE LENGTH 20.
"          M = Monitor / P = Repost errors / C = Catch-up scan
SELECTION-SCREEN END OF BLOCK b2.

SELECTION-SCREEN BEGIN OF BLOCK b3 WITH FRAME TITLE TEXT-003.
PARAMETERS: p_sched AS CHECKBOX,
            p_freq  TYPE i DEFAULT 5,
            p_funit TYPE c LENGTH 3 DEFAULT 'MIN' AS LISTBOX VISIBLE LENGTH 6.
SELECTION-SCREEN END OF BLOCK b3.

CONSTANTS: gc_freq_min TYPE i VALUE 60,
           gc_freq_max TYPE i VALUE 2592000.

*---------------------------------------------------------------------*
CLASS lcl_mon DEFINITION FINAL.
  PUBLIC SECTION.
    METHODS run.
  PRIVATE SECTION.
    DATA: ms_run  TYPE zmm_301_mov_run_log,
          mt_disp TYPE STANDARD TABLE OF zmm_301_mov_log.
    METHODS start_log IMPORTING iv_type TYPE c.
    METHODS finish_log IMPORTING iv_status TYPE c.
    METHODS monitor.
    METHODS repost_errors.
    METHODS catch_up.
    METHODS display.
    METHODS interval_secs RETURNING VALUE(rv) TYPE i.
    METHODS schedule_next.
    METHODS run_id RETURNING VALUE(rv) TYPE sysuuid_c32.
ENDCLASS.

CLASS lcl_mon IMPLEMENTATION.

  METHOD run.
    IF p_sched = abap_true.
      DATA(lv_s) = interval_secs( ).
      IF lv_s < gc_freq_min OR lv_s > gc_freq_max.
        MESSAGE e010(zmm301).
      ENDIF.
    ENDIF.

    start_log( p_mode ).
    CASE p_mode.
      WHEN 'M'. monitor( ).
      WHEN 'P'. repost_errors( ).
      WHEN 'C'. catch_up( ).
    ENDCASE.
    finish_log( COND #( WHEN ms_run-cnt_error > 0 THEN 'W' ELSE 'S' ) ).

    IF sy-batch = abap_false.
      display( ).
    ENDIF.

    IF p_sched = abap_true AND p_mode = 'C'.
      " only the catch-up mode self-reschedules
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
  METHOD monitor.
    SELECT * FROM zmm_301_mov_log INTO TABLE @mt_disp
      WHERE erdat IN @so_budat
        AND aufnr IN @so_aufnr.
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
  METHOD repost_errors.
    SELECT * FROM zmm_301_mov_log INTO TABLE @DATA(lt_err)
      WHERE erdat IN @so_budat
        AND aufnr IN @so_aufnr
        AND status IN ( 'E', 'W' ).
    ms_run-cnt_scanned = lines( lt_err ).

    LOOP AT lt_err ASSIGNING FIELD-SYMBOL(<e>).
      CALL FUNCTION 'Z_MM_301_POST_TRANSFER'
        EXPORTING
          iv_mblnr    = <e>-src_mblnr
          iv_mjahr    = <e>-src_mjahr
          iv_zeile    = <e>-src_zeile
          iv_reversal = abap_false
          iv_run_id   = ms_run-run_id
          iv_commit   = abap_true.        " synchronous call -> FM commits
      " re-read outcome
      SELECT SINGLE status FROM zmm_301_mov_log INTO @DATA(lv_st)
        WHERE src_mblnr = @<e>-src_mblnr
          AND src_mjahr = @<e>-src_mjahr
          AND src_zeile = @<e>-src_zeile.
      IF lv_st = 'S'. ms_run-cnt_posted = ms_run-cnt_posted + 1.
      ELSE.           ms_run-cnt_error  = ms_run-cnt_error + 1. ENDIF.
    ENDLOOP.

    monitor( ).   " refresh display set
  ENDMETHOD.

*-------------------------------------------------------------*
  METHOD catch_up.
    " GR 101 lines against orders in origin plant within the window.
    " Posting date lives on MKPF, so join MSEG to MKPF.
    SELECT s~mblnr, s~mjahr, s~zeile, s~aufnr, s~matnr
      FROM mseg AS s
      INNER JOIN mkpf AS h ON h~mblnr = s~mblnr AND h~mjahr = s~mjahr
      INTO TABLE @DATA(lt_gr)
      WHERE s~bwart = '101'
        AND s~werks = @p_werk_fr
        AND s~aufnr <> @space
        AND s~aufnr IN @so_aufnr
        AND h~budat IN @so_budat.
    ms_run-cnt_scanned = lines( lt_gr ).

    LOOP AT lt_gr ASSIGNING FIELD-SYMBOL(<g>).
      " skip if a successful transfer already exists
      SELECT SINGLE status FROM zmm_301_mov_log INTO @DATA(lv_st)
        WHERE src_mblnr = @<g>-mblnr
          AND src_mjahr = @<g>-mjahr
          AND src_zeile = @<g>-zeile.
      IF sy-subrc = 0 AND lv_st = 'S'.
        ms_run-cnt_skipped = ms_run-cnt_skipped + 1.
        CONTINUE.
      ENDIF.

      CALL FUNCTION 'Z_MM_301_POST_TRANSFER'
        EXPORTING
          iv_mblnr    = <g>-mblnr
          iv_mjahr    = <g>-mjahr
          iv_zeile    = <g>-zeile
          iv_reversal = abap_false
          iv_run_id   = ms_run-run_id
          iv_commit   = abap_true.        " synchronous call -> FM commits

      SELECT SINGLE status FROM zmm_301_mov_log INTO @lv_st
        WHERE src_mblnr = @<g>-mblnr
          AND src_mjahr = @<g>-mjahr
          AND src_zeile = @<g>-zeile.
      CASE lv_st.
        WHEN 'S'. ms_run-cnt_posted  = ms_run-cnt_posted + 1.
        WHEN 'W'. ms_run-cnt_warning = ms_run-cnt_warning + 1.
        WHEN OTHERS. ms_run-cnt_error = ms_run-cnt_error + 1.
      ENDCASE.
    ENDLOOP.

    monitor( ).
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
    MODIFY zmm_301_mov_run_log FROM @ms_run.
    COMMIT WORK.
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
START-OF-SELECTION.
  NEW lcl_mon( )->run( ).
