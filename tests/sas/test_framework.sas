/**
  @file test_framework.sas
  @brief Minimal assertion helpers for the lineage tests.
  @details Every assertion prints exactly one line to the log, starting with TEST_PASS: or
  TEST_FAIL:, which tests/run_tests.py collects.
**/

/* Print a PASS/FAIL line. p_cond must be a macro-evaluable expression. */
%macro t_assert(p_name=, p_cond=);
  %if (&p_cond) %then %put TEST_PASS: &p_name;
  %else %put TEST_FAIL: &p_name (condition: &p_cond);
%mend t_assert;

/* Count the rows of a table that satisfy a condition; the count is left in the global macro variable T_N */
%macro t_count(p_ds=, p_where=1);
  %GLOBAL t_n;
  %let t_n = 0;
  %if (%sysfunc(exist(&p_ds)) = 0) %then %return;
  PROC SQL NOPRINT;
    SELECT COUNT(*) INTO :t_n TRIMMED FROM &p_ds WHERE &p_where;
  QUIT;
%mend t_count;

/* Assert that exactly p_expect rows satisfy the condition */
%macro t_rows(p_name=, p_ds=, p_where=1, p_expect=1);
  %t_count(p_ds=&p_ds, p_where=&p_where)
  %t_assert(p_name=&p_name, p_cond=&t_n = &p_expect)
%mend t_rows;

/* Record the SCAPROC output of the code that follows into p_file (same options as %util_initScaproc); end with %t_recordStop */
%macro t_recordStart(p_file=);
  /* SCAPROC appends to an existing file, so start from nothing */
  DATA _NULL_;
    rc = FILENAME('trec', "&p_file");
    IF (FEXIST('trec')) THEN rc = FDELETE('trec');
    rc = FILENAME('trec');
  RUN;
  PROC SCAPROC;
    RECORD "&p_file" ATTR OPENTIMES EXPANDMACROS;
  RUN;
%mend t_recordStart;

%macro t_recordStop;
  PROC SCAPROC;
    WRITE;
  RUN;
%mend t_recordStop;

/* Count edge endpoints in a .dot file that have no node definition line (-1 = no edges at all) */
%macro t_dotDangling(p_file=, p_outVar=);
  %GLOBAL &p_outVar;
  DATA _NULL_;
    INFILE "&p_file" LRECL=32767 END=eof;
    INPUT;
    LENGTH id $400;
    RETAIN rxNode rxEdge;
    IF (_n_ = 1) THEN
    DO;
      rxNode = PRXPARSE('/^\s*"((?:[^"\\]|\\.)+)" \[/');
      rxEdge = PRXPARSE('/^\s*"((?:[^"\\]|\\.)+)" -> "((?:[^"\\]|\\.)+)"/');
      DECLARE HASH nodes();
      nodes.definekey('id');
      nodes.definedone();
      DECLARE HASH ends();
      ends.definekey('id');
      ends.definedone();
      DECLARE HITER ei('ends');
    END;
    IF (PRXMATCH(rxNode, _INFILE_)) THEN
    DO;
      id = PRXPOSN(rxNode, 1, _INFILE_);
      rc = nodes.replace();
    END;
    ELSE IF (PRXMATCH(rxEdge, _INFILE_)) THEN
    DO;
      id = PRXPOSN(rxEdge, 1, _INFILE_); rc = ends.replace();
      id = PRXPOSN(rxEdge, 2, _INFILE_); rc = ends.replace();
    END;
    IF (eof) THEN
    DO;
      dangling = 0;
      rc = ei.first();
      DO WHILE (rc = 0);
        IF (nodes.check() NE 0) THEN dangling + 1;
        rc = ei.next();
      END;
      CALL SYMPUTX("&p_outVar", IFN(ends.num_items = 0, -1, dangling));
    END;
  RUN;
%mend t_dotDangling;

/* Number of lines of a file that match a Perl regular expression */
%macro t_countRegex(p_file=, p_regex=, p_outVar=);
  %GLOBAL &p_outVar;
  %let &p_outVar = 0;
  %if (%sysfunc(fileexist(&p_file)) = 0) %then %return;
  DATA _NULL_;
    INFILE "&p_file" LRECL=32767 END=eof;
    INPUT;
    RETAIN n 0 rx;
    IF (_n_ = 1) THEN rx = PRXPARSE("/&p_regex/");
    IF (PRXMATCH(rx, _INFILE_)) THEN n + 1;
    IF (eof) THEN CALL SYMPUTX("&p_outVar", n);
  RUN;
%mend t_countRegex;
