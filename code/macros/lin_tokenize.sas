/**
  @file lin_tokenize.sas
  @brief Turns the derivation expressions into column references.
  @details Reads &p_prefix._exprDs and &p_prefix._exprSql and creates

    &p_prefix._eexpr eid, step, qid, toRaw, toVar, pos, kind, expr   one row per expression
    &p_prefix._ref   eid, qual, ident, calc                           one row per column reference

  An expression is the right hand side of one assignment or select item. A reference is a column
  name used inside it. Quoted strings, function calls
  (name followed by a bracket), formats (name followed by a dot), macro variables, numbers and
  language keywords are not references. 'alias.column' keeps the alias in QUAL, and a column that
  follows the SQL keyword CALCULATED has CALC=1. RENAME rows give one reference to the old name; its QUAL is the data set of the rename= option.

  @param [in] p_prefix= Prefix of the WORK tables. Default:lin.

  @version 9.4
  @author Ahmed Al-Attar
**/
%macro lin_tokenize(p_prefix=lin);

  DATA &p_prefix._eexpr (KEEP=eid step qid toRaw toVar pos kind expr)
       &p_prefix._ref   (KEEP=eid qual ident calc);
    LENGTH fromRaw $200;
    SET &p_prefix._exprDs &p_prefix._exprSql;
    LENGTH e $4000 qual ident $64 nc pc $1 kw $600;
    RETAIN rxLit1 rxLit2 rxTok kw;
    IF (_n_ = 1) THEN
    DO;
      rxLit1 = PRXPARSE("s/'[^']*'/ /");
      rxLit2 = PRXPARSE('s/"[^"]*"/ /');
      rxTok  = PRXPARSE('/(?:([A-Za-z_]\w*)\s*\.\s*)?([A-Za-z_]\w*)/');
      kw = 'AND OR NOT IN IS NULL MISSING LIKE BETWEEN DISTINCT FROM SELECT ALL ANY EXISTS SOME CASE WHEN THEN ELSE END AS '
        || 'TRUE FALSE IF DO TO BY WHILE UNTIL EQ NE LT GT LE GE _N_ _ERROR_ _ALL_ _CHARACTER_ _NUMERIC_ _TEMPORARY_ '
        || 'CONTAINS ASC DESC OF ESCAPE OUTER INNER LEFT RIGHT FULL JOIN ON WHERE GROUP ORDER HAVING UNION';
    END;

    eid = _n_;
    OUTPUT &p_prefix._eexpr;
    calc = 0;
    qual = '';
    IF (kind = 'RENAME') THEN
    DO;
      ident = expr;
      qual  = fromRaw;                         /* data set carrying the rename= option, if known */
      OUTPUT &p_prefix._ref;
      RETURN;
    END;
    IF (kind NE 'EXPR') THEN RETURN;

    e = expr;
    CALL PRXCHANGE(rxLit1, -1, e);
    CALL PRXCHANGE(rxLit2, -1, e);
    start = 1;
    stop  = LENGTH(e);
    calcNext = 0;
    IF (start > stop) THEN p = 0;
    ELSE CALL PRXNEXT(rxTok, start, stop, e, p, l);
    DO WHILE (p > 0);
      qual  = PRXPOSN(rxTok, 1, e);
      ident = PRXPOSN(rxTok, 2, e);
      j = p + l;
      DO WHILE (j <= stop AND SUBSTR(e, j, 1) = ' '); j + 1; END;
      nc = '';
      IF (j <= stop) THEN nc = SUBSTR(e, j, 1);
      pc = '';
      IF (p > 1) THEN pc = SUBSTR(e, p - 1, 1);
      use = 1;
      IF (pc IN ('&', ':') OR (pc >= '0' AND pc <= '9')) THEN use = 0;
      ELSE IF (nc = '(') THEN use = 0;                          /* function call / array element */
      ELSE IF (nc = '.' AND MISSING(qual)) THEN use = 0;        /* format such as z4. or first. */
      ELSE IF (MISSING(qual) AND UPCASE(ident) = 'CALCULATED') THEN
      DO;
        use = 0;
        calcNext = 1;
      END;
      ELSE IF (MISSING(qual) AND FINDW(kw, STRIP(ident), ' ', 'it') > 0) THEN use = 0;
      IF (use) THEN
      DO;
        IF (UPCASE(qual) IN ('FIRST', 'LAST')) THEN qual = '';
        calc = calcNext;
        OUTPUT &p_prefix._ref;
        calcNext = 0;
      END;
      IF (start > stop) THEN p = 0;
    ELSE CALL PRXNEXT(rxTok, start, stop, e, p, l);
    END;
  RUN;

%mend lin_tokenize;
