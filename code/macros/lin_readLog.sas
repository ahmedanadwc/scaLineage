/**
  @file lin_readLog.sas
  @brief Reads ONE SCAPROC (SAS Code Analyzer) recording into tidy lineage tables.
  @details Every record in the recording starts with the text  /* JOBSPLIT:  . The step number is
  advanced on each TASKSTARTTIME record, so every table below can be joined on STEP.

  Creates (all in WORK, named with the p_prefix):
    &p_prefix._steps   step, procname, elapsed, startDt, durSec
    &p_prefix._dsio    step, role (INPUT|OUTPUT|UPDATE), ds (LIB.MEM, upper case), memtype (DATA|VIEW)
    &p_prefix._fileio  step, role (INPUT|OUTPUT), path
    &p_prefix._attrs   step, ord (record order), role (INPUT|OUTPUT), ds, var, type, length, label, format, informat
    &p_prefix._src     step, lineno, text   (the submitted source of the step, comments/blank lines removed)

  Utility files (WORK.'SASTMP-...'.UTILITY, written by PROC SORT) are ignored. SAS opens concatenated
  libraries such as SASHELP under an internal alias (libref #C00003, announced by a CONCATMEM record);
  the alias is replaced by the real library (SASHELP.PRDSALE). An alias without a CONCATMEM record is dropped.

  Example usage:

      %lin_readLog(p_inFile=%str(D:/logs/sca__fuzzy.txt), p_prefix=lin)

  @param [in] p_inFile= Full path of the SCAPROC text file. Required.
  @param [in] p_prefix= Prefix of the WORK tables created. Default:lin.

  @version 9.4
  @author Ahmed Al-Attar
**/
%macro lin_readLog(p_inFile=, p_prefix=lin);

  %GLOBAL g_linRC;
  %let g_linRC = 0;

  %if (%SUPERQ(p_inFile) EQ ) %then
  %do;
    %put ERROR: lin_readLog: p_inFile is missing;
    %let g_linRC = 1;
    %return;
  %end;
  %if (%sysfunc(fileexist(&p_inFile)) = 0) %then
  %do;
    %put ERROR: lin_readLog: the file &p_inFile does not exist;
    %let g_linRC = 2;
    %return;
  %end;

  DATA &p_prefix._steps (KEEP=step procname elapsed startDt)
       &p_prefix._dsio  (KEEP=step role ds memtype)
       &p_prefix._fileio(KEEP=step role path)
       &p_prefix._attrs (KEEP=step ord role ds var type length label format informat)
       &p_prefix._src   (KEEP=step lineno text)
       &p_prefix._cmem  (KEEP=alias rlib);

    INFILE "&p_inFile" LRECL=32767 TRUNCOVER END=eof;
    INPUT;

    LENGTH line $4000 rec $4000 kw $32 procname $32 role $8 memtype $8
           ds $80 lib $32 alias rlib $32 mem $64 path $1000 var $64 type $9 label $256 format informat $32
           text $2000 startTxt $40;
    RETAIN step 0 inSrc 0 lineno 0 procname '' elapsed . startDt . rxAttr;

    IF (_n_ = 1) THEN
      rxAttr = PRXPARSE('/^ATTR (\S+) (INPUT|OUTPUT) VARIABLE:(.*) TYPE:(\w+) LENGTH:(\d+) LABEL:(.*) FORMAT:(\S*) INFORMAT:(\S*)\s*$/');

    line = _INFILE_;

    IF (line =: '/* JOBSPLIT: ') THEN
    DO;
      inSrc = 0;
      rec = STRIP(SUBSTR(line, 14));
      /* drop the closing comment marker */
      IF (LENGTH(rec) >= 2 AND SUBSTR(rec, LENGTH(rec) - 1) = '*/') THEN rec = STRIP(SUBSTR(rec, 1, LENGTH(rec) - 2));
      kw = SCAN(rec, 1, ' ');

      SELECT (kw);
        WHEN ('TASKSTARTTIME')
        DO;
          IF (step > 0) THEN OUTPUT &p_prefix._steps;
          step + 1;
          procname = '';
          elapsed  = .;
          lineno   = 0;
          startTxt = SCAN(rec, 2, ' ');
          startDt  = INPUT(startTxt, ?? datetime25.);
        END;
        WHEN ('PROCNAME') procname = SCAN(rec, 2, ' ');
        WHEN ('ELAPSED')  elapsed  = INPUT(SCAN(rec, 2, ' '), ?? best12.);
        WHEN ('STEP')
        DO;
          IF (rec =: 'STEP SOURCE FOLLOWS') THEN inSrc = 1;
        END;
        WHEN ('DATASET')
        DO;
          role = SCAN(rec, 2, ' ');
          ds   = SCAN(rec, 4, ' ');
          lib  = UPCASE(COMPRESS(SCAN(ds, 1, '.'), "'"));
          mem  = UPCASE(COMPRESS(SCAN(ds, 2, '.'), "'"));
          memtype = UPCASE(SCAN(ds, 3, '.'));
          ds   = CATX('.', lib, mem);
          IF (memtype NE 'UTILITY') THEN OUTPUT &p_prefix._dsio;
        END;
        WHEN ('CONCATMEM')
        DO;
          alias = UPCASE(SCAN(rec, 2, ' '));
          rlib  = UPCASE(SCAN(rec, 3, ' '));
          IF (SUBSTR(alias, 1, 1) = '#' AND NOT MISSING(rlib)) THEN OUTPUT &p_prefix._cmem;
        END;
        WHEN ('FILE')
        DO;
          role = SCAN(rec, 2, ' ');
          path = STRIP(SUBSTR(rec, LENGTH('FILE ') + LENGTH(role) + 2));
          OUTPUT &p_prefix._fileio;
        END;
        WHEN ('ATTR')
        DO;
          IF (PRXMATCH(rxAttr, rec)) THEN
          DO;
            ord      = _n_;
            ds       = PRXPOSN(rxAttr, 1, rec);
            role     = PRXPOSN(rxAttr, 2, rec);
            var      = STRIP(PRXPOSN(rxAttr, 3, rec));
            type     = PRXPOSN(rxAttr, 4, rec);
            length   = INPUT(PRXPOSN(rxAttr, 5, rec), ?? best12.);
            label    = STRIP(PRXPOSN(rxAttr, 6, rec));
            format   = PRXPOSN(rxAttr, 7, rec);
            informat = PRXPOSN(rxAttr, 8, rec);
            lib = UPCASE(COMPRESS(SCAN(ds, 1, '.'), "'"));
            mem = UPCASE(COMPRESS(SCAN(ds, 2, '.'), "'"));
            memtype = UPCASE(SCAN(ds, 3, '.'));
            ds  = CATX('.', lib, mem);
            IF (memtype NE 'UTILITY') THEN OUTPUT &p_prefix._attrs;
          END;
        END;
        OTHERWISE;
      END;
    END;
    ELSE IF (inSrc AND step > 0) THEN
    DO;
      /* keep the submitted source; skip blank lines and comment-only lines */
      IF (NOT MISSING(line)) AND NOT (STRIP(line) =: '/*' AND INDEX(line, '*/') > 0 AND
          LENGTH(STRIP(line)) = INDEX(STRIP(line), '*/') + 1) THEN
      DO;
        lineno + 1;
        text = line;
        OUTPUT &p_prefix._src;
      END;
    END;

    IF (eof AND step > 0) THEN OUTPUT &p_prefix._steps;
  RUN;

  /* replace the internal library aliases by the real library; the CONCATMEM record can come after the
     DATASET / ATTR records that use the alias, hence the second pass */
  %LOCAL l_t l_tbl;
  %do l_t = 1 %to 2;
    %let l_tbl = %scan(&p_prefix._dsio &p_prefix._attrs, &l_t, %str( ));
    DATA &l_tbl;
      LENGTH alias rlib $32;
      IF (_n_ = 1) THEN
      DO;
        DECLARE HASH h (DATASET: "&p_prefix._cmem");
        h.DEFINEKEY('alias');
        h.DEFINEDATA('rlib');
        h.DEFINEDONE();
        CALL MISSING(alias, rlib);
      END;
      SET &l_tbl;
      IF (SUBSTR(ds, 1, 1) = '#') THEN
      DO;
        alias = SCAN(ds, 1, '.');
        IF (h.FIND() = 0) THEN ds = CATX('.', rlib, SCAN(ds, 2, '.'));
        ELSE DELETE;
      END;
      DROP alias rlib;
    RUN;
  %end;

  /* step duration = gap to the next TASKSTARTTIME (same approach as util_parseScaproc) */
  DATA &p_prefix._steps;
    SET &p_prefix._steps NOBS=n;
    IF (_n_ < n) THEN
    DO;
      p = _n_ + 1;
      SET &p_prefix._steps (KEEP=startDt RENAME=(startDt=nextDt)) POINT=p;
    END;
    ELSE nextDt = .;
    durSec = IFN(NOT MISSING(nextDt), nextDt - startDt, .);
    DROP nextDt p;
  RUN;


%mend lin_readLog;
