/**
  @file lin_writeJson.sas
  @brief Writes the lineage of one SCAPROC recording as a node / edge JSON graph.
  @details One file holds both levels, so a consumer can filter on "level":

    nodes   {"id", "label", "type", "level", ...}
              type "dataset" (level dataset; "columns": [{name, type}] when p_attrs_yn=Y),
                   "file", "step" (with "step" number), "column" (level column; "dataset" = id of its
                   data set node, "unresolved": true when the step has source that does not say where the column
                   came from, "nosource": true when the step has no recorded source)
    edges   {"source", "target", "type", "level", ...}
              level dataset: type "input" (to a step), "output" (from a step) or "flow" (no step nodes)
              level column:  type "column", "method" (EXPR|RENAME|NAME|FILE|INPUT|CONST), "step", "expr"

  The dataset level uses the same source / target / type edges as the older dotMySASProgram JSON.
  Node ids are the ids used in the DOT files. A data set written more than once is one node per version.

  Needs the tables of %lin_readLog and %lin_buildLineage.

  @param [in] p_prefix= Prefix of the WORK tables. Default:lin.
  @param [in] p_outFile= Full path of the JSON file. Required.
  @param [in] p_name= Name stored in the "source" field. Required.
  @param [in] p_attrs_yn= Y|N list the columns inside the data set nodes. Default:N.
  @param [in] p_includeSteps_yn= Y|N step nodes with input -> step -> output edges. Default:Y.
  @param [in] p_columnGraph_yn= Y|N include the column nodes and column edges. Default:Y.

  @version 9.4
**/

/* expression that escapes a character value for a JSON string (backslash, quote, control characters) */
%macro lin_jq(p_x);
  PRXCHANGE('s/[\x00-\x1F]+/ /', -1, TRANWRD(TRANWRD(&p_x, '\', '\\'), '"', '\"'))
%mend lin_jq;

%macro lin_writeJson(p_prefix=lin, p_outFile=, p_name=, p_attrs_yn=N, p_includeSteps_yn=Y
, p_columnGraph_yn=Y);

  %LOCAL l_attrs l_steps l_cols;
  %let l_attrs = %upcase(&p_attrs_yn);
  %let l_steps = %upcase(&p_includeSteps_yn);
  %let l_cols  = %upcase(&p_columnGraph_yn);

  %if ((%SUPERQ(p_outFile) EQ ) OR (%SUPERQ(p_name) EQ )) %then
  %do;
    %put ERROR: lin_writeJson: p_outFile and p_name are required;
    %return;
  %end;

  /* ---- columns of every data set version (from the ATTR records) ---- */
  PROC SQL;
    CREATE TABLE work._lj_cols AS
    SELECT v.ds, v.ver, a.var, a.type, a.ord
    FROM &p_prefix._attrs a
    INNER JOIN &p_prefix._dsver v
      ON v.step = a.step AND v.ds = a.ds AND ((a.role = 'INPUT' AND v.io = 'IN') OR (a.role = 'OUTPUT' AND v.io = 'OUT'))
    ORDER BY v.ds, v.ver, a.var, a.ord;
  QUIT;
  DATA work._lj_cols;
    SET work._lj_cols;
    BY ds ver var;
    IF (FIRST.var);
  RUN;
  PROC SORT DATA=work._lj_cols;
    BY ds ver ord;
  RUN;

  /* ---- data set nodes: one per (ds, version); the version is only shown when a data set has several ---- */
  PROC SQL;
    CREATE TABLE work._lj_dsn AS
    SELECT DISTINCT d.ds, d.ver, n.nver
    FROM &p_prefix._dsver d
    INNER JOIN (SELECT ds, COUNT(DISTINCT ver) AS nver FROM &p_prefix._dsver GROUP BY ds) n ON n.ds = d.ds
    ORDER BY d.ds, d.ver;
  QUIT;
  DATA work._lj_dsn;
    SET work._lj_dsn;
    LENGTH id label $200;
    id = CAT(STRIP(ds), '#', STRIP(PUT(ver, best12.)));
    IF (nver = 1) THEN label = ds;
    ELSE label = CAT(STRIP(ds), ' (v', STRIP(PUT(ver, best12.)), ')');
    IF (nver > 1 AND ver = 0) THEN label = CAT(STRIP(ds), ' (existing)');
  RUN;

  /* ===== nodes: sec 1 data sets (with columns), 2 files, 3 steps, 4 columns, 5 in-stream data ===== */
  DATA work._lj_n1 (KEEP=sec obj seq st line);
    MERGE work._lj_dsn (IN=isDs) work._lj_cols (KEEP=ds ver var type ord);
    BY ds ver;
    IF (NOT isDs) THEN DELETE;
    LENGTH line $4000;
    RETAIN obj 0 seq 0 nc 0 hasc 0;
    sec = 1;
    st = 0;
    IF (FIRST.ver) THEN
    DO;
      obj + 1;
      nc = 0;
      hasc = ("&l_attrs" = 'Y' AND NOT MISSING(var));
      line = CAT('{"id": "', %lin_jq(STRIP(id)), '", "label": "', %lin_jq(STRIP(label)), '", "type": "dataset", "level": "dataset"');
      IF (hasc) THEN line = CAT(STRIP(line), ', "columns": [');
      ELSE line = CAT(STRIP(line), '}');
      st = 1;
      seq + 1;
      OUTPUT;
      st = 0;
    END;
    IF (hasc AND NOT MISSING(var)) THEN
    DO;
      line = CAT(IFC(nc > 0, ',', ' '), '{"name": "', %lin_jq(STRIP(var)), '", "type": "', IFC(type = 'CHARACTER', 'char', 'num'), '"}');
      nc + 1;
      seq + 1;
      OUTPUT;
    END;
    IF (LAST.ver AND hasc) THEN
    DO;
      line = ']}';
      seq + 1;
      OUTPUT;
    END;
  RUN;

  PROC SQL;
    CREATE TABLE work._lj_files AS
    SELECT DISTINCT path FROM &p_prefix._fileio
  %if (&l_cols = Y) %then
  %do;
    UNION
    SELECT DISTINCT fromDs FROM &p_prefix._collin WHERE fromKind = 'FILE'
  %end;
    ;
  QUIT;
  DATA work._lj_n2 (KEEP=sec obj seq st line);
    SET work._lj_files;
    LENGTH line $4000;
    sec = 2; obj = _n_; seq = 1; st = 1;
    line = CAT('{"id": "file:', %lin_jq(STRIP(path)), '", "label": "', %lin_jq(STRIP(SCAN(path, -1, '/\'))), '", "path": "', %lin_jq(STRIP(path)), '", "type": "file", "level": "dataset"}');
  RUN;

  /* every connection of a step: data set versions it reads / writes and files it reads / writes */
  PROC SQL;
    CREATE TABLE work._lj_edge AS
    SELECT v.step, v.io, n.id AS node LENGTH=400
    FROM &p_prefix._dsver v INNER JOIN work._lj_dsn n ON n.ds = v.ds AND n.ver = v.ver
    UNION
    SELECT step, CASE role WHEN 'INPUT' THEN 'IN' ELSE 'OUT' END, CATS('file:', path)
    FROM &p_prefix._fileio;
  QUIT;

  %if (&l_steps = Y) %then
  %do;
    PROC SQL;
      CREATE TABLE work._lj_stp AS
      SELECT s.step, s.procname, s.durSec
      FROM &p_prefix._steps s
      WHERE s.step IN (SELECT step FROM work._lj_edge)
      ORDER BY s.step;
    QUIT;
    DATA work._lj_n3 (KEEP=sec obj seq st line);
      SET work._lj_stp;
      LENGTH line $4000;
      sec = 3; obj = _n_; seq = 1; st = 1;
      line = CAT('{"id": "step_', STRIP(PUT(step, z4.)), '", "label": "', %lin_jq(STRIP(procname)), '", "type": "step", "level": "dataset", "step": ', STRIP(PUT(step, best12.)));
      IF (NOT MISSING(durSec)) THEN line = CAT(STRIP(line), ', "seconds": ', STRIP(PUT(durSec, best12.2)));
      line = CAT(STRIP(line), '}');
    RUN;
  %end;
  %else
  %do;
    DATA work._lj_n3;
      LENGTH sec obj seq st 8 line $4000;
      STOP;
    RUN;
  %end;

  %if (&l_cols = Y) %then
  %do;
    PROC SQL;
      CREATE TABLE work._lj_cn AS
      SELECT ds, ver, var FROM work._lj_cols
      UNION
      SELECT toDs, toVer, toVar FROM &p_prefix._collin
      UNION
      SELECT fromDs, fromVer, fromVar FROM &p_prefix._collin WHERE fromKind = 'DS';

      CREATE TABLE work._lj_cn2 AS
      SELECT c.ds, c.ver, c.var
           , EXISTS (SELECT 1 FROM &p_prefix._collin x
                     WHERE x.method = 'UNRESOLVED' AND x.toDs = c.ds AND x.toVer = c.ver AND x.toVar = c.var) AS unres
           , EXISTS (SELECT 1 FROM &p_prefix._collin x
                     WHERE x.method = 'NOSOURCE' AND x.toDs = c.ds AND x.toVer = c.ver AND x.toVar = c.var) AS nosrc
      FROM work._lj_cn c
      ORDER BY c.ds, c.ver, c.var;

      CREATE TABLE work._lj_src AS
      SELECT DISTINCT step FROM &p_prefix._collin WHERE fromKind = 'INLINE';
    QUIT;
    DATA work._lj_n4 (KEEP=sec obj seq st line);
      SET work._lj_cn2;
      LENGTH line $4000;
      sec = 4; obj = _n_; seq = 1; st = 1;
      line = CAT('{"id": "', %lin_jq(CATS(ds, '#', ver, '.', var)), '", "label": "', %lin_jq(STRIP(var)), '", "type": "column", "level": "column", "dataset": "'
               , %lin_jq(CATS(ds, '#', ver)), '"');
      IF (unres) THEN line = CAT(STRIP(line), ', "unresolved": true');
      IF (nosrc) THEN line = CAT(STRIP(line), ', "nosource": true');
      line = CAT(STRIP(line), '}');
    RUN;
    DATA work._lj_n5 (KEEP=sec obj seq st line);
      SET work._lj_src;
      LENGTH line $4000;
      sec = 5; obj = _n_; seq = 1; st = 1;
      line = CAT('{"id": "inline:', STRIP(PUT(step, best12.)), '", "label": "in-stream data (step ', STRIP(PUT(step, best12.)), ')", "type": "file", "level": "column", "step": ', STRIP(PUT(step, best12.)), '}');
    RUN;
  %end;
  %else
  %do;
    DATA work._lj_n4 work._lj_n5;
      LENGTH sec obj seq st 8 line $4000;
      STOP;
    RUN;
  %end;

  /* ===== edges: sec 1 data set level, 2 column level ===== */
  %if (&l_steps = Y) %then
  %do;
    DATA work._lj_e1 (KEEP=sec obj seq st line);
      SET work._lj_edge;
      LENGTH line $4000 sid $20;
      sec = 1; obj = _n_; seq = 1; st = 1;
      sid = CATS('step_', PUT(step, z4.));
      IF (io = 'IN') THEN
        line = CAT('{"source": "', %lin_jq(STRIP(node)), '", "target": "', STRIP(sid), '", "type": "input", "level": "dataset", "step": ', STRIP(PUT(step, best12.)), '}');
      ELSE
        line = CAT('{"source": "', STRIP(sid), '", "target": "', %lin_jq(STRIP(node)), '", "type": "output", "level": "dataset", "step": ', STRIP(PUT(step, best12.)), '}');
    RUN;
  %end;
  %else
  %do;
    PROC SQL;
      CREATE TABLE work._lj_e1 AS
      SELECT 1 AS sec, MONOTONIC() AS obj, 1 AS seq, 1 AS st
           , CAT('{"source": "', %lin_jq(STRIP(i.node)), '", "target": "', %lin_jq(STRIP(o.node))
               , '", "type": "flow", "level": "dataset", "step": ', STRIP(PUT(i.step, best12.)), '}') AS line LENGTH=4000
      FROM work._lj_edge i INNER JOIN work._lj_edge o ON o.step = i.step AND o.io = 'OUT'
      WHERE i.io = 'IN';
    QUIT;
  %end;

  %if (&l_cols = Y) %then
  %do;
    DATA work._lj_e2 (KEEP=sec obj seq st line);
      SET &p_prefix._collin (WHERE=(method NE 'UNRESOLVED' AND fromKind NE 'NONE'));
      LENGTH line $4000 src dst $400;
      sec = 2; obj = _n_; seq = 1; st = 1;
      IF (fromKind = 'DS') THEN src = CATS(fromDs, '#', fromVer, '.', fromVar);
      ELSE IF (fromKind = 'FILE') THEN src = CATS('file:', fromDs);
      ELSE src = CATS('inline:', step);
      dst = CATS(toDs, '#', toVer, '.', toVar);
      line = CAT('{"source": "', %lin_jq(STRIP(src)), '", "target": "', %lin_jq(STRIP(dst)), '", "type": "column", "level": "column", "method": "'
               , STRIP(method), '", "step": ', STRIP(PUT(step, best12.)));
      IF (NOT MISSING(expr)) THEN line = CAT(STRIP(line), ', "expr": "', %lin_jq(STRIP(expr)), '"');
      line = CAT(STRIP(line), '}');
    RUN;
  %end;
  %else
  %do;
    DATA work._lj_e2;
      LENGTH sec obj seq st 8 line $4000;
      STOP;
    RUN;
  %end;

  DATA work._lj_nodes;
    SET work._lj_n1 work._lj_n2 work._lj_n3 work._lj_n4 work._lj_n5;
  RUN;
  DATA work._lj_edges;
    SET work._lj_e1 work._lj_e2;
  RUN;
  PROC SORT DATA=work._lj_nodes; BY sec obj seq; RUN;
  PROC SORT DATA=work._lj_edges; BY sec obj seq; RUN;

  /* ===== write the file ===== */
  DATA _NULL_;
    FILE "&p_outFile" LRECL=32767;
    LENGTH line $4000;
    PUT '{';
    line = CAT('"generator": "scaLineage", "source": "', %lin_jq("&p_name"), '", "directed": true,');
    PUT line;
    PUT '"nodes": [';
  RUN;
  DATA _NULL_;
    FILE "&p_outFile" LRECL=32767 MOD;
    SET work._lj_nodes;
    RETAIN cnt 0;
    IF (st) THEN
    DO;
      line = CAT(IFC(cnt > 0, ',', ' '), STRIP(line));
      cnt + 1;
    END;
    PUT line;
  RUN;
  DATA _NULL_;
    FILE "&p_outFile" LRECL=32767 MOD;
    PUT '],';
    PUT '"edges": [';
  RUN;
  DATA _NULL_;
    FILE "&p_outFile" LRECL=32767 MOD;
    SET work._lj_edges;
    RETAIN cnt 0;
    line = CAT(IFC(cnt > 0, ',', ' '), STRIP(line));
    cnt + 1;
    PUT line;
  RUN;
  DATA _NULL_;
    FILE "&p_outFile" LRECL=32767 MOD;
    PUT ']';
    PUT '}';
  RUN;

  PROC DATASETS LIB=WORK NOLIST NOWARN;
    DELETE _lj_cols _lj_dsn _lj_files _lj_edge _lj_stp _lj_cn _lj_cn2 _lj_src
           _lj_n1 _lj_n2 _lj_n3 _lj_n4 _lj_n5 _lj_e1 _lj_e2 _lj_nodes _lj_edges;
  RUN; QUIT;

%mend lin_writeJson;
