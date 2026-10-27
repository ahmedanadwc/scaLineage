/**
  @file lin_stopRecord.sas
  @brief Writes the collected SAS Code Analyzer information to the recording file and stops recording.
  @details Counterpart of %lin_startRecord.

  Based on %util_termScaproc by Ahmed Al-Attar.

  @param [in] p_enableFlagName= Optional. Same flag as for %lin_startRecord: nothing happens unless
                                it is set to 1, Y or VERBOSE. Default: none (always write).

  @version 9.4
**/
%MACRO lin_stopRecord(p_enableFlagName=) / minoperator;

  %LOCAL l_flag;

  %if (%superq(p_enableFlagName) ne ) %then
  %do;
    %if (%symexist(&p_enableFlagName) = 0) %then %return;
    %let l_flag = %upcase(&&&p_enableFlagName);
    %if (NOT (&l_flag IN (1 Y VERBOSE))) %then %return;
  %end;

  PROC SCAPROC;
    WRITE;
  RUN;

%MEND lin_stopRecord;
