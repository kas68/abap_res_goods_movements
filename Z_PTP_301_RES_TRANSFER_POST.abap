*&---------------------------------------------------------------------*
*& Function module  Z_PTP_301_RES_TRANSFER_POST
*&---------------------------------------------------------------------*
*& Post ONE 301 transfer posting against ONE reservation item, for a
*& user-chosen quantity. Called synchronously by the transfer report
*& ZPTP_301_RESERVATION_TRANSFER (one call = one LUW = one commit).
*&
*& The user selects the reservation item in the report and decides the
*& quantity.
*&
*& Processing type : Normal function module (function group ZPTP_301_TRANSFER)
*&
*& IMPORT parameters:
*&   IV_RSNUM   TYPE rsnum     Reservation number
*&   IV_RSPOS   TYPE rspos     Reservation item
*&   IV_MENGE   TYPE menge_d   Quantity to transfer (base UoM of the item)
*&   IV_CHARG   TYPE charg_d   Batch (optional; falls back to RESB-CHARG)
*&   IV_BUDAT   TYPE budat     Posting date
*&   IV_RUN_ID  TYPE sysuuid_c32 (optional) run id for the log
*&   IV_CLOSE   TYPE abap_bool  (optional) X = final issue: the reservation item is
*&                             closed with this posting even if quantity is still open
*& EXPORT parameters:
*&   EV_STATUS  TYPE char1     S = posted / E = error
*&   EV_MESSAGE TYPE string
*&   EV_MBLNR   TYPE mblnr     Material document
*&   EV_MJAHR   TYPE mjahr
*&---------------------------------------------------------------------*
FUNCTION z_ptp_301_res_transfer_post.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_RSNUM) TYPE RSNUM
*"     VALUE(IV_RSPOS) TYPE RSPOS
*"     VALUE(IV_MENGE) TYPE MENGE_D
*"     VALUE(IV_CHARG) TYPE CHARG_D OPTIONAL
*"     VALUE(IV_BUDAT) TYPE BUDAT DEFAULT SY-DATUM
*"     VALUE(IV_RUN_ID) TYPE SYSUUID_C32 OPTIONAL
*"     VALUE(IV_CLOSE) TYPE ABAP_BOOL OPTIONAL
*"  EXPORTING
*"     VALUE(EV_STATUS) TYPE CHAR1
*"     VALUE(EV_MESSAGE) TYPE STRING
*"     VALUE(EV_MBLNR) TYPE MBLNR
*"     VALUE(EV_MJAHR) TYPE MJAHR
*"----------------------------------------------------------------------

  DATA ls_log TYPE zptp_301_trf_log.

  " Every exit goes through here: set EV_STATUS / EV_MESSAGE first, then log + leave.
  DEFINE _finish.
    ls_log-status  = ev_status.
    ls_log-message = ev_message.
    ls_log-erdat   = sy-datum.
    ls_log-erzet   = sy-uzeit.
    ls_log-ernam   = sy-uname.
    ls_log-run_id  = iv_run_id.
    MODIFY zptp_301_trf_log FROM @ls_log.
    COMMIT WORK.
    RETURN.
  END-OF-DEFINITION.

  CLEAR: ev_status, ev_message, ev_mblnr, ev_mjahr.

*--------------------------------------------------------------------*
* 1) Reservation item must still be open
*--------------------------------------------------------------------*
  SELECT SINGLE matnr, werks, lgort, umwrk, umlgo, bwart, bdmng, enmng,
                meins, wempf, charg, xloek, kzear
    FROM resb INTO @DATA(ls_resb)
    WHERE rsnum = @iv_rsnum AND rspos = @iv_rspos.
  IF sy-subrc <> 0.
    ev_status  = 'E'.
    ev_message = |Reservation { iv_rsnum }/{ iv_rspos } not found|.
    RETURN.
  ENDIF.

  ls_log = VALUE #( rsnum    = iv_rsnum
                    rspos    = iv_rspos
                    aufnr    = ls_resb-wempf
                    matnr    = ls_resb-matnr
                    werks_fr = ls_resb-werks
                    werks_to = ls_resb-umwrk
                    menge    = iv_menge
                    meins    = ls_resb-meins ).

  IF ls_resb-xloek = abap_true OR ls_resb-kzear = abap_true.
    ev_status = 'E'. ev_message = |Reservation item is deleted or final-issued|. _finish.
  ENDIF.
  IF iv_menge <= 0.
    ev_status = 'E'. ev_message = |Quantity must be greater than zero|. _finish.
  ENDIF.
  IF iv_menge > ls_resb-bdmng - ls_resb-enmng.
    ev_status = 'E'. ev_message = |Quantity { iv_menge } exceeds the open reservation quantity { ls_resb-bdmng - ls_resb-enmng }|. _finish.
  ENDIF.

*--------------------------------------------------------------------*
* 2) Batch handling (source plant)
*--------------------------------------------------------------------*
  DATA(lv_charg) = COND charg_d( WHEN iv_charg IS NOT INITIAL THEN iv_charg ELSE ls_resb-charg ).
  ls_log-charg = lv_charg.

  SELECT SINGLE xchpf FROM marc INTO @DATA(lv_xchpf_src)
    WHERE matnr = @ls_resb-matnr AND werks = @ls_resb-werks.
  IF lv_xchpf_src = abap_true AND lv_charg IS INITIAL.
    ev_status = 'E'. ev_message = |Material { ls_resb-matnr } is batch-managed: enter a batch|. _finish.
  ENDIF.

*--------------------------------------------------------------------*
* 3) Available unrestricted-use stock in the source (re-checked at
*    posting time: stock may have moved since the report was read)
*--------------------------------------------------------------------*
  DATA: lv_avail TYPE menge_d,
        lr_lgort TYPE RANGE OF lgort_d.
  IF ls_resb-lgort IS NOT INITIAL.                    " blank storage location = whole plant
    lr_lgort = VALUE #( ( sign = 'I' option = 'EQ' low = ls_resb-lgort ) ).
  ENDIF.
  IF lv_charg IS NOT INITIAL.
    SELECT SUM( clabs ) FROM mchb
      WHERE matnr = @ls_resb-matnr AND werks = @ls_resb-werks
        AND charg = @lv_charg
        AND lgort IN @lr_lgort
      INTO @lv_avail.
  ELSE.
    SELECT SUM( labst ) FROM mard
      WHERE matnr = @ls_resb-matnr AND werks = @ls_resb-werks
        AND lgort IN @lr_lgort
      INTO @lv_avail.
  ENDIF.
  IF iv_menge > lv_avail.
    ev_status = 'E'. ev_message = |Quantity { iv_menge } exceeds unrestricted stock { lv_avail } in { ls_resb-werks }|. _finish.
  ENDIF.

*--------------------------------------------------------------------*
* 4) Destination valuation type
*    Forward direction (control entry werks_fr -> werks_to exists):
*      destination valuation type from ZPTP_301_VALTYPE, key = destination plant
*      + material type + fiscal year of the posting date (blank WERKS / MTART =
*      all; the most specific entry wins).
*    Reverse direction (e.g. raw materials 8Q01 -> 8P01): no mapping;
*      the source valuation type is read from the source batch (MCHA-BWTAR).
*--------------------------------------------------------------------*
  DATA: lv_valtype TYPE bwtar_d,
        lv_srcval  TYPE bwtar_d.

  SELECT SINGLE @abap_true FROM zptp_301_ctrl INTO @DATA(lv_forward)
    WHERE werks_fr = @ls_resb-werks
      AND werks_to = @ls_resb-umwrk
      AND active   = @abap_true.

  IF lv_forward = abap_true.
    SELECT SINGLE bwkey FROM t001w INTO @DATA(lv_bwkey) WHERE werks = @ls_resb-werks.
    SELECT SINGLE bukrs FROM t001k INTO @DATA(lv_bukrs) WHERE bwkey = @lv_bwkey.

    DATA: lv_gjahr TYPE gjahr, lv_poper TYPE poper.
    CALL FUNCTION 'FI_PERIOD_DETERMINE'
      EXPORTING
        i_budat = iv_budat
        i_bukrs = lv_bukrs
      IMPORTING
        e_gjahr = lv_gjahr
        e_poper = lv_poper
      EXCEPTIONS
        OTHERS  = 1.
    IF sy-subrc <> 0 OR lv_gjahr IS INITIAL.
      ev_status = 'E'. ev_message = |Could not determine fiscal year for posting date { iv_budat }|. _finish.
    ENDIF.

    " material type of the transferred material
    SELECT SINGLE mtart FROM mara INTO @DATA(lv_mtart) WHERE matnr = @ls_resb-matnr.

    " Most specific entry wins: destination-plant-specific over all plants
    " (blank WERKS), then material-type-specific over all types (blank MTART).
    SELECT bwtar FROM zptp_301_valtype
      WHERE ( werks = @ls_resb-umwrk OR werks = @space )
        AND ( mtart = @lv_mtart OR mtart = @space )
        AND gjahr  = @lv_gjahr
        AND active = @abap_true
      ORDER BY werks DESCENDING, mtart DESCENDING
      INTO @lv_valtype
      UP TO 1 ROWS.
    ENDSELECT.
    IF sy-subrc <> 0 OR lv_valtype IS INITIAL.
      ev_status = 'E'. ev_message = |No valuation type mapped for fiscal year { lv_gjahr }, plant { ls_resb-umwrk }, material type { lv_mtart }|. _finish.
    ENDIF.
  ELSE.
    " RESB carries no valuation type: take it from the source batch (MCHA-BWTAR)
    IF lv_charg IS NOT INITIAL.
      SELECT SINGLE bwtar FROM mcha INTO @lv_srcval
        WHERE matnr = @ls_resb-matnr
          AND werks = @ls_resb-werks
          AND charg = @lv_charg.
    ENDIF.
  ENDIF.
  ls_log-bwtar = lv_valtype.

*--------------------------------------------------------------------*
* 5) Batch must exist in the destination plant (create from source batch)
*--------------------------------------------------------------------*
  DATA lv_batch_note TYPE string.
  FIELD-SYMBOLS <lv_batch_bwtar> TYPE data.

  IF lv_charg IS NOT INITIAL.
    SELECT SINGLE @abap_true FROM mcha INTO @DATA(lv_batch_found)
      WHERE matnr = @ls_resb-matnr
        AND werks = @ls_resb-umwrk
        AND charg = @lv_charg.
    IF sy-subrc <> 0.
      SELECT SINGLE xchpf FROM marc INTO @DATA(lv_xchpf_dst)
        WHERE matnr = @ls_resb-matnr AND werks = @ls_resb-umwrk.
      IF sy-subrc <> 0 OR lv_xchpf_dst IS INITIAL.
        ev_status = 'E'. ev_message = |Material not batch-managed in plant { ls_resb-umwrk } - batch { lv_charg } cannot be created|. _finish.
      ENDIF.

      DATA: ls_batatt     TYPE bapibatchatt,
            ls_batatt_new TYPE bapibatchatt,
            lt_ret_b      TYPE STANDARD TABLE OF bapiret2,
            lt_ret_b2     TYPE STANDARD TABLE OF bapiret2,
            lv_batch_new  TYPE charg_d.

      CALL FUNCTION 'BAPI_BATCH_GET_DETAIL'
        EXPORTING
          material_long   = ls_resb-matnr
          batch           = lv_charg
          plant           = ls_resb-werks
        IMPORTING
          batchattributes = ls_batatt
        TABLES
          return          = lt_ret_b.
      IF line_exists( lt_ret_b[ type = 'E' ] ) OR line_exists( lt_ret_b[ type = 'A' ] ).
        ev_status = 'E'. ev_message = |Source batch { lv_charg } read error: { VALUE #( lt_ret_b[ type = 'E' ]-message DEFAULT `unknown` ) }|. _finish.
      ENDIF.

      " copy source attributes, then add the destination valuation type
      ls_batatt_new = ls_batatt.
      IF lv_valtype IS NOT INITIAL.
        ASSIGN COMPONENT 'VAL_TYPE' OF STRUCTURE ls_batatt_new TO <lv_batch_bwtar>.
        IF sy-subrc <> 0.
          ASSIGN COMPONENT 'BWTAR' OF STRUCTURE ls_batatt_new TO <lv_batch_bwtar>.
        ENDIF.
        IF <lv_batch_bwtar> IS ASSIGNED.
          <lv_batch_bwtar> = lv_valtype.
        ELSE.
          lv_batch_note = | (batch valuation type not set by BAPI_BATCH_CREATE)|.
        ENDIF.
      ENDIF.

      CALL FUNCTION 'BAPI_BATCH_CREATE'
        EXPORTING
          material_long   = ls_resb-matnr
          batch           = lv_charg
          plant           = ls_resb-umwrk
          batchattributes = ls_batatt_new
        IMPORTING
          batch           = lv_batch_new
        TABLES
          return          = lt_ret_b2.
      IF line_exists( lt_ret_b2[ type = 'E' ] ) OR line_exists( lt_ret_b2[ type = 'A' ] ).
        CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
        ev_status = 'E'. ev_message = |Batch { lv_charg } create error in plant { ls_resb-umwrk }: { VALUE #( lt_ret_b2[ type = 'E' ]-message DEFAULT `unknown` ) }|. _finish.
      ENDIF.
      " no COMMIT here: the batch is created in the same LUW as the 301 posting
    ENDIF.
  ENDIF.

*--------------------------------------------------------------------*
* 6) Post the transfer against the reservation item
*--------------------------------------------------------------------*
  DATA: ls_head   TYPE bapi2017_gm_head_01,
        ls_code   TYPE bapi2017_gm_code,
        ls_item   TYPE bapi2017_gm_item_create,
        lt_item   TYPE STANDARD TABLE OF bapi2017_gm_item_create,
        lt_ret    TYPE STANDARD TABLE OF bapiret2,
        lv_matdoc TYPE bapi2017_gm_head_ret-mat_doc,
        lv_matyr  TYPE bapi2017_gm_head_ret-doc_year.

  ls_head-pstng_date = iv_budat.
  ls_head-doc_date   = iv_budat.
  ls_head-ref_doc_no = |{ iv_rsnum }/{ iv_rspos }|.
  ls_head-header_txt = |RES301 { ls_resb-wempf }|.
  ls_code-gm_code    = '04'.                         " 04 = transfer posting

  ls_item-material_long = ls_resb-matnr.             " S/4: 40-char MATNR
  ls_item-plant         = ls_resb-werks.
  ls_item-stge_loc      = ls_resb-lgort.
  ls_item-move_type     = ls_resb-bwart.             " 301
  ls_item-entry_qnt     = iv_menge.
  ls_item-entry_uom     = ls_resb-meins.
  ls_item-batch         = lv_charg.
  ls_item-val_type      = lv_srcval.                 " blank in the forward direction
  ls_item-move_plant    = ls_resb-umwrk.
  ls_item-move_stloc    = ls_resb-umlgo.
  ls_item-move_batch    = lv_charg.
  ls_item-move_val_type = lv_valtype.
  ls_item-reserv_no     = iv_rsnum.                  " reservation reference (consumes ENMNG)
  ls_item-res_item      = iv_rspos.
  " RES_TYPE stays blank: the reservation items have RESB-RSART blank (manual reservation, BDART MR)
  IF iv_close = abap_true.
    ls_item-withdrawn = abap_true.                 " final issue (RESB-KZEAR): closes the item
  ENDIF.
  APPEND ls_item TO lt_item.

  CALL FUNCTION 'BAPI_GOODSMVT_CREATE'
    EXPORTING
      goodsmvt_header  = ls_head
      goodsmvt_code    = ls_code
    IMPORTING
      materialdocument = lv_matdoc
      matdocumentyear  = lv_matyr
    TABLES
      goodsmvt_item    = lt_item
      return           = lt_ret.

  IF line_exists( lt_ret[ type = 'E' ] ) OR line_exists( lt_ret[ type = 'A' ] ).
    CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
    " first error message with its message class / number (for the analysis in SE91)
    DATA(ls_err) = VALUE bapiret2( lt_ret[ type = 'E' ] OPTIONAL ).
    IF ls_err IS INITIAL.
      ls_err = VALUE bapiret2( lt_ret[ type = 'A' ] OPTIONAL ).
    ENDIF.
    ev_status  = 'E'.
    ev_message = COND #( WHEN ls_err IS INITIAL THEN `Posting error`
                         ELSE |{ ls_err-message } ({ ls_err-id } { ls_err-number })| ).
    _finish.
  ENDIF.

  CALL FUNCTION 'BAPI_TRANSACTION_COMMIT' EXPORTING wait = 'X'.
  ev_mblnr         = lv_matdoc.
  ev_mjahr         = lv_matyr.
  ls_log-mov_mblnr = lv_matdoc.
  ls_log-mov_mjahr = lv_matyr.
  ev_status = 'S'. ev_message = |301 doc { lv_matdoc } posted, qty { iv_menge } { ls_resb-meins }{ lv_batch_note }|
                          && COND string( WHEN iv_close = abap_true THEN ', reservation closed (final issue)' ).
  _finish.

ENDFUNCTION.
