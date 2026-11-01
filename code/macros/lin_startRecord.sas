/**
  @file lin_startrecord.sas
  @brief Starts the SAS Code Analyzer (PROC SCAPROC) recording for the code that follows.
  @details Records into p_outFile with the options the lineage macros need: 
  <ul>
  <li>ATTR (column attributes, without them no column lineage can be traced)</li>
  <li>OPENTIMES (step run times)</li>
  <li>EXPANDMACROS</li>
  </ul>
  These three are always set. The SCAPROC appends to an existing file, so the file is deleted first (p_replace_yn=Y).

  Example usage:

      %lin_startRecord(p_outFile=%str(<Path>/<FileName>.txt)
      , p_replace_yn=Y, p_enableFlagName=g_enableScaProc)


  @param [in] p_outFile= Full path of the recording file. Required. Unix and Windows paths both work.
  @param [in] p_replace_yn= Y deletes an existing recording file first. Default:Y.
  @param [in] p_enableFlagName= Optional. Name of a macro variable; recording starts only when it is
                                set to 1, Y or VERBOSE. Default: g_enableScaProc.

  @version 9.4
  @author Ahmed Al-Attar
**/
%MACRO lin_startRecord(p_outFile=
, p_replace_yn=Y
, p_enableFlagName=g_enableScaProc) / minoperator;

  %LOCAL l_flag;

  %if (%superq(p_enableFlagName) ne ) %then
  %do;
    %if (%symexist(&p_enableFlagName) = 0) %then %return;
    %let l_flag = %upcase(&&&p_enableFlagName);
    %if (NOT (&l_flag IN (1 Y VERBOSE))) %then %return;
  %end;

  %if (%superq(p_outFile) = ) %then
  %do;
    %put ERROR: lin_startRecord: p_outFile is required.;
    %return;
  %end;

  %if (%upcase(&p_replace_yn) = Y) %then
  %do;
    DATA _NULL_;
      rc = FILENAME('lrec', "&p_outFile");
      IF (FEXIST('lrec')) THEN rc = FDELETE('lrec');
      rc = FILENAME('lrec');
    RUN;
  %end;

  PROC SCAPROC;
    RECORD "&p_outFile" ATTR OPENTIMES EXPANDMACROS;
  RUN;

%MEND lin_startRecord;
