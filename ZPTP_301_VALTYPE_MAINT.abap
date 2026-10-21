*&---------------------------------------------------------------------*
*& Report  ZPTP_301_VALTYPE_MAINT   (txn ZPTP_301_VALT)
*&---------------------------------------------------------------------*
*& Maintenance of the destination valuation types ZPTP_301_VALTYPE
*& (destination plant / material type / fiscal year -> valuation type),
*& also in a client where customizing changes are not allowed.
*&
*& Editable ALV:
*&   - existing rows : valuation type, comment and active flag can be changed;
*&                     the key (plant, material type, fiscal year) is locked;
*&   - new rows      : standard ALV functions 'Insert row' / 'Append row';
*&                     all fields are entered;
*&   - deleted rows  : standard ALV function 'Delete row'.
*& SAVE writes all differences against the rows read at the start (created,
*& changed, deleted) after the checks:
*&   - fiscal year filled; plant blank or in T001W; material type blank or in T134;
*&   - valuation type filled and in T149D;
*&   - no duplicate key (in the list or, for new rows, in the table).
*& Rows in error are shown with a red light and the reason; nothing is saved
*& until they are corrected.
*&
*& COPYYEAR copies the selected rows to fiscal year + 1 as new rows of the list
*& (written with SAVE); keys that already exist are skipped.
*&
*& Authorization: S_TABU_DIS, activity 02, with the authorization group of the
*& table (TDDAT). Without it the list is display only. The table is locked
*& (ENQUEUE_E_TABLE) while the list is in change mode.
*&
*& GUI status ZVALTYPE (copy of STANDARD_FULLSCREEN of SAPLKKBL) with the extra
*& functions SAVE and COPYYEAR must exist in this program (SE41).
*&---------------------------------------------------------------------*
REPORT zptp_301_valtype_maint.

TYPE-POOLS: abap, icon.

*---------------------------------------------------------------------*
* Selection screen
*---------------------------------------------------------------------*
DATA: gv_werks TYPE werks_d,
      gv_mtart TYPE mtart,
      gv_gjahr TYPE gjahr.

SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.   " Selection
SELECT-OPTIONS: so_werks FOR gv_werks,                          " destination plant
                so_mtart FOR gv_mtart,                          " material type
                so_gjahr FOR gv_gjahr.                          " fiscal year
SELECTION-SCREEN END OF BLOCK b1.

*---------------------------------------------------------------------*
* Local class : application engine
*---------------------------------------------------------------------*
CLASS lcl_app DEFINITION FINAL.

  PUBLIC SECTION.
    TYPES: BEGIN OF ty_out,
             icon    TYPE c LENGTH 4,
             werks   TYPE werks_d,
             mtart   TYPE mtart,
             gjahr   TYPE gjahr,
             bwtar   TYPE bwtar_d,
             descr   TYPE text40,
             active  TYPE xfeld,
             msg     TYPE string,
             celltab TYPE lvc_t_styl,
           END OF ty_out.
    TYPES tt_out TYPE STANDARD TABLE OF ty_out WITH DEFAULT KEY.

    METHODS run.
    METHODS user_command
      IMPORTING iv_ucomm TYPE sy-ucomm
                it_rows  TYPE lvc_t_row OPTIONAL.     " rows selected in the grid
    METHODS is_editable
      RETURNING VALUE(rv_edit) TYPE abap_bool.

  PRIVATE SECTION.
    DATA: mt_out  TYPE tt_out,
          mt_db   TYPE STANDARD TABLE OF zptp_301_valtype WITH DEFAULT KEY, " rows as read
          mv_edit TYPE abap_bool.

    METHODS check_authority.
    METHODS select_data.
    METHODS lock_key_cells.
    METHODS check_rows
      RETURNING VALUE(rv_ok) TYPE abap_bool.
    METHODS save.
    METHODS copy_next_year
      IMPORTING it_rows TYPE lvc_t_row.
    METHODS display_alv.

ENDCLASS.

DATA go_app TYPE REF TO lcl_app.

*---------------------------------------------------------------------*
CLASS lcl_app IMPLEMENTATION.

  METHOD run.
    check_authority( ).
    select_data( ).
    display_alv( ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD is_editable.
    rv_edit = mv_edit.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD check_authority.
    " change authorization for the authorization group of the table
    SELECT SINGLE cclass FROM tddat INTO @DATA(lv_group)
      WHERE tabname = 'ZPTP_301_VALTYPE'.
    IF lv_group IS INITIAL.
      lv_group = '&NC&'.
    ENDIF.
    AUTHORITY-CHECK OBJECT 'S_TABU_DIS'
      ID 'DICBERCLS' FIELD lv_group
      ID 'ACTVT'     FIELD '02'.
    IF sy-subrc <> 0.
      MESSAGE 'No change authorization: the valuation types are displayed only' TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.

    " one user at a time in change mode
    CALL FUNCTION 'ENQUEUE_E_TABLE'
      EXPORTING
        mode_rstable   = 'E'
        tabname        = 'ZPTP_301_VALTYPE'
      EXCEPTIONS
        foreign_lock   = 1
        system_failure = 2
        OTHERS         = 3.
    IF sy-subrc <> 0.
      MESSAGE |Table locked by user { sy-msgv1 }: the valuation types are displayed only| TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.
    mv_edit = abap_true.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD select_data.
    SELECT * FROM zptp_301_valtype
      WHERE werks IN @so_werks
        AND mtart IN @so_mtart
        AND gjahr IN @so_gjahr
      INTO TABLE @mt_db.
    SORT mt_db BY werks mtart gjahr.

    mt_out = VALUE #( FOR d IN mt_db ( werks  = d-werks
                                       mtart  = d-mtart
                                       gjahr  = d-gjahr
                                       bwtar  = d-bwtar
                                       descr  = d-descr
                                       active = d-active ) ).
    lock_key_cells( ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD lock_key_cells.
    " existing rows: the key cannot be changed (new rows have no style: editable)
    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<o>).
      CLEAR <o>-celltab.
      IF line_exists( mt_db[ werks = <o>-werks mtart = <o>-mtart gjahr = <o>-gjahr ] ).
        INSERT VALUE #( fieldname = 'GJAHR' style = cl_gui_alv_grid=>mc_style_disabled ) INTO TABLE <o>-celltab.
        INSERT VALUE #( fieldname = 'MTART' style = cl_gui_alv_grid=>mc_style_disabled ) INTO TABLE <o>-celltab.
        INSERT VALUE #( fieldname = 'WERKS' style = cl_gui_alv_grid=>mc_style_disabled ) INTO TABLE <o>-celltab.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD user_command.
    CASE iv_ucomm.
      WHEN 'SAVE'.
        IF mv_edit = abap_true.
          save( ).
        ENDIF.
      WHEN 'COPYYEAR'.
        IF mv_edit = abap_true.
          copy_next_year( it_rows ).
        ENDIF.
    ENDCASE.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD copy_next_year.
    " Copies the selected rows to fiscal year + 1 (same plant, material type,
    " valuation type, comment and active flag). The copies are NEW rows of the
    " list: they are written only with SAVE, after the usual checks. A copy is
    " skipped when its key already exists in the list or in the table.
    IF it_rows IS INITIAL.
      MESSAGE 'Select the rows to copy to the next fiscal year' TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.

    DATA: lt_new     TYPE tt_out,
          lv_skipped TYPE i,
          lv_next    TYPE gjahr.
    LOOP AT it_rows INTO DATA(ls_row) WHERE rowtype IS INITIAL.   " data rows only
      READ TABLE mt_out INTO DATA(ls_src) INDEX ls_row-index.
      IF sy-subrc <> 0 OR ls_src-gjahr IS INITIAL.
        CONTINUE.
      ENDIF.
      lv_next = ls_src-gjahr + 1.

      IF line_exists( mt_out[ werks = ls_src-werks mtart = ls_src-mtart gjahr = lv_next ] )
      OR line_exists( lt_new[ werks = ls_src-werks mtart = ls_src-mtart gjahr = lv_next ] ).
        lv_skipped = lv_skipped + 1.
        CONTINUE.
      ENDIF.
      SELECT SINGLE gjahr FROM zptp_301_valtype INTO @DATA(lv_y)
        WHERE werks = @ls_src-werks AND mtart = @ls_src-mtart AND gjahr = @lv_next.
      IF sy-subrc = 0.
        lv_skipped = lv_skipped + 1.
        CONTINUE.
      ENDIF.

      APPEND VALUE #( icon   = icon_led_yellow
                      werks  = ls_src-werks
                      mtart  = ls_src-mtart
                      gjahr  = lv_next
                      bwtar  = ls_src-bwtar
                      descr  = ls_src-descr
                      active = ls_src-active
                      msg    = |Copied from { ls_src-gjahr }, not saved yet| ) TO lt_new.
    ENDLOOP.

    APPEND LINES OF lt_new TO mt_out.
    SORT mt_out BY werks mtart gjahr.
    lock_key_cells( ).                                  " new rows keep editable keys
    MESSAGE |{ lines( lt_new ) } row(s) copied to the next fiscal year, { lv_skipped } skipped (already exist). Check them and press Save| TYPE 'S'.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD check_rows.
    rv_ok = abap_true.
    DATA lt_keys TYPE SORTED TABLE OF string WITH UNIQUE KEY table_line.

    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<o>).
      CLEAR: <o>-icon, <o>-msg.
      DATA(lv_msg) = VALUE string( ).

      IF <o>-gjahr IS INITIAL.
        lv_msg = 'Fiscal year missing'.
      ELSEIF <o>-werks IS NOT INITIAL
         AND NOT line_exists( mt_db[ werks = <o>-werks ] ).
        SELECT SINGLE werks FROM t001w INTO @DATA(lv_w) WHERE werks = @<o>-werks.
        IF sy-subrc <> 0.
          lv_msg = |Plant { <o>-werks } does not exist|.
        ENDIF.
      ENDIF.
      IF lv_msg IS INITIAL AND <o>-mtart IS NOT INITIAL.
        SELECT SINGLE mtart FROM t134 INTO @DATA(lv_m) WHERE mtart = @<o>-mtart.
        IF sy-subrc <> 0.
          lv_msg = |Material type { <o>-mtart } does not exist|.
        ENDIF.
      ENDIF.
      IF lv_msg IS INITIAL.
        IF <o>-bwtar IS INITIAL.
          lv_msg = 'Valuation type missing'.
        ELSE.
          SELECT SINGLE bwtar FROM t149d INTO @DATA(lv_b) WHERE bwtar = @<o>-bwtar.
          IF sy-subrc <> 0.
            lv_msg = |Valuation type { <o>-bwtar } does not exist|.
          ENDIF.
        ENDIF.
      ENDIF.

      " duplicate key in the list
      IF lv_msg IS INITIAL.
        INSERT |{ <o>-werks }/{ <o>-mtart }/{ <o>-gjahr }| INTO TABLE lt_keys.
        IF sy-subrc <> 0.
          lv_msg = 'Same plant / material type / fiscal year entered twice'.
        ENDIF.
      ENDIF.
      " new row whose key already exists in the table (outside the selection)
      IF lv_msg IS INITIAL
         AND NOT line_exists( mt_db[ werks = <o>-werks mtart = <o>-mtart gjahr = <o>-gjahr ] ).
        SELECT SINGLE gjahr FROM zptp_301_valtype INTO @DATA(lv_y)
          WHERE werks = @<o>-werks AND mtart = @<o>-mtart AND gjahr = @<o>-gjahr.
        IF sy-subrc = 0.
          lv_msg = 'This plant / material type / fiscal year already exists in the table'.
        ENDIF.
      ENDIF.

      IF lv_msg IS NOT INITIAL.
        <o>-icon = icon_led_red.
        <o>-msg  = lv_msg.
        rv_ok    = abap_false.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD save.
    IF check_rows( ) = abap_false.
      MESSAGE 'Nothing saved: correct the rows with a red light' TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    " differences against the rows read at the start
    DATA: lt_ins TYPE STANDARD TABLE OF zptp_301_valtype WITH DEFAULT KEY,
          lt_upd TYPE STANDARD TABLE OF zptp_301_valtype WITH DEFAULT KEY,
          lt_del TYPE STANDARD TABLE OF zptp_301_valtype WITH DEFAULT KEY.

    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<o>).
      DATA(ls_new) = VALUE zptp_301_valtype( mandt  = sy-mandt
                                             werks  = <o>-werks
                                             mtart  = <o>-mtart
                                             gjahr  = <o>-gjahr
                                             bwtar  = <o>-bwtar
                                             descr  = <o>-descr
                                             active = <o>-active ).
      READ TABLE mt_db INTO DATA(ls_old)
           WITH KEY werks = <o>-werks mtart = <o>-mtart gjahr = <o>-gjahr.
      IF sy-subrc <> 0.
        APPEND ls_new TO lt_ins.
      ELSEIF ls_old-bwtar <> ls_new-bwtar OR ls_old-descr <> ls_new-descr
          OR ls_old-active <> ls_new-active.
        APPEND ls_new TO lt_upd.
      ENDIF.
    ENDLOOP.
    LOOP AT mt_db INTO DATA(ls_db).
      IF NOT line_exists( mt_out[ werks = ls_db-werks mtart = ls_db-mtart gjahr = ls_db-gjahr ] ).
        APPEND ls_db TO lt_del.
      ENDIF.
    ENDLOOP.

    IF lt_ins IS INITIAL AND lt_upd IS INITIAL AND lt_del IS INITIAL.
      MESSAGE 'No change to save' TYPE 'S'.
      RETURN.
    ENDIF.

    " deletions: confirmation, with a warning for current / future fiscal years
    IF lt_del IS NOT INITIAL.
      DATA lv_year TYPE gjahr.
      lv_year = sy-datum(4).
      DATA(lv_future) = REDUCE i( INIT n = 0 FOR d IN lt_del
                                  WHERE ( gjahr >= lv_year AND active = abap_true ) NEXT n = n + 1 ).
      DATA lv_answer TYPE c LENGTH 1.
      CALL FUNCTION 'POPUP_TO_CONFIRM'
        EXPORTING
          titlebar              = 'Delete valuation types'
          text_question         = COND #( WHEN lv_future > 0
                                          THEN |{ lines( lt_del ) } row(s) will be deleted, { lv_future } active for the current or a future fiscal year: transfers without a valuation type are refused. Continue?|
                                          ELSE |{ lines( lt_del ) } row(s) will be deleted. Continue?| )
          text_button_1         = 'Save'
          text_button_2         = 'Cancel'
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
    ENDIF.

    DELETE zptp_301_valtype FROM TABLE @lt_del.
    INSERT zptp_301_valtype FROM TABLE @lt_ins ACCEPTING DUPLICATE KEYS.
    IF sy-subrc <> 0 AND lt_ins IS NOT INITIAL.
      ROLLBACK WORK.
      MESSAGE 'Save failed: a new row already exists in the table' TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.
    UPDATE zptp_301_valtype FROM TABLE @lt_upd.
    COMMIT WORK.

    MESSAGE |Saved: { lines( lt_ins ) } created, { lines( lt_upd ) } changed, { lines( lt_del ) } deleted| TYPE 'S'.

    " the saved state becomes the new reference
    mt_db = VALUE #( FOR o IN mt_out ( mandt  = sy-mandt
                                       werks  = o-werks
                                       mtart  = o-mtart
                                       gjahr  = o-gjahr
                                       bwtar  = o-bwtar
                                       descr  = o-descr
                                       active = o-active ) ).
    SORT mt_db BY werks mtart gjahr.
    SORT mt_out BY werks mtart gjahr.
    lock_key_cells( ).
  ENDMETHOD.

*---------------------------------------------------------------------*
  METHOD display_alv.
    DATA: lt_fcat   TYPE lvc_t_fcat,
          ls_layout TYPE lvc_s_layo.

    DEFINE _col.
      APPEND VALUE lvc_s_fcat( fieldname = &1 coltext = &2 outputlen = &3
                               ref_table = &4 ref_field = &5 ) TO lt_fcat.
    END-OF-DEFINITION.

    _col 'ICON'   'St.'              4  ''                 ''.
    _col 'WERKS'  'Dest. plant'      6  'ZPTP_301_VALTYPE' 'WERKS'.
    _col 'MTART'  'Material type'    6  'ZPTP_301_VALTYPE' 'MTART'.
    _col 'GJAHR'  'Fiscal year'      6  'ZPTP_301_VALTYPE' 'GJAHR'.
    _col 'BWTAR'  'Valuation type'   10 'ZPTP_301_VALTYPE' 'BWTAR'.
    _col 'DESCR'  'Comment'          40 'ZPTP_301_VALTYPE' 'DESCR'.
    _col 'ACTIVE' 'Active'           6  'ZPTP_301_VALTYPE' 'ACTIVE'.
    _col 'MSG'    'Message'          60 ''                 ''.

    LOOP AT lt_fcat ASSIGNING FIELD-SYMBOL(<f>).
      CASE <f>-fieldname.
        WHEN 'ICON'.
          <f>-icon = abap_true.
        WHEN 'ACTIVE'.
          <f>-checkbox = abap_true.
          <f>-edit     = mv_edit.
        WHEN 'WERKS' OR 'MTART' OR 'GJAHR' OR 'BWTAR' OR 'DESCR'.
          <f>-edit     = mv_edit.                       " key cells of existing rows: locked by style
      ENDCASE.
    ENDLOOP.

    ls_layout-stylefname = 'CELLTAB'.
    ls_layout-sel_mode   = 'A'.                         " row selection (for Copy to next year)
    ls_layout-zebra      = abap_true.
    ls_layout-cwidth_opt = abap_true.

    CALL FUNCTION 'REUSE_ALV_GRID_DISPLAY_LVC'
      EXPORTING
        i_callback_program       = sy-repid
        i_callback_pf_status_set = 'SET_STATUS'
        i_callback_user_command  = 'USER_COMMAND'
        is_layout_lvc            = ls_layout
        it_fieldcat_lvc          = lt_fcat
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
  " display only: no SAVE function
  DATA lt_extab TYPE slis_t_extab.
  lt_extab = pt_extab.
  IF go_app->is_editable( ) = abap_false.
    APPEND VALUE #( fcode = 'SAVE' ) TO lt_extab.
    APPEND VALUE #( fcode = 'COPYYEAR' ) TO lt_extab.
  ENDIF.
  SET PF-STATUS 'ZVALTYPE' EXCLUDING lt_extab.
ENDFORM.

FORM user_command USING pv_ucomm    LIKE sy-ucomm
                        ps_selfield TYPE slis_selfield.
  " take over the values typed in the grid (also inserted / deleted rows)
  DATA lo_grid TYPE REF TO cl_gui_alv_grid.
  CALL FUNCTION 'GET_GLOBALS_FROM_SLVC_FULLSCR'
    IMPORTING
      e_grid = lo_grid.
  DATA lt_rows TYPE lvc_t_row.
  IF lo_grid IS BOUND.
    lo_grid->check_changed_data( ).
    lo_grid->get_selected_rows( IMPORTING et_index_rows = lt_rows ).
  ENDIF.

  go_app->user_command( iv_ucomm = pv_ucomm it_rows = lt_rows ).

  ps_selfield-refresh    = abap_true.
  ps_selfield-col_stable = abap_true.
  ps_selfield-row_stable = abap_true.
ENDFORM.

*---------------------------------------------------------------------*
START-OF-SELECTION.
  go_app = NEW lcl_app( ).
  go_app->run( ).
