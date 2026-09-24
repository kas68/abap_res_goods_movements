*&---------------------------------------------------------------------*
*& Function module  Z_MM_301_POST_TRANSFER      (function group ZMM_301_MOV)
*&---------------------------------------------------------------------*
*& E-xxx-SEG (FS-MM-301MOV-001) : Post (or reverse) the 301 transfer for
*& one goods receipt item, in its own LUW. Registered IN BACKGROUND TASK by
*& the MB_DOCUMENT_BADI implementation (ZCL_MM_301_GR_TRIGGER), and also
*& called by the monitor/repost report (ZMM_R_301_MOV_MONITOR).
*&
*& Processing type : Remote-Enabled Module (required for IN BACKGROUND TASK)
*&
*& The FM owns its LUW (own COMMIT/ROLLBACK). Never call it synchronously
*& inside another posting LUW.
*&
*& IMPORT parameters:
*&   IV_MBLNR    TYPE mblnr        Source GR material document
*&   IV_MJAHR    TYPE mjahr        Source GR document year
*&   IV_ZEILE    TYPE mblpo        Source GR item
*&   IV_REVERSAL TYPE abap_bool    'X' = GR was reversed (cancel the 301)
*&   IV_RUN_ID   TYPE sysuuid_c32  (optional) repost/catch-up run id
*&---------------------------------------------------------------------*
FUNCTION z_mm_301_post_transfer.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_MBLNR) TYPE MBLNR
*"     VALUE(IV_MJAHR) TYPE MJAHR
*"     VALUE(IV_ZEILE) TYPE MBLPO
*"     VALUE(IV_REVERSAL) TYPE ABAP_BOOL DEFAULT SPACE
*"     VALUE(IV_RUN_ID) TYPE SYSUUID_C32 OPTIONAL
*"----------------------------------------------------------------------

  DATA: ls_log TYPE zmm_301_mov_log.

*--------------------------------------------------------------------*
* 1) Idempotency – skip if this source item was already transferred.
*    "Transferred" = a 301 document exists for it (MOV_MBLNR filled):
*    status S, W (posted without reservation reference) or R (reversed).
*--------------------------------------------------------------------*
  SELECT SINGLE * FROM zmm_301_mov_log INTO @DATA(ls_prev)
    WHERE src_mblnr = @iv_mblnr
      AND src_mjahr = @iv_mjahr
      AND src_zeile = @iv_zeile.
  IF sy-subrc = 0 AND ls_prev-mov_mblnr IS NOT INITIAL AND iv_reversal = abap_false.
    RETURN.                              " already posted – nothing to do
  ENDIF.
  IF sy-subrc = 0 AND ls_prev-status = 'R' AND iv_reversal = abap_true.
    RETURN.                              " reversal already done
  ENDIF.

*--------------------------------------------------------------------*
* 2) Re-read the source GR line (persisted by now) + document header
*--------------------------------------------------------------------*
  SELECT SINGLE mblnr, mjahr, zeile, bwart, matnr, werks, lgort,
                charg, menge, meins, aufnr, smbln, sjahr, smblp
    FROM mseg INTO @DATA(ls_seg)
    WHERE mblnr = @iv_mblnr AND mjahr = @iv_mjahr AND zeile = @iv_zeile.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  SELECT SINGLE budat, bldat FROM mkpf INTO @DATA(ls_kpf)
    WHERE mblnr = @iv_mblnr AND mjahr = @iv_mjahr.

*--------------------------------------------------------------------*
* 3) Control entry for the origin plant (re-checked: the switch may have
*    been flipped after the unit was registered)
*--------------------------------------------------------------------*
  SELECT SINGLE * FROM zmm_301_ctrl INTO @DATA(ls_ctrl)
    WHERE werks_fr = @ls_seg-werks AND active = @abap_true.
  IF sy-subrc <> 0.
    RETURN.                              " automation inactive for this plant
  ENDIF.

  DATA(lv_movetype) = COND bwart( WHEN ls_ctrl-move_type IS NOT INITIAL
                                  THEN ls_ctrl-move_type ELSE '301' ).

  ls_log = VALUE #( src_mblnr = iv_mblnr
                    src_mjahr = iv_mjahr
                    src_zeile = iv_zeile
                    aufnr     = ls_seg-aufnr
                    matnr     = ls_seg-matnr
                    menge     = ls_seg-menge
                    meins     = ls_seg-meins
                    charg     = ls_seg-charg
                    run_id    = iv_run_id
                    erdat     = sy-datum
                    erzet     = sy-uzeit
                    ernam     = sy-uname ).

  " zero / negative quantity: never post
  IF ls_seg-menge <= 0.
    ls_log-status  = 'W'.
    ls_log-message = |GR { iv_mblnr }/{ iv_mjahr } item { iv_zeile }: zero quantity – not transferred|.
    PERFORM finish USING ls_log.
    RETURN.
  ENDIF.

*--------------------------------------------------------------------*
* 3b) Authorisation – explicit check before any posting
*     M_MSEG_WMB (plant) for both plants, M_MSEG_BWA (movement type)
*--------------------------------------------------------------------*
  DATA(lv_bwart_chk) = COND bwart( WHEN iv_reversal = abap_true THEN '302'
                                   ELSE lv_movetype ).
  DATA lv_auth_ok TYPE abap_bool VALUE abap_true.
  AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'
    ID 'ACTVT' FIELD '01' ID 'WERKS' FIELD ls_ctrl-werks_fr.
  IF sy-subrc <> 0. lv_auth_ok = abap_false. ENDIF.
  AUTHORITY-CHECK OBJECT 'M_MSEG_WMB'
    ID 'ACTVT' FIELD '01' ID 'WERKS' FIELD ls_ctrl-werks_to.
  IF sy-subrc <> 0. lv_auth_ok = abap_false. ENDIF.
  AUTHORITY-CHECK OBJECT 'M_MSEG_BWA'
    ID 'ACTVT' FIELD '01' ID 'BWART' FIELD lv_bwart_chk.
  IF sy-subrc <> 0. lv_auth_ok = abap_false. ENDIF.
  IF lv_auth_ok = abap_false.
    ls_log-status  = 'E'.
    MESSAGE e027(zmm301) WITH iv_mblnr iv_mjahr iv_zeile ls_ctrl-werks_to
            INTO ls_log-message.
    PERFORM finish USING ls_log.
    RETURN.
  ENDIF.

*--------------------------------------------------------------------*
* 4) Reversal path – cancel the original 301 material document (-> 302)
*--------------------------------------------------------------------*
  IF iv_reversal = abap_true.
    " the 102 line references the original GR via SMBLN / SJAHR / SMBLP
    SELECT SINGLE mov_mblnr, mov_mjahr FROM zmm_301_mov_log
      INTO @DATA(ls_orig)
      WHERE src_mblnr = @ls_seg-smbln
        AND src_mjahr = @ls_seg-sjahr
        AND src_zeile = @ls_seg-smblp
        AND mov_mblnr <> @space
        AND status    <> 'R'.
    IF sy-subrc <> 0 OR ls_orig-mov_mblnr IS INITIAL.
      ls_log-status  = 'W'.
      ls_log-message = |Reversal: no original 301 found for GR { ls_seg-smbln }/{ ls_seg-sjahr }/{ ls_seg-smblp }|.
      PERFORM finish USING ls_log.
      RETURN.
    ENDIF.

    DATA lt_ret_c TYPE STANDARD TABLE OF bapiret2.
    CALL FUNCTION 'BAPI_GOODSMVT_CANCEL'
      EXPORTING
        materialdocument = ls_orig-mov_mblnr
        matdocumentyear  = ls_orig-mov_mjahr
      TABLES
        return           = lt_ret_c.
    IF line_exists( lt_ret_c[ type = 'E' ] ) OR line_exists( lt_ret_c[ type = 'A' ] ).
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      ls_log-status  = 'E'.
      ls_log-message = VALUE #( lt_ret_c[ type = 'E' ]-message OPTIONAL ).
    ELSE.
      CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X'.
      ls_log-status  = 'R'.
      ls_log-message = |302 reversal of doc { ls_orig-mov_mblnr } posted|.
      " mark the original 301 entry as reversed
      UPDATE zmm_301_mov_log SET status = 'R'
        WHERE src_mblnr = @ls_seg-smbln
          AND src_mjahr = @ls_seg-sjahr
          AND src_zeile = @ls_seg-smblp.
    ENDIF.
    PERFORM finish USING ls_log.
    RETURN.
  ENDIF.

*--------------------------------------------------------------------*
* 5) Reservation for the order (latest link row + RESB open check)
*--------------------------------------------------------------------*
  DATA lv_resno TYPE rsnum.
  DATA lv_respo TYPE rspos.

  " SELECT SINGLE does not allow ORDER BY -> UP TO 1 ROWS
  SELECT rsnum, rspos FROM zmm_301_resv_log
    WHERE aufnr = @ls_seg-aufnr AND rsnum <> @space
    ORDER BY erdat DESCENDING, erzet DESCENDING
    INTO TABLE @DATA(lt_link) UP TO 1 ROWS.
  IF lt_link IS NOT INITIAL.
    DATA(ls_link) = lt_link[ 1 ].
    SELECT SINGLE bdmng, enmng, matnr, werks, umwrk FROM resb INTO @DATA(ls_resb)
      WHERE rsnum = @ls_link-rsnum AND rspos = @ls_link-rspos.
    IF sy-subrc = 0
       AND ls_resb-bdmng - ls_resb-enmng > 0
       AND ls_resb-matnr = ls_seg-matnr
       AND ls_resb-werks = ls_ctrl-werks_fr
       AND ls_resb-umwrk = ls_ctrl-werks_to.
      lv_resno = ls_link-rsnum.
      lv_respo = ls_link-rspos.
    ENDIF.
  ENDIF.

  IF lv_resno IS INITIAL AND ls_ctrl-no_resv_action = 'S'.
    ls_log-status  = 'W'.
    MESSAGE w023(zmm301) WITH iv_mblnr iv_mjahr iv_zeile ls_seg-aufnr INTO ls_log-message.
    PERFORM finish USING ls_log.
    RETURN.
  ENDIF.

*--------------------------------------------------------------------*
* 6) Destination valuation type = valuation type of the posting-date FY
*    (origin plant is NOT split-valuated -> VAL_TYPE stays blank)
*--------------------------------------------------------------------*
  " company code + fiscal-year variant for the origin plant
  SELECT SINGLE bwkey FROM t001w INTO @DATA(lv_bwkey) WHERE werks = @ls_seg-werks.
  SELECT SINGLE bukrs FROM t001k INTO @DATA(lv_bukrs) WHERE bwkey = @lv_bwkey.

  DATA: lv_gjahr TYPE gjahr, lv_poper TYPE poper.
  CALL FUNCTION 'FI_PERIOD_DETERMINE'
    EXPORTING
      i_budat = ls_kpf-budat
      i_bukrs = lv_bukrs
    IMPORTING
      e_gjahr = lv_gjahr
      e_poper = lv_poper
    EXCEPTIONS
      OTHERS  = 1.
  IF sy-subrc <> 0 OR lv_gjahr IS INITIAL.
    ls_log-status  = 'E'.
    ls_log-message = |Fiscal year could not be determined for posting date { ls_kpf-budat DATE = USER }|.
    PERFORM finish USING ls_log.
    RETURN.
  ENDIF.
  ls_log-gjahr = lv_gjahr.

  " company-specific entry wins over the global (blank BUKRS) entry
  SELECT bwtar FROM zmm_301_valtype
    WHERE ( bukrs = @lv_bukrs OR bukrs = @space )
      AND gjahr  = @lv_gjahr
      AND active = @abap_true
    ORDER BY bukrs DESCENDING
    INTO TABLE @DATA(lt_valtype) UP TO 1 ROWS.
  IF lt_valtype IS INITIAL.
    ls_log-status  = 'E'.
    MESSAGE e022(zmm301) WITH iv_mblnr iv_mjahr iv_zeile lv_gjahr INTO ls_log-message.
    PERFORM finish USING ls_log.
    RETURN.
  ENDIF.
  DATA(lv_valtype) = lt_valtype[ 1 ]-bwtar.
  ls_log-bwtar = lv_valtype.
  ls_log-rsnum = lv_resno.
  ls_log-rspos = lv_respo.

*--------------------------------------------------------------------*
* 7) Post the 301 transfer via BAPI_GOODS_MOVEMENT_CREATE
*--------------------------------------------------------------------*
  DATA: ls_head   TYPE bapi2017_gm_head_01,
        lv_code   TYPE bapi2017_gm_code VALUE '04',   " 04 = transfer posting (MB1B)
        ls_item   TYPE bapi2017_gm_item_create,
        lt_item   TYPE STANDARD TABLE OF bapi2017_gm_item_create,
        lt_ret    TYPE STANDARD TABLE OF bapiret2,
        lv_matdoc TYPE bapi2017_gm_head_ret-mat_doc,
        lv_matyr  TYPE bapi2017_gm_head_ret-doc_year.

  ls_head-pstng_date = ls_kpf-budat.
  ls_head-doc_date   = ls_kpf-bldat.
  ls_head-ref_doc_no = iv_mblnr.
  ls_head-header_txt = |AUTO301 GR { iv_mblnr }|.

  ls_item-material_long = ls_seg-matnr.
  ls_item-plant         = ls_ctrl-werks_fr.
  ls_item-stge_loc      = COND #( WHEN ls_seg-lgort IS NOT INITIAL
                                  THEN ls_seg-lgort ELSE ls_ctrl-lgort_fr ).
  ls_item-move_type     = lv_movetype.               " 301
  ls_item-entry_qnt     = ls_seg-menge.
  ls_item-entry_uom     = ls_seg-meins.
  ls_item-batch         = ls_seg-charg.
  " receiving (destination) side
  ls_item-move_plant    = ls_ctrl-werks_to.
  ls_item-move_stloc    = ls_ctrl-lgort_to.
  ls_item-move_batch    = ls_seg-charg.
  " valuation types: origin blank (not split-valuated); destination = posting-date FY
  CLEAR ls_item-val_type.
  ls_item-val_type_move = lv_valtype.                " *** verify field name in target release (M9) ***
  " reservation reference (consumes ENMNG)
  IF lv_resno IS NOT INITIAL.
    ls_item-reserv_no = lv_resno.
    ls_item-res_item  = lv_respo.
    ls_item-res_type  = 'R'.
  ENDIF.
  APPEND ls_item TO lt_item.

  CALL FUNCTION 'BAPI_GOODS_MOVEMENT_CREATE'
    EXPORTING
      goodsmvt_header  = ls_head
      goodsmvt_code    = lv_code
    IMPORTING
      materialdocument = lv_matdoc
      matdocumentyear  = lv_matyr
    TABLES
      goodsmvt_item    = lt_item
      return           = lt_ret.

  IF line_exists( lt_ret[ type = 'E' ] ) OR line_exists( lt_ret[ type = 'A' ] ).
    CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
    ls_log-status  = 'E'.
    ls_log-message = VALUE #( lt_ret[ type = 'E' ]-message OPTIONAL DEFAULT 'Posting error' ).
  ELSE.
    CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X'.
    ls_log-status    = COND #( WHEN lv_resno IS INITIAL THEN 'W' ELSE 'S' ).
    ls_log-mov_mblnr = lv_matdoc.
    ls_log-mov_mjahr = lv_matyr.
    ls_log-message   = COND #( WHEN lv_resno IS INITIAL
                               THEN |301 doc { lv_matdoc } posted WITHOUT reservation reference (valtype { lv_valtype })|
                               ELSE |301 doc { lv_matdoc } posted (valtype { lv_valtype })| ).
  ENDIF.

  PERFORM finish USING ls_log.

ENDFUNCTION.

*&---------------------------------------------------------------------*
*& Include LZMM_301_MOVF01 – subroutines of function group ZMM_301_MOV
*&---------------------------------------------------------------------*
*& FINISH : persist the movement-log row, write the application log
*&          (object ZMM / subobject Z301MOV) and commit.
*&
*& NOTE: a 'W' row that carries MOV_MBLNR is a successful posting made
*& without a reservation reference (NO_RESV_ACTION = 'P'). Step 1 and the
*& monitor therefore treat "MOV_MBLNR filled" as transferred, not STATUS.
*&---------------------------------------------------------------------*
FORM finish USING is_log TYPE zmm_301_mov_log.

  DATA: ls_bal    TYPE bal_s_log,
        lv_handle TYPE balloghndl,
        lt_handle TYPE bal_t_logh,
        lv_text   TYPE c LENGTH 200,
        lv_msgty  TYPE symsgty.

  MODIFY zmm_301_mov_log FROM @is_log.

  " application log (best effort – never blocks the log row / the GR)
  ls_bal-object    = 'ZMM'.
  ls_bal-subobject = 'Z301MOV'.
  ls_bal-extnumber = |{ is_log-src_mblnr }/{ is_log-src_mjahr }/{ is_log-src_zeile }|.
  ls_bal-aldate    = sy-datum.
  ls_bal-altime    = sy-uzeit.
  ls_bal-aluser    = sy-uname.
  CALL FUNCTION 'BAL_LOG_CREATE'
    EXPORTING  i_s_log      = ls_bal
    IMPORTING  e_log_handle = lv_handle
    EXCEPTIONS OTHERS       = 1.
  IF sy-subrc = 0.
    lv_msgty = SWITCH #( is_log-status WHEN 'E' THEN 'E'
                                       WHEN 'W' THEN 'W'
                                       ELSE 'S' ).
    lv_text = is_log-message.
    CALL FUNCTION 'BAL_LOG_MSG_ADD_FREE_TEXT'
      EXPORTING  i_log_handle = lv_handle
                 i_msgty      = lv_msgty
                 i_text       = lv_text
      EXCEPTIONS OTHERS       = 1.
    INSERT lv_handle INTO TABLE lt_handle.
    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING  i_t_log_handle = lt_handle
      EXCEPTIONS OTHERS         = 1.
  ENDIF.

  COMMIT WORK.
ENDFORM.
