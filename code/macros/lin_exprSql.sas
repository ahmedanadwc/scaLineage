/**
  @file lin_exprsql.sas
  @brief Extracts column derivations from the recorded source of PROC SQL steps.
  @details Understands CREATE TABLE|VIEW x AS SELECT ... and INSERT INTO x SELECT ..., including joins,
  table aliases, CASE expressions, calculated columns and UNION / INTERSECT / EXCEPT.
  Creates

  <ul><li>work.&p_prefix._exprSql: Column derivations from the recorded source of PROC SQL steps</li>
|Variable|Description|
|---|---|
|step|The step number of the SQL step|
|qid|The query ID (one per SELECT segment)|
|toRaw|The raw text of the target (output) column|
|toVar|The name of the target (output) column|
|pos|The position of the column in the output|
|kind|The kind of derivation (always EXPR)|
|expr|The expression that defines the column|

<li>work.&p_prefix._alias: Concatenated Library alias information</li>
|Variable|Description|
|---|---|
|step|The step number of the SQL step|
|qid|The query ID (one per SELECT segment)|
|alias|The alias of the table|
|tblRaw|The raw text of the table|
</ul>

  Example usage:

      %lin_exprSql(p_prefix=&p_prefix, p_stmtsDsName=work.&p_prefix._stmts
      , p_stepsDsName=work.&p_prefix._steps)

  qid numbers the query segments of a step (a UNION has one qid per SELECT). Select items of the
  second and later segments take the column name of the item at the same position in the first segment.
  SELECT * / a.* items produce no row: they are covered by matching the column names.

  @note Not handled: nested sub-queries in the FROM clause are treated as unknown tables (the columns
  are then matched by name against every input table).

  @param [in] p_prefix= Prefix of the WORK tables. Default:lin.
  @param [in] p_stmtsDsName=Source code for each step. Default: work.&p_prefix._stmts
  @param [in] p_stepsDsName=Step information for each step. Default: work.&p_prefix._steps


  <h4> Data Inputs </h4>
  @li work.&p_prefix._stmts
  @li work.&p_prefix._steps


  <h4> Data Outputs </h4>
  @li work.&p_prefix._exprSql
  @li work.&p_prefix._alias


  @version 9.4
  @author Ahmed Al-Attar
**/

%macro lin_exprSql(p_prefix=lin
, p_stmtsDsName=work.&p_prefix._stmts
, p_stepsDsName=work.&p_prefix._steps);

  PROC SQL;
    CREATE TABLE work._lin_sqlstmts AS
    SELECT a.step, a.stmtno, a.text
    FROM &p_stmtsDsName a
    INNER JOIN &p_stepsDsName b ON a.step = b.step
    WHERE b.procname = 'SQL'
    ORDER BY a.step, a.stmtno;
  QUIT;

  DATA &p_prefix._exprSql (KEEP=step qid toRaw toVar pos kind expr)
       &p_prefix._alias   (KEEP=step qid alias tblRaw);
    SET work._lin_sqlstmts;
    BY step;
    LENGTH toRaw $200 toVar $64 kind $8 expr $4000 alias $64 tblRaw $200
           query seg msk msk2 mk txt selList fromTxt mfrom piece mpiece item mitem rest mrest $32000
           q $1 ch $1 tbl $200 w1 w2 w3 $64 a1_1-a1_200 $64;
    RETAIN qid 0 a1_1-a1_200 '' rxCreate rxInsert rxSet rxSelect rxFrom rxFromEnd rxJoin rxOn rxMod rxAs rxSimple rxInto;
    ARRAY a1 {200} a1_1-a1_200;

    IF (_n_ = 1) THEN
    DO;
      rxCreate  = PRXPARSE('/^create\s+(?:table|view)\s+(\S+?)\s+as\s+(.*)$/i');
      rxInsert  = PRXPARSE('/^insert\s+into\s+(\S+?)(?:\s*\([^)]*\))?\s+(select\b.*)$/i');
      rxSet     = PRXPARSE('/\b(?:union|intersect|except)\b(?:\s+(?:all|distinct|corr|corresponding))*(?:\s+outer)?/i');
      rxSelect  = PRXPARSE('/^\s*select\s+(?:distinct\s+|all\s+|unique\s+)?/i');
      rxFrom    = PRXPARSE('/\sfrom\s/i');
      rxFromEnd = PRXPARSE('/\s(?:where|group\s+by|having|order\s+by)\s/i');
      rxJoin    = PRXPARSE('/,|\b(?:natural\s+)?(?:(?:inner|left|right|full|cross)\s+)?(?:outer\s+)?join\b/i');
      rxOn      = PRXPARSE('/\bon\b/i');
      rxMod     = PRXPARSE('s/\s+(?:label|format|informat|length)\s*=\s*(?:''[^'']*''|"[^"]*"|\S+)//i');
      rxAs      = PRXPARSE('/\s+as\s+(\w+|''[^'']*''n|"[^"]*"n)\s*$/i');
      rxSimple  = PRXPARSE('/^(?:calculated\s+)?(?:\w+\.)?(\w+)$/i');
      rxInto    = PRXPARSE('s/\s+into\s+:.*?(?=\sfrom\s)//i');
    END;
    IF (FIRST.step) THEN
    DO;
      qid = 0;
      DO i = 1 TO 200; a1{i} = ''; END;
    END;

    /* which statement is it? */
    query = '';
    toRaw = '';
    IF (PRXMATCH(rxCreate, text)) THEN
    DO;
      toRaw = PRXPOSN(rxCreate, 1, text);
      query = PRXPOSN(rxCreate, 2, text);
    END;
    ELSE IF (PRXMATCH(rxInsert, text)) THEN
    DO;
      toRaw = PRXPOSN(rxInsert, 1, text);
      query = PRXPOSN(rxInsert, 2, text);
    END;
    IF (MISSING(query) OR NOT PRXMATCH('/^\s*\(?\s*select\b/i', query)) THEN RETURN;
    query = PRXCHANGE(rxInto, 1, query);

    /* mask: quoted text and everything inside parentheses becomes '_' (same length) */
    txt = query; LINK mask; msk = mk;

    /* split on top level set operators; segments are processed in turn */
    segStart = 1;
    segNo    = 0;
    start = 1; stop = LENGTH(msk);
    IF (start > stop) THEN sp = 0;
    ELSE CALL PRXNEXT(rxSet, start, stop, msk, sp, sl);
    DO WHILE (1);
      IF (sp > 0) THEN seg = SUBSTR(query, segStart, sp - segStart);
      ELSE seg = SUBSTR(query, segStart);
      segNo + 1;
      qid   + 1;
      LINK doSegment;
      IF (sp <= 0) THEN LEAVE;
      segStart = sp + sl;
      IF (start > stop) THEN sp = 0;
    ELSE CALL PRXNEXT(rxSet, start, stop, msk, sp, sl);
    END;
    RETURN;

    /* ---------- one SELECT ... FROM ... segment ---------- */
    doSegment:
      seg = STRIP(PRXCHANGE('s/\bouter\s*$//i', 1, STRIP(seg)));
      /* tolerate a segment wrapped in one pair of brackets */
      IF (seg =: '(') THEN
      DO;
        seg = STRIP(SUBSTR(seg, 2));
        IF (SUBSTR(seg, LENGTH(seg)) = ')') THEN seg = STRIP(SUBSTR(seg, 1, LENGTH(seg) - 1));
      END;
      txt = seg; LINK mask; msk2 = mk;

      IF (NOT PRXMATCH(rxSelect, seg)) THEN RETURN;
      CALL PRXSUBSTR(rxSelect, seg, sPos, sLen);
      fp = PRXMATCH(rxFrom, msk2);
      IF (fp = 0) THEN
      DO;  /* no FROM: constants only */
        selList = SUBSTR(seg, sPos + sLen);
        fromTxt = '';
      END;
      ELSE
      DO;
        selList = SUBSTR(seg, sPos + sLen, fp - (sPos + sLen) + 1);
        rest    = SUBSTR(seg, fp + 6);
        mrest   = SUBSTR(msk2, fp + 6);
        ep = PRXMATCH(rxFromEnd, mrest);
        IF (ep > 0) THEN fromTxt = SUBSTR(rest, 1, ep);
        ELSE fromTxt = rest;
      END;

      /* --- tables of the FROM clause --- */
      IF (NOT MISSING(fromTxt)) THEN
      DO;
        txt = fromTxt; LINK mask; mfrom = mk;
        pStart = 1;
        jStart = 1; jStop = LENGTH(mfrom);
        IF (jStart > jStop) THEN jp = 0;
    ELSE CALL PRXNEXT(rxJoin, jStart, jStop, mfrom, jp, jl);
        DO WHILE (1);
          IF (jp > 0) THEN piece = SUBSTR(fromTxt, pStart, jp - pStart);
          ELSE piece = SUBSTR(fromTxt, pStart);
          LINK doPiece;
          IF (jp <= 0) THEN LEAVE;
          pStart = jp + jl;
          IF (jStart > jStop) THEN jp = 0;
    ELSE CALL PRXNEXT(rxJoin, jStart, jStop, mfrom, jp, jl);
        END;
      END;

      /* --- select items --- */
      txt = selList; LINK mask; mitem = mk;
      k = 0; iStart = 1; n = LENGTH(selList);
      DO i = 1 TO n + 1;
        IF (i = n + 1 OR SUBSTR(mitem, i, 1) = ',') THEN
        DO;
          item = STRIP(SUBSTR(selList, iStart, i - iStart));
          iStart = i + 1;
          IF (NOT MISSING(item)) THEN
          DO;
            k + 1;
            LINK doItem;
          END;
        END;
      END;
    RETURN;

    /* ---------- one table of the FROM clause (item in piece) ---------- */
    doPiece:
      piece = STRIP(piece);
      IF (MISSING(piece)) THEN RETURN;
      txt = piece; LINK mask; mpiece = mk;
      onp = PRXMATCH(rxOn, mpiece);
      IF (onp > 0) THEN piece = STRIP(SUBSTR(piece, 1, onp - 1));
      IF (MISSING(piece)) THEN RETURN;
      alias = '';
      IF (piece =: '(') THEN
      DO;  /* sub-query: unknown table, alias follows the closing bracket */
        tbl = '(subquery)';
        d = 0;
        DO j = 1 TO LENGTH(piece);
          ch = SUBSTR(piece, j, 1);
          IF (ch = '(') THEN d + 1;
          ELSE IF (ch = ')') THEN
          DO;
            d + (-1);
            IF (d = 0) THEN LEAVE;
          END;
        END;
        rest = STRIP(SUBSTR(piece, MIN(j + 1, LENGTH(piece) + 1)));
      END;
      ELSE
      DO;
        tbl = SCAN(piece, 1, ' (');
        j = INDEX(piece, STRIP(tbl)) + LENGTH(STRIP(tbl));
        rest = STRIP(SUBSTR(piece, j));
        IF (rest =: '(') THEN
        DO;  /* skip dataset options */
          d = 0;
          DO j = 1 TO LENGTH(rest);
            ch = SUBSTR(rest, j, 1);
            IF (ch = '(') THEN d + 1;
            ELSE IF (ch = ')') THEN
            DO;
              d + (-1);
              IF (d = 0) THEN LEAVE;
            END;
          END;
          rest = STRIP(SUBSTR(rest, MIN(j + 1, LENGTH(rest) + 1)));
        END;
      END;
      w1 = SCAN(rest, 1, ' ');
      w2 = SCAN(rest, 2, ' ');
      IF (LOWCASE(w1) = 'as') THEN alias = w2;
      ELSE IF (NOT MISSING(w1)) THEN alias = w1;
      IF (MISSING(alias) AND tbl NE '(subquery)') THEN alias = SCAN(tbl, -1, '.');
      alias  = UPCASE(alias);
      tblRaw = tbl;
      OUTPUT &p_prefix._alias;
      /* a table can also be referred to by its own name */
      IF (tbl NE '(subquery)' AND UPCASE(SCAN(tbl, -1, '.')) NE alias) THEN
      DO;
        alias = UPCASE(SCAN(tbl, -1, '.'));
        OUTPUT &p_prefix._alias;
      END;
    RETURN;

    /* ---------- one select item (text in item, position k) ---------- */
    doItem:
      item = PRXCHANGE(rxMod, -1, item);
      item = STRIP(item);
      alias = '';
      IF (PRXMATCH(rxAs, item)) THEN
      DO;
        alias = PRXPOSN(rxAs, 1, item);
        /* name literal: 'my col'n  ->  my col */
        IF (PRXMATCH('/^["'']/', alias)) THEN alias = PRXCHANGE('s/^["'']([^"'']*)["'']n$/$1/i', 1, alias);
        CALL PRXSUBSTR(rxAs, item, ap, al);
        expr = STRIP(SUBSTR(item, 1, ap - 1));
      END;
      ELSE
      DO;
        expr = item;
        IF (PRXMATCH(rxSimple, item)) THEN alias = PRXPOSN(rxSimple, 1, item);
      END;
      /* SELECT * and a.* are covered by name matching */
      IF (expr = '*' OR PRXMATCH('/\.\s*\*$/', expr)) THEN RETURN;

      IF (segNo = 1) THEN
      DO;
        IF (k <= 200) THEN a1{k} = alias;
      END;
      ELSE IF (k <= 200) THEN alias = a1{k};

      toVar = alias;
      pos   = k;
      kind  = 'EXPR';
      OUTPUT &p_prefix._exprSql;
    RETURN;

    /* ---------- mask: txt -> mk ---------- */
    mask:
      mk = txt;
      q  = '';
      d  = 0;
      DO m = 1 TO LENGTH(txt);
        ch = SUBSTR(txt, m, 1);
        IF (q NE '') THEN
        DO;
          IF (ch = q) THEN q = '';
          SUBSTR(mk, m, 1) = '_';
        END;
        ELSE IF (ch IN ("'", '"')) THEN
        DO;
          q = ch;
          SUBSTR(mk, m, 1) = '_';
        END;
        ELSE IF (ch = '(') THEN
        DO;
          d + 1;
          SUBSTR(mk, m, 1) = '_';
        END;
        ELSE IF (ch = ')') THEN
        DO;
          d + (-1);
          SUBSTR(mk, m, 1) = '_';
        END;
        ELSE IF (d > 0) THEN SUBSTR(mk, m, 1) = '_';
      END;
    RETURN;
  RUN;

  PROC DATASETS LIB=WORK NOLIST NOWARN;
    DELETE _lin_sqlstmts;
  RUN; QUIT;

%mend lin_exprSql;
