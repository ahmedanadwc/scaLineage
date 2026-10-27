/**
  @file usage_lin_runAll.sas
  @brief Example: extract data / column lineage and draw the DAGs for every SCAPROC *.txt in a folder.
  @details Edit the three paths below, then submit the whole program in SAS.
  Render the resulting files with Graphviz, e.g.   dot -Tsvg x_column.dot -o x_column.svg
**/

/* ---- where things are --------------------------------------------------------------------- */
%let g_linRoot = %sysfunc(sysget(HOME))/scaLineage;       /* folder that holds code/ and your logs */
%let g_logDir  = &g_linRoot/logs;                         /* the SCAPROC *.txt files               */
%let g_outDir  = &g_linRoot/output;                       /* results, one sub-folder per log       */

/* ---- load the macros ------------------------------------------------------------------------ */
%macro loadLineage(p_codeDir=);
  %LOCAL i f;
  %let f = lin_startRecord lin_stopRecord lin_readLog lin_prepSource lin_exprDataStep lin_exprSql lin_tokenize lin_buildLineage
           lin_writeDag lin_writeJson lin_processLog lin_runAll;
  %do i = 1 %to %sysfunc(countw(&f));
    %include "&p_codeDir/%scan(&f, &i).sas";
  %end;
%mend loadLineage;
%loadLineage(p_codeDir=&g_linRoot/code/macros)

/* ---- make sure the output folder exists ------------------------------------------------------ */
OPTIONS DLCREATEDIR;
LIBNAME _out "&g_outDir";
LIBNAME _out CLEAR;

/* ---- every *.txt in the log folder ----------------------------------------------------------- */
%lin_runAll(
  p_logDir=&g_logDir
, p_outDir=&g_outDir
, p_attrs_yn=Y            /* list the columns inside the data set nodes   */
, p_includeSteps_yn=Y     /* draw the steps with their run times          */
, p_columnDag_yn=Y        /* also draw the column level DAG               */
, p_rankDir=LR)

/* work.lin_summary holds one row per log: steps, data sets, edges by kind, unresolved columns */
PROC PRINT DATA=work.lin_summary NOOBS;
RUN;

/* ---- or one log only ------------------------------------------------------------------------- */
/*
%lin_processLog(
  p_inFile=&g_logDir/sca__fuzzy.txt
, p_outDir=&g_outDir
, p_attrs_yn=Y)
*/
