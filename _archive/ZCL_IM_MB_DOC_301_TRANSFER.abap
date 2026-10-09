CLASS zcl_im_mb_doc_301_transfer DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
    " FS-MM-301MOV-001 : BAdI implementation ZMB_DOC_301_TRANSFER of
    " MB_DOCUMENT_BADI (classic BAdI, SE19).
    "
    " Only calls the enhancement class ZCE_MB_DOCUMENT_BADI_301, which holds
    " the GR-triggered 301 logic (development standard).
    "
    "   Interface : IF_EX_MB_DOCUMENT_BADI
    "   Methods   : MB_DOCUMENT_BEFORE_UPDATE -> ZCE_MB_DOCUMENT_BADI_301
    "               MB_DOCUMENT_UPDATE        -> not used

    INTERFACES if_ex_mb_document_badi.

ENDCLASS.

CLASS zcl_im_mb_doc_301_transfer IMPLEMENTATION.

  METHOD if_ex_mb_document_badi~mb_document_before_update.
    NEW zce_mb_document_badi_301( )->before_update( it_mkpf = xmkpf
                                                    it_mseg = xmseg ).
  ENDMETHOD.

  METHOD if_ex_mb_document_badi~mb_document_update.
    " not used
  ENDMETHOD.

ENDCLASS.
