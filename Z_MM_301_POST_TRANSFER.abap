*&---------------------------------------------------------------------*
*& Function module  Z_MM_301_POST_TRANSFER
*&---------------------------------------------------------------------*
*& FS-MM-301MOV-001 : Post (or reverse) the 301 transfer for one goods
*& receipt item, in its own LUW. Called IN BACKGROUND TASK from the
*& MB_DOCUMENT_BADI implementation (ZCL_MM_301_GR_TRIGGER), and also by the
*& monitor/repost report (ZMM_R_301_MOV_MONITOR).
*&
*& Processing type : Remote-Enabled Module (required for IN BACKGROUND TASK)
*&
*& IMPORT parameters:
*&   IV_MBLNR    TYPE mblnr     Source GR material document
*&   IV_MJAHR    TYPE mjahr     Source GR document year
*&   IV_ZEILE    TYPE mblpo     Source GR item
*&   IV_REVERSAL TYPE abap_bool 'X' = GR was reversed (cancel the 301)
*&   IV_RUN_ID   TYPE sysuuid_c32  (optional) repost/catch-up run id
*&   IV_COMMIT   TYPE abap_bool  'X' = synchronous caller (monitor) -> this FM
*&                 commits itself. SPACE = called IN BACKGROUND TASK (tRFC):
*&                 the tRFC framework owns COMMIT WORK, so this FM must NOT
*&                 issue COMMIT WORK / ROLLBACK WORK itself.
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
*"     VALUE(IV_COMMIT) TYPE ABAP_BOOL DEFAULT SPACE
*"----------------------------------------------------------------------

  DATA: ls_log TYPE zmm_301_mov_log.

  " Persist the movement log. In the tRFC path (IV_COMMIT = space) the
  " framework issues COMMIT WORK, so we never COMMIT/ROLLBACK here.
  DEFINE _persist_log.
    MODIFY zmm_301_mov_log FROM @ls_log.
    IF iv_commit = abap_true.
      COMMIT WORK.
    ENDIF.
  END-OF-DEFINITION.

*--------------------------------------------------------------------*
* 1) Idempotency – skip if this source item was already transferred OK
*--------------------------------------------------------------------*
  SELECT SINGLE * FROM zmm_301_mov_log INTO @DATA(ls_prev)
    WHERE src_mblnr = @iv_mblnr
      AND src_mjahr = @iv_mjahr
      AND src_zeile = @iv_zeile.
  IF sy-subrc = 0.
    " forward: already transferred; reversal: already reversed -> nothing to do
    IF ( iv_reversal = abap_false AND ls_prev-status = 'S' )
    OR ( iv_reversal = abap_true  AND ls_prev-status = 'R' ).
      RETURN.
    ENDIF.
  ENDIF.

*--------------------------------------------------------------------*
* 2) Re-read the source GR line (persisted by now) + document header
*--------------------------------------------------------------------*
  SELECT SINGLE mblnr, mjahr, zeile, bwart, matnr, werks, lgort,
                charg, menge, meins, aufnr, smbln, smblp, sjahr
    FROM mseg INTO @DATA(ls_seg)
    WHERE mblnr = @iv_mblnr AND mjahr = @iv_mjahr AND zeile = @iv_zeile.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  SELECT SINGLE budat, bldat FROM mkpf INTO @DATA(ls_kpf)
    WHERE mblnr = @iv_mblnr AND mjahr = @iv_mjahr.
  IF sy-subrc <> 0.
    RETURN.                              " no header -> cannot determine period
  ENDIF.

*--------------------------------------------------------------------*
* 3) Control entry for the origin plant
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

*--------------------------------------------------------------------*
* 4) Reversal path – cancel the original 301 material document
*--------------------------------------------------------------------*
  IF iv_reversal = abap_true.
    " the 102 line references the original GR via SMBLN / SMBLP / SJAHR
    SELECT SINGLE mov_mblnr, mov_mjahr FROM zmm_301_mov_log
      INTO @DATA(ls_orig)
      WHERE src_mblnr = @ls_seg-smbln
        AND src_mjahr = @ls_seg-sjahr
        AND src_zeile = @ls_seg-smblp
        AND status    = 'S'.
    IF sy-subrc <> 0 OR ls_orig-mov_mblnr IS INITIAL.
      ls_log-status  = 'W'.
      ls_log-message = |Reversal: no original 301 found for GR { ls_seg-smbln }/{ ls_seg-smblp }|.
      _persist_log.
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
      " Business error: log it and (tRFC path) return normally so the unit is
      " NOT retried. Only the synchronous caller rolls back.
      IF iv_commit = abap_true.
        CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      ENDIF.
      ls_log-status  = 'E'.
      ls_log-message = VALUE #( lt_ret_c[ type = 'E' ]-message OPTIONAL DEFAULT 'Cancel error' ).
    ELSE.
      IF iv_commit = abap_true.
        CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X'.
      ENDIF.
      ls_log-status  = 'R'.
      ls_log-message = |302 reversal of doc { ls_orig-mov_mblnr } posted|.
    ENDIF.
    _persist_log.
    RETURN.
  ENDIF.

*--------------------------------------------------------------------*
* 5) Reservation for the order (link table + open check)
*--------------------------------------------------------------------*
  " IMPORTANT: only the HEADER reservation (RES_KIND = 'H', 8P01->8Q01) is
  " relevant here; raw-material rows ('R', 8Q01->8P01) must be excluded.
  DATA: lv_link_rsnum TYPE rsnum,
        lv_link_rspos TYPE rspos.
  SELECT rsnum, rspos FROM zmm_301_resv_log
    WHERE aufnr = @ls_seg-aufnr AND res_kind = 'H' AND rsnum <> @space
    ORDER BY erdat DESCENDING, erzet DESCENDING
    INTO (@lv_link_rsnum, @lv_link_rspos)
    UP TO 1 ROWS.
  ENDSELECT.

  DATA lv_resno TYPE rsnum.
  DATA lv_respo TYPE rspos.
  IF lv_link_rsnum IS NOT INITIAL.
    SELECT SINGLE bdmng, enmng FROM resb INTO @DATA(ls_resb)
      WHERE rsnum = @lv_link_rsnum AND rspos = @lv_link_rspos.
    IF sy-subrc = 0 AND ls_resb-bdmng - ls_resb-enmng > 0.
      lv_resno = lv_link_rsnum.
      lv_respo = lv_link_rspos.
    ENDIF.
  ENDIF.

  IF lv_resno IS INITIAL AND ls_ctrl-no_resv_action = 'S'.
    ls_log-status  = 'W'.
    ls_log-message = |No open reservation for order { ls_seg-aufnr } – skipped per config|.
    _persist_log.
    RETURN.
  ENDIF.

*--------------------------------------------------------------------*
* 6) Destination valuation type = current-FY valuation type
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
    ls_log-message = |Could not determine fiscal year for posting date { ls_kpf-budat }|.
    _persist_log.
    RETURN.
  ENDIF.

  " company-specific entry wins over the global (blank BUKRS) one
  DATA lv_valtype TYPE bwtar.
  SELECT bwtar FROM zmm_301_valtype
    WHERE ( bukrs = @lv_bukrs OR bukrs = @space )
      AND gjahr  = @lv_gjahr
      AND active = @abap_true
    ORDER BY bukrs DESCENDING
    INTO @lv_valtype
    UP TO 1 ROWS.
  ENDSELECT.
  IF sy-subrc <> 0 OR lv_valtype IS INITIAL.
    ls_log-status  = 'E'.
    ls_log-message = |No valuation type mapped for fiscal year { lv_gjahr }|.
    _persist_log.
    RETURN.
  ENDIF.
  ls_log-bwtar = lv_valtype.
  ls_log-rsnum = lv_resno.
  ls_log-rspos = lv_respo.

*--------------------------------------------------------------------*
* 7) Post the 301 transfer via BAPI_GOODS_MOVEMENT_CREATE
*--------------------------------------------------------------------*
  DATA: ls_head TYPE bapi2017_gm_head_01,
        lv_code TYPE bapi2017_gm_code VALUE '04',   " 04 = transfer posting (MB1B)
        ls_item TYPE bapi2017_gm_item_create,
        lt_item TYPE STANDARD TABLE OF bapi2017_gm_item_create,
        lt_ret  TYPE STANDARD TABLE OF bapiret2,
        lv_matdoc TYPE bapi2017_gm_head_ret-mat_doc,
        lv_matyr  TYPE bapi2017_gm_head_ret-doc_year.

  ls_head-pstng_date = ls_kpf-budat.
  ls_head-doc_date   = ls_kpf-bldat.
  ls_head-ref_doc_no = iv_mblnr.
  ls_head-header_txt = |AUTO301 GR { iv_mblnr }|.

  ls_item-material_long = ls_seg-matnr.
  ls_item-material      = ls_seg-matnr.
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
  " valuation types: origin blank (not split-valuated); destination = current FY
  CLEAR ls_item-val_type.
  ls_item-val_type_move = lv_valtype.                " *** verify field name in target release ***
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
    " Deterministic business error: only the synchronous caller rolls back.
    " In the tRFC path we log and return normally (unit not retried).
    IF iv_commit = abap_true.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
    ENDIF.
    ls_log-status  = 'E'.
    ls_log-message = VALUE #( lt_ret[ type = 'E' ]-message OPTIONAL DEFAULT 'Posting error' ).
  ELSE.
    IF iv_commit = abap_true.
      CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X'.
    ENDIF.
    ls_log-status    = 'S'.
    ls_log-mov_mblnr = lv_matdoc.
    ls_log-mov_mjahr = lv_matyr.
    ls_log-message   = |301 doc { lv_matdoc } posted (valtype { lv_valtype })|.
  ENDIF.

  _persist_log.

ENDFUNCTION.
