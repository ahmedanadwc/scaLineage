/**
  @file lin_stoprecord.sas
  @brief Writes out the collected information to the record file.
  @details Writes out the collected information to the record file, and terminate the SAS Code Analyzer.

  Example usage:
  
      %lin_stopRecord(p_enableFlagName=g_enableScaProc)

  @param [in] p_enableFlagName= Optional. Same flag as for %lin_startRecord: nothing happens unless
                                it is set to 1, Y or VERBOSE. Default: g_enableScaProc.

  @version 9.4
  @author Ahmed Al-Attar
**/
%macro lin_stopRecord(p_enableFlagName=g_enableScaProc) / minoperator;

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

%mend lin_stopRecord;
