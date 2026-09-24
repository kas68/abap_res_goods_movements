*&---------------------------------------------------------------------*
*& Class  ZCL_MM_301_GR_TRIGGER
*&---------------------------------------------------------------------*
*& E-xxx-SEG (FS-MM-301MOV-001) : BAdI implementation of MB_DOCUMENT_BADI.
*&
*& Detects a goods receipt (mvt 101) posted against a production order in
*& the configured origin plant for the order header material, and registers
*& the follow-on 301 transfer to the destination plant. The transfer itself
*& runs in a SEPARATE LUW after the GR commit (function Z_MM_301_POST_TRANSFER
*& called IN BACKGROUND TASK) so that a transfer failure can NEVER roll back
*& the goods receipt.
*&
*& Reversals (mvt 102) register the matching 302 reverse transfer.
*&
*& Implementation of BAdI: MB_DOCUMENT_BADI (classic BAdI).
*&   Interface : IF_EX_MB_DOCUMENT_BADI
*&   Method    : MB_DOCUMENT_BEFORE_UPDATE
*&
*& Execution context: MB_DOCUMENT_BEFORE_UPDATE is called by the posting
*& program in the posting (dialog/BAPI) LUW, immediately BEFORE the update
*& task is triggered - it does NOT run in the update task (that is the
*& sibling method MB_DOCUMENT_UPDATE). The document numbers are already
*& assigned. A CALL FUNCTION ... IN BACKGROUND TASK registered here is
*& therefore executed only when the GR's COMMIT WORK succeeds, as its own
*& tRFC LUW, and is discarded if the GR is rolled back.
*& *** verify in target release (SE18: MB_DOCUMENT_BADI) - FS open item M1 ***
*&---------------------------------------------------------------------*
CLASS zcl_mm_301_gr_trigger DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_ex_mb_document_badi.

  PRIVATE SECTION.
    CONSTANTS: gc_gr_101  TYPE bwart VALUE '101',
               gc_rev_102 TYPE bwart VALUE '102'.

    " Returns the active control entry for an origin plant, if any.
    " ZMM_301_CTRL is fully buffered -> no DB round trip in normal operation.
    METHODS get_control
      IMPORTING iv_werks         TYPE werks_d
      EXPORTING es_ctrl          TYPE zmm_301_ctrl
      RETURNING VALUE(rv_active) TYPE abap_bool.

    " True if the material is the header (finished) material of the order.
    METHODS is_header_material
      IMPORTING iv_aufnr         TYPE aufnr
                iv_matnr         TYPE matnr
      RETURNING VALUE(rv_header) TYPE abap_bool.

ENDCLASS.

*---------------------------------------------------------------------*
CLASS zcl_mm_301_gr_trigger IMPLEMENTATION.

  METHOD if_ex_mb_document_badi~mb_document_before_update.
    " Importing (from interface): XMKPF (MKPF lines), XMSEG (MSEG lines).
    " Only classification + registration here: no DB write, no posting.
    DATA ls_ctrl TYPE zmm_301_ctrl.

    LOOP AT xmkpf ASSIGNING FIELD-SYMBOL(<kpf>).
      LOOP AT xmseg ASSIGNING FIELD-SYMBOL(<seg>)
           WHERE mblnr = <kpf>-mblnr AND mjahr = <kpf>-mjahr.

        " only goods receipts / their reversal, against a production order
        IF <seg>-aufnr IS INITIAL.
          CONTINUE.
        ENDIF.
        IF <seg>-bwart <> gc_gr_101 AND <seg>-bwart <> gc_rev_102.
          CONTINUE.
        ENDIF.

        " origin plant must be an active control entry
        IF get_control( EXPORTING iv_werks = <seg>-werks
                        IMPORTING es_ctrl  = ls_ctrl ) = abap_false.
          CONTINUE.
        ENDIF.

        " optional activation window (GR posting date)
        IF ( ls_ctrl-valid_from IS NOT INITIAL AND <kpf>-budat < ls_ctrl-valid_from )
        OR ( ls_ctrl-valid_to   IS NOT INITIAL AND <kpf>-budat > ls_ctrl-valid_to ).
          CONTINUE.
        ENDIF.

        " header material only (skip components / co-products)
        IF is_header_material( iv_aufnr = <seg>-aufnr
                               iv_matnr = <seg>-matnr ) = abap_false.
          CONTINUE.
        ENDIF.

        DATA(lv_reversal) = xsdbool( <seg>-bwart = gc_rev_102 ).

        " Register the transfer as a tRFC unit: executed after the GR's
        " COMMIT WORK, in its own LUW. For strict serialisation a bgRFC
        " inbound queue keyed by MATNR/WERKS is recommended (FS M1/M8).
        CALL FUNCTION 'Z_MM_301_POST_TRANSFER'
          IN BACKGROUND TASK
          EXPORTING
            iv_mblnr    = <seg>-mblnr
            iv_mjahr    = <seg>-mjahr
            iv_zeile    = <seg>-zeile
            iv_reversal = lv_reversal.

      ENDLOOP.
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD if_ex_mb_document_badi~mb_document_update.
    " Not used - runs in the update task; nothing to do here.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD get_control.
    CLEAR es_ctrl.
    SELECT SINGLE * FROM zmm_301_ctrl INTO @es_ctrl
      WHERE werks_fr = @iv_werks
        AND active   = @abap_true.
    rv_active = xsdbool( sy-subrc = 0 ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD is_header_material.
    " header material = AFPO-MATNR of the order's finished item(s)
    SELECT SINGLE matnr FROM afpo INTO @DATA(lv_matnr)
      WHERE aufnr = @iv_aufnr
        AND matnr = @iv_matnr.
    rv_header = xsdbool( sy-subrc = 0 ).
  ENDMETHOD.

ENDCLASS.
