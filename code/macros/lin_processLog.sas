/**
  @file lin_processlog.sas
  @brief Extracts the data / column lineage of ONE SCAPROC recording and draws its DAGs.
  @details Runs the whole chain for one *.txt file:
        %lin_readLog -> %lin_prepSource -> %lin_exprDataStep + %lin_exprSql -> %lin_tokenize -> %lin_buildLineage -> %lin_writeDag

  and writes into p_outDir
      |Name|Description|
      |---|---|
      |<p_name>_dataset.dot|data set level DAG|
      |<p_name>_column.dot|column level DAG|
      |<p_name>_column_lineage.csv|one row per column lineage edge (see %lin_buildLineage)|
      |<p_name>_dataset_lineage.csv|one row per step input / output (data sets and files, with version)|
      |<p_name>_steps.csv|one row per step (proc, elapsed, duration)|
      |<p_name>.json|node / edge graph of both levels (only when p_json_yn=Y)|
      |<p_name>_source.csv|one row per source|


  A one-row summary is appended to WORK.LIN_SUMMARY (created on first use).
  The global macro variable G_LINRC is 0 when the log was processed, otherwise<br>
  1 = p_inFile / p_outDir missing, <br>2 = input does not exist, <br>3 = output folder does not exist,
  <br>4 = the file holds no SCAPROC steps.

  Example usage:

      %lin_processLog(p_inFile=%str(~/logs/sca__fuzzy.txt), p_outDir=%str(~/lineage/fuzzy), p_attrs_yn=Y)

  @param [in] p_inFile= SCAPROC text file. Required.
  @param [in] p_outDir= Existing output folder. Required.
  @param [in] p_name= Base name of the output files. Default: the file name without its extension.
  @param [in] p_attrs_yn= Y|N list the columns inside the data set nodes of the dataset DAG. Default:N.
  @param [in] p_includeSteps_yn= Y|N draw the processing steps in the dataset DAG. Default:Y.
  @param [in] p_columnDag_yn= Y|N also write the column DAG. Default:Y.
  @param [in] p_rankDir= TB|BT|LR|RL layout direction. Default:LR.
  @param [in] p_json_yn= Y|N also write <p_name>.json (nodes / edges of both levels, see %lin_writeJson). Default:N.
  @param [in] p_prefix= Prefix of the WORK tables used while processing. Default:lin.

  <h4> SAS Macros </h4>
  @li lin_readlog.sas
  @li lin_prepsource.sas
  @li lin_exprdatastep.sas
  @li lin_exprsql.sas
  @li lin_tokenize.sas
  @li lin_buildlineage.sas
  @li lin_writedag.sas
  @li lin_writejson.sas

  @version 9.4
  @author Ahmed Al-Attar
**/

%macro lin_processLog(
  p_inFile=
, p_outDir=
, p_name=
, p_attrs_yn=N 
, p_includeSteps_yn=Y 
, p_columnDag_yn=Y 
, p_rankDir=LR 
, p_json_yn=N 
, p_prefix=lin);

  %GLOBAL g_linRC;
  %LOCAL 
  l_prefix 
  l_name 
  l_nsteps 
  l_nattrs 
  l_nexprdatastep
  l_status 
  l_file 
  l_dot 
  l_logsRoot
  l_slash
  ;

	%LOCAL
  l_sTime
  l_eTime
  l_rTime
  ;
  
  %LOCAL 
  l_nds
  l_nfile 
  l_ncol 
  l_nexpr 
  l_nname 
  l_nother 
  l_nunres 
  l_nnosrc 
  l_nauto 
  l_pct;
  
	* Record Starting Time;
	%let l_sTime = %sysfunc(time());
  %let g_linRC=0;
  %let l_prefix=&p_prefix;
  %let l_status=OK;

  %let l_logsRoot = %sysfunc(pathname(WORK));
  %if (%symexist(g_logsRoot)) %then %let l_logsRoot = &g_logsRoot;
  
  %if (%symexist(g_slash)) %then %let l_slash=&g_slash;
  %else %let l_slash=/;

  /* start recording */
  %lin_startRecord(p_outFile=%str(&l_logsRoot.&l_slash.sca__lin_processlog.txt)
  , p_replace_yn=Y
  , p_enableFlagName=g_enableScaProc)

  %if ((%SUPERQ(p_inFile) EQ ) OR (%SUPERQ(p_outDir) EQ )) %then 
  %do;
    %put ERROR: lin_processLog: p_inFile and p_outDir are required;
    %let g_linRC=1;
    %return;
  %end;
  %if (%sysfunc(fileexist(&p_inFile))=0) %then 
  %do;
    %put ERROR: lin_processLog: the file &p_inFile does not exist;
    %let g_linRC=2;
    %return;
  %end;
  %if (%sysfunc(fileexist(&p_outDir))=0) %then 
  %do;
    %put ERROR: lin_processLog: the folder &p_outDir does not exist;
    %let g_linRC=3;
    %return;
  %end;

  %if (%SUPERQ(p_name) EQ ) %then 
  %do;
    %let l_file=%qscan(&p_inFile, -1, %str(/\));
    %let l_dot=%sysfunc(findc(&l_file, ., b));
    %if (&l_dot > 1) %then %let l_name=%qsubstr(&l_file, 1, %eval(&l_dot - 1));
    %else %let l_name=&l_file;
  %end;
  %else %let l_name=&p_name;
  %let l_name=%sysfunc(translate(&l_name, %str(_), %str( )));

  %put NOTE: lin_processLog: &p_inFile -> &p_outDir/&l_name.*;

  %lin_readLog(p_inFile=&p_inFile, p_prefix=&l_prefix) 
  %if (&g_linRC NE 0) %then
    %return;

  PROC SQL NOPRINT;
    SELECT COUNT(*) INTO :l_nsteps TRIMMED FROM work.&p_prefix._steps;
  QUIT;

  %if (&l_nsteps=0) %then 
  %do;
    %put WARNING: lin_processLog: &p_inFile holds no SCAPROC steps. Skipped.;
    %let g_linRC=4;
    %let l_status=EMPTY;
    %goto summary;
  %end;

  PROC SQL NOPRINT;
    SELECT COUNT(*) INTO :l_nattrs TRIMMED FROM work.&p_prefix._attrs;
  QUIT;
  %if (&l_nattrs=0) %then 
    %put WARNING: lin_processLog: &p_inFile has no ATTR records, so no columns can be traced. Record with the PROC SCAPROC RECORD options ATTR OPENTIMES EXPANDMACROS.;

  %lin_prepSource(p_prefix=&p_prefix, p_srcDsName=work.&p_prefix._src)
  %lin_exprDataStep(p_prefix=&p_prefix, p_stmtsDsName=work.&p_prefix._stmts, p_stepsDsName=work.&p_prefix._steps)
  %lin_exprSql(p_prefix=&p_prefix, p_stmtsDsName=work.&p_prefix._stmts, p_stepsDsName=work.&p_prefix._steps)
  %lin_tokenize(p_prefix=&p_prefix, p_exprSqlDsName=work.&p_prefix._exprSql, p_exprDsDsName=work.&p_prefix._exprDs )
  %lin_buildLineage(p_prefix=&p_prefix
  , p_stepsDsName=work.&p_prefix._steps
  , p_dsioDsName=work.&p_prefix._dsio
  , p_fileioDsName=work.&p_prefix._fileio
  , p_attrsDsName=work.&p_prefix._attrs
  , p_stmtsDsName=work.&p_prefix._stmts
  , p_aliasDsName=work.&p_prefix._alias
  , p_eexprDsName=work.&p_prefix._eexpr
  , p_refDsName=work.&p_prefix._ref)
  %lin_writeDag(p_prefix=&p_prefix, p_outDir=&p_outDir, p_name=&l_name
  , p_attrs_yn=&p_attrs_yn , p_includeSteps_yn=&p_includeSteps_yn
  , p_columnDag_yn=&p_columnDag_yn, p_rankDir=&p_rankDir
  , p_stepsDsName=work.&p_prefix._steps
  , p_dsioDsName=work.&p_prefix._dsio
  , p_fileioDsName=work.&p_prefix._fileio
  , p_attrsDsName=work.&p_prefix._attrs
  , p_srcDsName=work.&p_prefix._src
  , p_dsverDsName=work.&p_prefix._dsver
  , p_cmemDsName=work.&p_prefix._cmem
  , p_collinDsName=work.&p_prefix._collin) 

  %if (%upcase(&p_json_yn)=Y) %then 
  %do;
    %lin_writeJson(p_prefix=&p_prefix, p_outFile=&p_outDir/&l_name..json,
    p_name=&l_name, p_attrs_yn=&p_attrs_yn ,
    p_includeSteps_yn=&p_includeSteps_yn, p_columnGraph_yn=&p_columnDag_yn
    , p_stepsDsName=work.&p_prefix._steps
    , p_fileioDsName=work.&p_prefix._fileio
    , p_attrsDsName=work.&p_prefix._attrs
    , p_collinDsName=work.&p_prefix._collin
    , p_dsverDsName=work.&p_prefix._dsver)
  %end;

  /* ---- the extracted lineage as CSV ---- */
  PROC SQL;
    CREATE TABLE work._lin_dslin AS 
    SELECT d.step, s.procname, d.io
    , 'DATASET' AS kind LENGTH=8
    , d.ds AS name LENGTH=1000
    , d.ver 
    FROM &p_prefix._dsver d
    LEFT JOIN &p_prefix._steps s ON s.step=d.step 
    UNION 
    SELECT f.step,
      s.procname, CASE f.role WHEN 'INPUT' THEN 'IN' ELSE 'OUT' END, 'FILE',
      f.path, . 
    FROM &p_prefix._fileio f 
    LEFT JOIN &p_prefix._steps s ON s.step=f.step 
    ORDER BY 1, 3, 5;
  QUIT;

  PROC EXPORT DATA=&p_prefix._collin
    OUTFILE="&p_outDir/&l_name._column_lineage.csv" DBMS=CSV REPLACE;
  RUN;

  PROC EXPORT DATA=work._lin_dslin
    OUTFILE="&p_outDir/&l_name._dataset_lineage.csv" DBMS=CSV REPLACE;
  RUN;

  PROC EXPORT DATA=&p_prefix._steps OUTFILE="&p_outDir/&l_name._steps.csv"
    DBMS=CSV REPLACE;
  RUN;

  %summary: /* ---- one summary row per processed log ---- */ 
    %let l_nds=0;
    %let l_nfile=0;
    %let l_ncol=0;
    %let l_nexpr=0;
    %let l_nname=0;
    %let l_nother=0;
    %let l_nunres=0;
    %let l_nnosrc=0;
    %let l_nauto=0;
    %let l_pct=.;

    %if (&l_status=OK) %then 
    %do;
      PROC SQL NOPRINT;
        SELECT COUNT(DISTINCT ds) INTO :l_nds TRIMMED FROM &p_prefix._dsio;
        SELECT COUNT(DISTINCT path) INTO :l_nfile TRIMMED FROM &p_prefix._fileio;
        SELECT COUNT(*) INTO :l_ncol TRIMMED FROM &p_prefix._collin;
        SELECT COUNT(*) INTO :l_nexpr TRIMMED FROM &p_prefix._collin WHERE method=
          'EXPR';
        SELECT COUNT(*) INTO :l_nname TRIMMED FROM &p_prefix._collin WHERE method=
          'NAME';
        SELECT COUNT(*) INTO :l_nother TRIMMED FROM &p_prefix._collin WHERE method
          IN ('FILE', 'INPUT', 'RENAME', 'CONST');
        SELECT COUNT(*) INTO :l_nunres TRIMMED FROM &p_prefix._collin WHERE method
          ='UNRESOLVED';
        SELECT COUNT(*) INTO :l_nnosrc TRIMMED FROM &p_prefix._collin WHERE method
          ='NOSOURCE';
        SELECT COUNT(*) INTO :l_nauto TRIMMED FROM &p_prefix._collin WHERE method=
          'AUTO';
      QUIT;

      %if (&l_nnosrc > 0) %then %put WARNING: lin_processLog: &l_nnosrc column(s)
        come from steps with no recorded source (NOSOURCE). SCAPROC does not
        record code that is included from a file or generated by CALL EXECUTE:
        submit the code directly when recording.;

      %if (%eval(&l_ncol - &l_nnosrc) > 0) %then 
        %let l_pct=%sysevalf(100 * &l_nunres / (&l_ncol - &l_nnosrc));
    %end;

    DATA work._lin_sum;
      LENGTH logFile $1000 name $200 status $8;
      logFile=SCAN(TRANSLATE(SYMGET('p_inFile'), '/', ''), -1, '/');
      name="&l_name";
      status="&l_status";
      steps=&l_nsteps;
      datasets=&l_nds;
      files=&l_nfile;
      colEdges=&l_ncol;
      exprEdges=&l_nexpr;
      nameEdges=&l_nname;
      otherEdges=&l_nother;
      unresolved=&l_nunres;
      noSource=&l_nnosrc;
      autoEdges=&l_nauto;
      unresPct=&l_pct;
        /* unresolved as % of the column edges of steps that have a recorded source */
    RUN;

    PROC APPEND BASE=work.lin_summary DATA=work._lin_sum; RUN;

    PROC DATASETS LIB=WORK NOLIST NOWARN;
      DELETE _lin_dslin _lin_sum
        &p_prefix._steps &p_prefix._dsio &p_prefix._fileio &p_prefix._attrs &p_prefix._src &p_prefix._stmts
        &p_prefix._exprDs &p_prefix._exprSql &p_prefix._alias &p_prefix._eexpr &p_prefix._ref
        &p_prefix._collin &p_prefix._dsver &p_prefix._cmem;
      RUN;
    QUIT;

	%goto finished;

	%finished:
		%let l_eTime=%sysfunc(time());
		%let l_rTime=%sysfunc(putn(%sysevalf(&l_eTime - &l_sTime),time12.2));
		%PUT >>> lin_processLog :>>> Total RunTime = &l_rTime;

    /* stop and write out recording */
    %lin_stopRecord(p_enableFlagName=g_enableScaProc);
%mend lin_processLog;
