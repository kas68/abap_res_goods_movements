CLASS zce_mb_document_badi_301 DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
    " FS-MM-301MOV-001 : Enhancement class for MB_DOCUMENT_BADI. Holds the
    " logic; the BAdI class ZCL_IM_MB_DOC_301_TRANSFER only calls it
    " (development standard: enhancements are encapsulated in a ZCE_ class).
    "
    " Detects a goods receipt (mvt 101) posted against a production order in
    " the configured origin plant for the order header material, and enqueues
    " the follow-on 301 transfer to the destination plant. The transfer itself
    " runs in a SEPARATE LUW after the GR commit (function Z_PTP_301_TRANSFER_POST
    " called IN BACKGROUND TASK) so that a transfer failure can NEVER roll back
    " the goods receipt.
    "
    " Reversals (mvt 102) enqueue the matching 302 reverse transfer.
    "
    " Called from IF_EX_MB_DOCUMENT_BADI~MB_DOCUMENT_BEFORE_UPDATE.

    " Same parameters as IF_EX_MB_DOCUMENT_BADI~MB_DOCUMENT_BEFORE_UPDATE
    METHODS before_update
      IMPORTING it_mkpf TYPE ty_t_mkpf
                it_mseg TYPE ty_t_mseg.

  PRIVATE SECTION.
    CONSTANTS: gc_gr_101  TYPE bwart VALUE '101',
               gc_rev_102 TYPE bwart VALUE '102'.

    " Returns the active control entry for an origin plant, if any.
    METHODS get_control
      IMPORTING iv_werks         TYPE werks_d
      EXPORTING es_ctrl          TYPE zptp_301_ctrl
      RETURNING VALUE(rv_active) TYPE abap_bool.

    " True if the material is the header (finished) material of the order.
    METHODS is_header_material
      IMPORTING iv_aufnr         TYPE aufnr
                iv_matnr         TYPE matnr
      RETURNING VALUE(rv_header) TYPE abap_bool.

ENDCLASS.

CLASS zce_mb_document_badi_301 IMPLEMENTATION.

  METHOD before_update.
    LOOP AT it_mseg ASSIGNING FIELD-SYMBOL(<seg>).

      " only goods receipts / their reversal, against a production order
      IF <seg>-aufnr IS INITIAL.
        CONTINUE.
      ENDIF.
      IF <seg>-bwart <> gc_gr_101 AND <seg>-bwart <> gc_rev_102.
        CONTINUE.
      ENDIF.

      " origin plant must be an active control entry
      DATA ls_ctrl TYPE zptp_301_ctrl.
      IF get_control( EXPORTING iv_werks = <seg>-werks
                      IMPORTING es_ctrl  = ls_ctrl ) = abap_false.
        CONTINUE.
      ENDIF.

      " optional activation window (posting date from the document header)
      READ TABLE it_mkpf INTO DATA(ls_mkpf)
           WITH KEY mblnr = <seg>-mblnr mjahr = <seg>-mjahr.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      IF ( ls_ctrl-valid_from IS NOT INITIAL AND ls_mkpf-budat < ls_ctrl-valid_from )
      OR ( ls_ctrl-valid_to   IS NOT INITIAL AND ls_mkpf-budat > ls_ctrl-valid_to ).
        CONTINUE.
      ENDIF.

      " header material only (skip components / co-products)
      IF is_header_material( iv_aufnr = <seg>-aufnr
                             iv_matnr = <seg>-matnr ) = abap_false.
        CONTINUE.
      ENDIF.

      DATA(lv_reversal) = xsdbool( <seg>-bwart = gc_rev_102 ).

      " Enqueue the transfer in a separate LUW. IN BACKGROUND TASK registers a
      " tRFC unit executed after the GR's COMMIT WORK. For strict serialisation
      " a bgRFC queue keyed by MATNR/WERKS is recommended (FS Open Issue M1/M8).
      CALL FUNCTION 'Z_PTP_301_TRANSFER_POST'
        IN BACKGROUND TASK
        EXPORTING
          iv_mblnr    = ls_mkpf-mblnr
          iv_mjahr    = ls_mkpf-mjahr
          iv_zeile    = <seg>-zeile
          iv_reversal = lv_reversal.

    ENDLOOP.
  ENDMETHOD.

  METHOD get_control.
    CLEAR es_ctrl.
    SELECT SINGLE * FROM zptp_301_ctrl INTO @es_ctrl
      WHERE werks_fr = @iv_werks
        AND active   = @abap_true.
    rv_active = xsdbool( sy-subrc = 0 ).
  ENDMETHOD.

  METHOD is_header_material.
    " header material = AFPO-MATNR of the order's finished item(s)
    SELECT SINGLE matnr FROM afpo INTO @DATA(lv_matnr)
      WHERE aufnr = @iv_aufnr
        AND matnr = @iv_matnr.
    rv_header = xsdbool( sy-subrc = 0 ).
  ENDMETHOD.

ENDCLASS.
