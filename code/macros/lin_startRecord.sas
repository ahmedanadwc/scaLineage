/**
  @file lin_startRecord.sas
  @brief Starts the SAS Code Analyzer (PROC SCAPROC) recording for the code that follows.
  @details Records into p_outFile with the options the lineage macros need: ATTR (column attributes,
  without them no column lineage can be traced), OPENTIMES (step run times) and EXPANDMACROS. These
  three are always set; p_extraOptions adds more RECORD options. SCAPROC appends to an existing
  file, so the file is deleted first (p_replace_yn=Y). Finish with %lin_stopRecord.

  Based on %util_initScaproc by Ahmed Al-Attar, itself inspired by
  https://support.sas.com/resources/papers/proceedings17/1104-2017.pdf

  Example usage:

      %lin_startRecord(p_outFile=%str(~/scaLineage/logs/my_program.txt))
      ... your program ...
      %lin_stopRecord

  @param [in] p_outFile= Full path of the recording file. Required. Unix and Windows paths both work.
  @param [in] p_extraOptions= Further PROC SCAPROC RECORD options. Default: none.
  @param [in] p_replace_yn= Y deletes an existing recording file first. Default:Y.
  @param [in] p_enableFlagName= Optional. Name of a macro variable; recording starts only when it is
                                set to 1, Y or VERBOSE. Default: none (always record).

  @version 9.4
**/
%MACRO lin_startRecord(p_outFile=
, p_extraOptions=
, p_replace_yn=Y
, p_enableFlagName=) / minoperator;

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
    RECORD "&p_outFile" ATTR OPENTIMES EXPANDMACROS &p_extraOptions;
  RUN;

%MEND lin_startRecord;
