/**
  @file lin_writeDag.sas
  @brief Draws the lineage of one SCAPROC recording as Graphviz (*.dot) DAGs.
  @details Writes two files into p_outDir (render them with Graphviz, e.g. dot -Tsvg x.dot -o x.svg):

    <p_name>_dataset.dot   data set level DAG: files, data sets and steps
                           (data sets are cylinders, or tables listing the columns when p_attrs_yn=Y)
    <p_name>_column.dot    column level DAG: one box per column, grouped in a cluster per data set,
                           one arrow per lineage edge (colour = how the column was derived)

  Colours in the column DAG:  grey = same name (NAME), blue = expression (EXPR), purple = rename,
  green = read from a file, red outline = no source could be determined.
  A data set written more than once appears once per version, e.g. WORK.ONE (v2).

  Needs the tables of %lin_readLog and %lin_buildLineage.

  @param [in] p_prefix= Prefix of the WORK tables. Default:lin.
  @param [in] p_outDir= Output folder. Required.
  @param [in] p_name= Base name of the output files. Required.
  @param [in] p_attrs_yn= Y|N list the columns inside the data set nodes of the dataset DAG. Default:N.
  @param [in] p_includeSteps_yn= Y|N draw the processing steps (with run time) in the dataset DAG. Default:Y.
  @param [in] p_columnDag_yn= Y|N also write the column DAG. Default:Y.
  @param [in] p_rankDir= TB|BT|LR|RL layout direction. Default:LR.

  @version 9.4
  @author Ahmed Al-Attar
**/

/* expression that escapes backslashes and double quotes for a DOT string */
%macro lin_q(p_x);
  TRANWRD(TRANWRD(&p_x, '\', '\\'), '"', '\"')
%mend lin_q;

/* expression that escapes the characters that are special inside an HTML label */
%macro lin_h(p_x);
  TRANWRD(TRANWRD(TRANWRD(&p_x, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
%mend lin_h;

/* write work._lin_dot (sec, seq, line) to a file in section order */
%macro lin_emit(p_file=);
  PROC SORT DATA=work._lin_dot;
    BY sec seq;
  RUN;
  DATA _NULL_;
    SET work._lin_dot;
    FILE "&p_file" LRECL=32767;
    PUT line;
  RUN;
  PROC DATASETS LIB=WORK NOLIST NOWARN;
    DELETE _lin_dot;
  RUN; QUIT;
%mend lin_emit;

%macro lin_writeDag(p_prefix=lin, p_outDir=, p_name=, p_attrs_yn=N, p_includeSteps_yn=Y
, p_columnDag_yn=Y, p_rankDir=LR) / minoperator;

  %LOCAL l_rankDir l_attrs l_steps;
  %let l_rankDir = %upcase(&p_rankDir);
  %if NOT (&l_rankDir IN (TB BT LR RL)) %then %let l_rankDir = LR;
  %let l_attrs = %upcase(&p_attrs_yn);
  %let l_steps = %upcase(&p_includeSteps_yn);

  %if ((%SUPERQ(p_outDir) EQ ) OR (%SUPERQ(p_name) EQ )) %then
  %do;
    %put ERROR: lin_writeDag: p_outDir and p_name are required;
    %return;
  %end;

  /* ---- columns of every data set version (from the ATTR records) ---- */
  PROC SQL;
    CREATE TABLE work._lin_cols AS
    SELECT v.ds, v.ver, a.var, a.type, a.ord
    FROM &p_prefix._attrs a
    INNER JOIN &p_prefix._dsver v
      ON v.step = a.step AND v.ds = a.ds AND ((a.role = 'INPUT' AND v.io = 'IN') OR (a.role = 'OUTPUT' AND v.io = 'OUT'))
    ORDER BY v.ds, v.ver, a.var, a.ord;
  QUIT;
  DATA work._lin_cols;
    SET work._lin_cols;
    BY ds ver var;
    IF (FIRST.var);
  RUN;
  PROC SORT DATA=work._lin_cols;
    BY ds ver ord;
  RUN;

  /* ---- data set nodes: one per (ds, version); the version is only shown when a data set has several ---- */
  PROC SQL;
    CREATE TABLE work._lin_dsn AS
    SELECT DISTINCT d.ds, d.ver, n.nver
    FROM &p_prefix._dsver d
    INNER JOIN (SELECT ds, COUNT(DISTINCT ver) AS nver FROM &p_prefix._dsver GROUP BY ds) n ON n.ds = d.ds
    ORDER BY d.ds, d.ver;
  QUIT;
  DATA work._lin_dsn;
    SET work._lin_dsn;
    LENGTH id label $200;
    id = CAT(STRIP(ds), '#', STRIP(PUT(ver, best12.)));      /* node id: no blanks or brackets */
    IF (nver = 1) THEN label = ds;
    ELSE label = CAT(STRIP(ds), ' (v', STRIP(PUT(ver, best12.)), ')');
    IF (nver > 1 AND ver = 0) THEN label = CAT(STRIP(ds), ' (existing)');
  RUN;

  /* =========================== dataset level DAG =========================== */
  DATA work._lin_d1;
    LENGTH line $4000;
    sec = 1;
    seq = 1; line = 'digraph dag {'; OUTPUT;
    seq = 2; line = "  rankdir=&l_rankDir;"; OUTPUT;
    seq = 3; line = CAT('  graph [label="\n', %lin_q("&p_name"), '"];'); OUTPUT;
    sec = 9;
    seq = 1; line = '}'; OUTPUT;
  RUN;

  %if (&l_attrs = Y) %then
  %do;
    /* one HTML table row per column */
    DATA work._lin_colstr (KEEP=ds ver cols);
      SET work._lin_cols;
      BY ds ver;
      LENGTH cols $30000;
      RETAIN cols;
      IF (FIRST.ver) THEN cols = '';
      cols = CATS(cols, '<TR><TD ALIGN="LEFT">', %lin_h(STRIP(var)), '</TD><TD ALIGN="LEFT">',
                  IFC(type = 'CHARACTER', 'char', 'num'), '</TD></TR>');
      IF (LAST.ver) THEN OUTPUT;
    RUN;
  %end;
  %else
  %do;
    DATA work._lin_colstr;
      LENGTH ds $80 ver 8 cols $10;
      STOP;
    RUN;
  %end;

  PROC SQL;
    CREATE TABLE work._lin_dn AS
    SELECT n.ds, n.ver, n.id, n.label, c.cols
    FROM work._lin_dsn n LEFT JOIN work._lin_colstr c ON c.ds = n.ds AND c.ver = n.ver
    ORDER BY n.ds, n.ver;
  QUIT;

  DATA work._lin_d2;
    SET work._lin_dn;
    LENGTH line $4000 lab $4000;
    sec = 2;
    seq = _n_;
    IF ("&l_attrs" = 'Y') THEN
    DO;
      lab = CATS('<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" BGCOLOR="lightblue"><TR><TD COLSPAN="2"><B>',
                 %lin_h(STRIP(label)), '</B></TD></TR>', cols, '</TABLE>>');
      line = CAT('  "', %lin_q(STRIP(id)), '" [shape=plaintext label=', STRIP(lab), '];');
    END;
    ELSE
      line = CAT('  "', %lin_q(STRIP(id)), '" [shape=cylinder fillcolor=lightblue style=filled label="', %lin_q(STRIP(label)), '"];');
    KEEP sec seq line;
  RUN;

  /* external files */
  PROC SQL;
    CREATE TABLE work._lin_files AS
    SELECT DISTINCT path FROM &p_prefix._fileio;
  QUIT;
  DATA work._lin_d3;
    SET work._lin_files;
    LENGTH line $4000;
    sec = 3;
    seq = _n_;
    line = CAT('  "file:', %lin_q(STRIP(path)), '" [shape="note" fillcolor=lightgreen style=filled label="', %lin_q(STRIP(SCAN(path, -1, '/\'))), '" tooltip="', %lin_q(STRIP(path)), '"];');
    KEEP sec seq line;
  RUN;

  /* every connection of a step: data set versions it reads/writes and files it reads/writes */
  PROC SQL;
    CREATE TABLE work._lin_edge AS
    SELECT v.step, v.io, n.id AS node LENGTH=400
    FROM &p_prefix._dsver v INNER JOIN work._lin_dsn n ON n.ds = v.ds AND n.ver = v.ver
    UNION
    SELECT step, CASE role WHEN 'INPUT' THEN 'IN' ELSE 'OUT' END, CATS('file:', path)
    FROM &p_prefix._fileio;
  QUIT;

  %if (&l_steps = Y) %then
  %do;
    PROC SQL;
      CREATE TABLE work._lin_stp AS
      SELECT s.step, s.procname, s.durSec
      FROM &p_prefix._steps s
      WHERE s.step IN (SELECT step FROM work._lin_edge)
      ORDER BY s.step;
    QUIT;
    DATA work._lin_d4;
      SET work._lin_stp;
      LENGTH line $4000 tm $20;
      sec = 4;
      seq = _n_;
      tm = '';
      IF (NOT MISSING(durSec)) THEN tm = CATS('\n', PUT(durSec, time12.2));
      line = CAT('  "step_', STRIP(PUT(step, z4.)), '" [shape="oval" fillcolor=yellow style=filled label="', STRIP(PUT(step, z3.)), ' ', %lin_q(STRIP(procname)), STRIP(tm), '"];');
      KEEP sec seq line;
    RUN;
    DATA work._lin_d5;
      SET work._lin_edge;
      LENGTH line $4000 sid $20;
      sec = 5;
      seq = _n_;
      sid = CATS('step_', PUT(step, z4.));
      IF (io = 'IN') THEN line = CAT('  "', %lin_q(STRIP(node)), '" -> "', STRIP(sid), '";');
      ELSE line = CAT('  "', STRIP(sid), '" -> "', %lin_q(STRIP(node)), '";');
      KEEP sec seq line;
    RUN;
  %end;
  %else
  %do;
    /* no step nodes: draw an arrow from every input of a step to every output of the same step */
    PROC SQL;
      CREATE TABLE work._lin_d5 AS
      SELECT 5 AS sec, i.step * 10000 + MONOTONIC() AS seq
           , CAT('  "', %lin_q(STRIP(i.node)), '" -> "', %lin_q(STRIP(o.node)), '";') AS line LENGTH=4000
      FROM work._lin_edge i INNER JOIN work._lin_edge o ON o.step = i.step AND o.io = 'OUT'
      WHERE i.io = 'IN';
    QUIT;
    DATA work._lin_d4;
      LENGTH line $4000;
      STOP;
      sec = 4; seq = 0;
    RUN;
  %end;

  DATA work._lin_dot;
    SET work._lin_d1 work._lin_d2 work._lin_d3 work._lin_d4 work._lin_d5;
  RUN;
  %lin_emit(p_file=&p_outDir/&p_name._dataset.dot)

  /* =========================== column level DAG =========================== */
  %if (%upcase(&p_columnDag_yn) = Y) %then
  %do;
    PROC SQL;
      /* every column that is mentioned: attribute records, plus both ends of every lineage edge */
      CREATE TABLE work._lin_cn AS
      SELECT ds, ver, var FROM work._lin_cols
      UNION
      SELECT toDs, toVer, toVar FROM &p_prefix._collin
      UNION
      SELECT fromDs, fromVer, fromVar FROM &p_prefix._collin WHERE fromKind = 'DS';

      CREATE TABLE work._lin_cn2 AS
      SELECT c.ds, c.ver, c.var, COALESCE(n.label, CAT(STRIP(c.ds), ' (v', STRIP(PUT(c.ver, best12.)), ')')) AS label LENGTH=200
           , CASE WHEN EXISTS (SELECT 1 FROM &p_prefix._collin x
                               WHERE x.method = 'UNRESOLVED' AND x.toDs = c.ds AND x.toVer = c.ver AND x.toVar = c.var)
                  THEN 'red' ELSE 'gray40' END AS colr LENGTH=10
           , o.ord
      FROM work._lin_cn c
      LEFT JOIN work._lin_dsn n ON n.ds = c.ds AND n.ver = c.ver
      LEFT JOIN work._lin_cols o ON o.ds = c.ds AND o.ver = c.ver AND o.var = c.var
      ORDER BY c.ds, c.ver, o.ord, c.var;

      /* file / in-stream sources */
      CREATE TABLE work._lin_src AS
      SELECT DISTINCT fromKind, fromDs, step FROM &p_prefix._collin WHERE fromKind IN ('FILE', 'INLINE');
    QUIT;

    DATA work._lin_c2;
      SET work._lin_cn2;
      BY ds ver;
      LENGTH line $4000 id $400;
      RETAIN seq 0 cl 0;
      sec = 2;
      IF (FIRST.ver) THEN
      DO;
        cl + 1;
        seq + 1;
        line = CAT('  subgraph "cluster_', STRIP(PUT(cl, best12.)), '" {');
        OUTPUT;
        seq + 1;
        line = CAT('    label="', %lin_q(STRIP(label)), '"; style="filled,rounded"; fillcolor=lightblue; color=steelblue; fontsize=14;');
        OUTPUT;
      END;
      id = CATS(ds, '#', ver, '.', var);
      seq + 1;
      line = CAT('    "', %lin_q(STRIP(id)), '" [shape=box style=filled fillcolor=white color=', STRIP(colr), ' label="', %lin_q(STRIP(var)), '"];');
      OUTPUT;
      IF (LAST.ver) THEN
      DO;
        seq + 1;
        line = '  }';
        OUTPUT;
      END;
      KEEP sec seq line;
    RUN;

    DATA work._lin_c3;
      SET work._lin_src;
      LENGTH line $4000;
      sec = 3;
      seq = _n_;
      IF (fromKind = 'FILE') THEN
        line = CAT('  "file:', %lin_q(STRIP(fromDs)), '" [shape="note" fillcolor=lightgreen style=filled label="', %lin_q(STRIP(SCAN(fromDs, -1, '/\'))), '" tooltip="', %lin_q(STRIP(fromDs)), '"];');
      ELSE
        line = CAT('  "inline:', STRIP(PUT(step, best12.)), '" [shape="note" fillcolor=lightgreen style=filled label="in-stream data (step ', STRIP(PUT(step, best12.)), ')"];');
      KEEP sec seq line;
    RUN;

    DATA work._lin_c4;
      SET &p_prefix._collin (WHERE=(method NE 'UNRESOLVED' AND fromKind NE 'NONE'));
      LENGTH line $4000 src dst $400 colr $20 tip $1000;
      sec = 5;
      seq = _n_;
      IF (fromKind = 'DS') THEN src = CATS(fromDs, '#', fromVer, '.', fromVar);
      ELSE IF (fromKind = 'FILE') THEN src = CATS('file:', fromDs);
      ELSE src = CATS('inline:', step);
      dst = CATS(toDs, '#', toVer, '.', toVar);
      SELECT (method);
        WHEN ('EXPR')   colr = 'blue';
        WHEN ('RENAME') colr = 'purple';
        WHEN ('NAME')   colr = 'gray50';
        OTHERWISE       colr = 'darkgreen';
      END;
      tip = CAT('step ', STRIP(PUT(step, best12.)), ' ', STRIP(procname), ' ', STRIP(method));
      IF (NOT MISSING(expr)) THEN tip = CAT(STRIP(tip), ': ', STRIP(expr));
      line = CAT('  "', %lin_q(STRIP(src)), '" -> "', %lin_q(STRIP(dst)), '" [color=', STRIP(colr), ' tooltip="', %lin_q(STRIP(tip)), '"];');
      KEEP sec seq line;
    RUN;

    DATA work._lin_c1;
      LENGTH line $4000;
      sec = 1;
      seq = 1; line = 'digraph column_lineage {'; OUTPUT;
      seq = 2; line = "  rankdir=&l_rankDir; compound=true;"; OUTPUT;
      seq = 3; line = CAT('  graph [label="\n', %lin_q("&p_name"), ' (column lineage)"];'); OUTPUT;
      seq = 4; line = '  node [fontname="Helvetica" fontsize=11];'; OUTPUT;
      sec = 9;
      seq = 1; line = '}'; OUTPUT;
    RUN;

    DATA work._lin_dot;
      SET work._lin_c1 work._lin_c2 work._lin_c3 work._lin_c4;
    RUN;
    %lin_emit(p_file=&p_outDir/&p_name._column.dot)
  %end;

  PROC DATASETS LIB=WORK NOLIST NOWARN;
    DELETE _lin_cols _lin_dsn _lin_colstr _lin_dn _lin_files _lin_edge _lin_stp _lin_cn _lin_cn2 _lin_src
           _lin_d1 _lin_d2 _lin_d3 _lin_d4 _lin_d5 _lin_c1 _lin_c2 _lin_c3 _lin_c4;
  RUN; QUIT;

%mend lin_writeDag;
