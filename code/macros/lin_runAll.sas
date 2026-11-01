/**
  @file lin_runall.sas
  @brief Extracts lineage and draws the DAGs for EVERY SCAPROC text file in a folder.
  @details Lists p_logDir, and runs %lin_processLog for each file with the extension p_ext.
  Every log gets its own sub-folder under p_outDir (named after the file), holding the files below

  <ul><li>*_dataset.dot </li>
  <li>*_dataset_attrs.dot </li>
  <li>*_column.dot </li>
  <li>*_steps.csv </li>
  <li>*_dataset_lineage.csv </li>
  <li>*_column_lineage.csv </li>
  </ul>

  Files that are empty or hold no SCAPROC steps are reported in the summary and skipped. The one-row-per-log summary is written to
  <p_outDir>/lineage_summary.csv and is left in WORK.LIN_SUMMARY.

  Example usage:

      %lin_runAll(p_logDir=%str(<Path>/logs)
      , p_outDir=%str(<Path>/lineage)
      , p_attrs_yn=Y)

  @param [in] p_logDir= Folder holding the SCAPROC text files. Required.
  @param [in] p_outDir= Existing output folder. Required.
  @param [in] p_ext= Extension of the files to process. Default:txt.
  @param [in] p_attrs_yn= Y|N list the columns inside the data set nodes of the dataset DAG. Default:N.
  @param [in] p_includeSteps_yn= Y|N draw the processing steps in the dataset DAG. Default:Y.
  @param [in] p_columnDag_yn= Y|N also write the column DAG. Default:Y.
  @param [in] p_rankDir= TB|BT|LR|RL layout direction. Default:LR.
  @param [in] p_json_yn= Y|N also write a .json graph per recording. Default:N.

  <h4> SAS Macros </h4>
  @li lin_readlog.sas

  @version 9.4
  @author Ahmed Al-Attar
**/
%macro lin_runAll(p_logDir=, p_outDir=, p_ext=txt, p_attrs_yn=N, p_includeSteps_yn=Y
, p_columnDag_yn=Y, p_rankDir=LR, p_json_yn=N);

  %GLOBAL g_linRC;
  %LOCAL l_n;
  %let g_linRC = 0;

  %if ((%SUPERQ(p_logDir) EQ ) OR (%SUPERQ(p_outDir) EQ )) %then
  %do;
    %put ERROR: lin_runAll: p_logDir and p_outDir are required;
    %let g_linRC = 1;
    %return;
  %end;
  %if (%sysfunc(fileexist(&p_logDir)) = 0) %then
  %do;
    %put ERROR: lin_runAll: the folder &p_logDir does not exist;
    %let g_linRC = 2;
    %return;
  %end;
  %if (%sysfunc(fileexist(&p_outDir)) = 0) %then
  %do;
    %put ERROR: lin_runAll: the folder &p_outDir does not exist;
    %let g_linRC = 3;
    %return;
  %end;

  /* start a fresh summary */
  PROC DATASETS LIB=WORK NOLIST NOWARN;
    DELETE lin_summary;
  RUN; QUIT;

  /* list the files, and make one output sub-folder per file */
  DATA work._lin_list (KEEP=path outSub);
    LENGTH fref $8 fn $256 base $256 safe $256 path outSub $1000;
    rc = FILENAME(fref, "&p_logDir");
    did = DOPEN(fref);
    IF (did > 0) THEN
    DO;
      DO i = 1 TO DNUM(did);
        fn = DREAD(did, i);
        IF (LOWCASE(SCAN(fn, -1, '.')) = LOWCASE("&p_ext") AND INDEX(fn, '.') > 1) THEN
        DO;
          base = SUBSTR(fn, 1, FINDC(fn, '.', 'b') - 1);
          safe = PRXCHANGE('s/[^A-Za-z0-9_.-]/_/', -1, STRIP(base));
          path = CATS("&p_logDir", '/', fn);
          dcr = DCREATE(safe, "&p_outDir");
          outSub = CATS("&p_outDir", '/', safe);
          OUTPUT;
        END;
      END;
      rc = DCLOSE(did);
    END;
    rc = FILENAME(fref);
  RUN;

  PROC SORT DATA=work._lin_list;
    BY path;
  RUN;

  PROC SQL NOPRINT;
    SELECT COUNT(*) INTO :l_n TRIMMED FROM work._lin_list;
  QUIT;
  %put NOTE: lin_runAll: &l_n file(s) with extension .&p_ext found in &p_logDir;

  %if (&l_n = 0) %then %return;

  /* one macro call per file; %nrstr protects paths containing & % , ( ) */
  FILENAME _linrun TEMP;
  DATA _NULL_;
    SET work._lin_list;
    FILE _linrun LRECL=4000;
    PUT '%lin_processLog(p_inFile=%nrstr(' path +(-1) ')';
    PUT ', p_outDir=%nrstr(' outSub +(-1) ')';
    PUT ", p_attrs_yn=&p_attrs_yn, p_includeSteps_yn=&p_includeSteps_yn";
    PUT ", p_columnDag_yn=&p_columnDag_yn, p_rankDir=&p_rankDir, p_json_yn=&p_json_yn)";
  RUN;
  %include _linrun;
  FILENAME _linrun CLEAR;

  %if (%sysfunc(exist(work.lin_summary))) %then
  %do;
    PROC EXPORT DATA=work.lin_summary OUTFILE="&p_outDir/lineage_summary.csv" DBMS=CSV REPLACE; RUN;
  %end;

  PROC DATASETS LIB=WORK NOLIST NOWARN;
    DELETE _lin_list;
  RUN; QUIT;

  %let g_linRC = 0;

%mend lin_runAll;
