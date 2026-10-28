/**
  @file lin_exprDataStep.sas
  @brief Extracts column derivations from the recorded source of DATA steps.
  @details Looks at the statements of every DATASTEP step (see %lin_prepSource) and creates

    &p_prefix._exprDs   step, qid(=0), toRaw(blank = every output), fromRaw, toVar, pos, kind, expr

  kind:
    EXPR    assignment (x = expr;) or sum statement (x + expr;); expr holds the right hand side
    RENAME  rename=(old=new) option or RENAME statement; toVar = new name, expr = old name;
            fromRaw = data set the rename= option is attached to (blank for a RENAME statement)
    INPUT   variable read by an INPUT statement (comes from the INFILE / in-stream data)

  Leading IF ... THEN / ELSE / WHEN / OTHERWISE clauses are removed so the assignment behind them
  is still seen. Conditions are not treated as sources (data lineage, not control lineage).

  @param [in] p_prefix= Prefix of the WORK tables. Default:lin.

  @version 9.4
  @author Ahmed Al-Attar
**/
%macro lin_exprDataStep(p_prefix=lin);

  PROC SQL;
    CREATE TABLE work._lin_dsstmts AS
    SELECT a.step, a.stmtno, a.text
    FROM &p_prefix._stmts a
    INNER JOIN &p_prefix._steps b ON a.step = b.step
    WHERE b.procname = 'DATASTEP'
    ORDER BY a.step, a.stmtno;
  QUIT;

  DATA &p_prefix._exprDs (KEEP=step qid toRaw fromRaw toVar pos kind expr);
    SET work._lin_dsstmts;
    LENGTH s prev $4000 toRaw fromRaw $200 toVar $64 kind $8 expr $4000 inner $4000 tok $200 old new $64;
    RETAIN qid 0 rxIf rxElse rxWhen rxAssign rxSum rxRen rxRen1 rxDo rxRenSt rxLit1 rxLit2;
    IF (_n_ = 1) THEN
    DO;
      rxIf     = PRXPARSE('s/^\s*if\b.*?\bthen\b\s*//i');
      rxElse   = PRXPARSE('s/^\s*else\b\s*//i');
      rxWhen   = PRXPARSE('s/^\s*(when\s*\(.*?\)|otherwise)\b\s*//i');
      rxAssign = PRXPARSE('/^([A-Za-z_]\w*)\s*(?:[\[{(][^\]})]*[\]})])?\s*=\s*(.*)$/');
      rxSum    = PRXPARSE('/^([A-Za-z_]\w*)\s*\+\s*([^=].*)$/');
      rxRen    = PRXPARSE('/([A-Za-z_][\w.&]*)\s*\((?:[^()]|\([^()]*\))*?\brename\s*=\s*\(([^)]*)\)/i');
      rxDo     = PRXPARSE('/^do\s+([A-Za-z_]\w*)\s*=\s*(.*)$/i');
      rxRen1   = PRXPARSE('s/\brename\s*=\s*([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)/rename=($1=$2)/i');
      rxLit1   = PRXPARSE("s/'[^']*'/''/");
      rxLit2   = PRXPARSE('s/"[^"]*"/""/');
    END;

    toRaw   = '';
    fromRaw = '';
    pos     = .;

    /* a. rename= options anywhere in the statement (data / set / merge / update) */
    s = text;
    CALL PRXCHANGE(rxLit1, -1, s);
    CALL PRXCHANGE(rxLit2, -1, s);
    CALL PRXCHANGE(rxRen1, -1, s);            /* rename=old=new  ->  rename=(old=new) */
    start = 1;
    stop  = LENGTH(s);
    IF (start > stop) THEN p = 0;
    ELSE CALL PRXNEXT(rxRen, start, stop, s, p, l);
    DO WHILE (p > 0);
      fromRaw = PRXPOSN(rxRen, 1, s);
      inner   = PRXPOSN(rxRen, 2, s);
      inner = PRXCHANGE('s/\s*=\s*/=/', -1, inner);
      DO i = 1 TO COUNTW(inner, ' ');
        tok = SCAN(inner, i, ' ');
        old = SCAN(tok, 1, '=');
        new = SCAN(tok, 2, '=');
        IF (NOT MISSING(old) AND NOT MISSING(new)) THEN
        DO;
          toVar = new; kind = 'RENAME'; expr = old; OUTPUT;
        END;
      END;
      IF (start > stop) THEN p = 0;
    ELSE CALL PRXNEXT(rxRen, start, stop, s, p, l);
    END;
    fromRaw = '';

    /* b. peel off IF-THEN / ELSE / WHEN / OTHERWISE prefixes */
    prev = '*';
    DO WHILE (s NE prev);
      prev = s;
      CALL PRXCHANGE(rxIf,   1, s);
      CALL PRXCHANGE(rxElse, 1, s);
      CALL PRXCHANGE(rxWhen, 1, s);
    END;
    s = STRIP(s);

    /* c. statements */
    IF (s =: 'rename ' OR s =: 'RENAME ') THEN
    DO;
      inner = PRXCHANGE('s/\s*=\s*/=/', -1, STRIP(SUBSTR(s, 7)));
      DO i = 1 TO COUNTW(inner, ' ');
        tok = SCAN(inner, i, ' ');
        old = SCAN(tok, 1, '=');
        new = SCAN(tok, 2, '=');
        IF (NOT MISSING(old) AND NOT MISSING(new)) THEN
        DO;
          toVar = new; kind = 'RENAME'; expr = old; OUTPUT;
        END;
      END;
    END;
    ELSE IF (LOWCASE(SCAN(s, 1, ' ')) = 'input') THEN
    DO;
      DO i = 2 TO COUNTW(s, ' ');
        tok = SCAN(s, i, ' ');
        IF (PRXMATCH('/^[A-Za-z_]\w*$/', STRIP(tok))) THEN
        DO;
          toVar = tok; kind = 'INPUT'; expr = ''; OUTPUT;
        END;
      END;
    END;
    ELSE IF (PRXMATCH(rxDo, s)) THEN
    DO;
      /* DO var = start TO stop BY step: the index variable is derived from its bounds */
      toVar = PRXPOSN(rxDo, 1, s);
      expr  = STRIP(PRXPOSN(rxDo, 2, s));
      /* TO / BY are keywords, not columns; a WHILE / UNTIL condition is not a source */
      expr  = STRIP(PRXCHANGE('s/\s+(?:while|until)\s*\(.*$//i', -1, expr));
      expr  = PRXCHANGE('s/\s+(?:to|by)\s+/, /i', -1, expr);
      kind  = 'EXPR';
      OUTPUT;
    END;
    ELSE IF (PRXMATCH(rxAssign, s)) THEN
    DO;
      toVar = PRXPOSN(rxAssign, 1, s);
      expr  = STRIP(PRXPOSN(rxAssign, 2, s));
      kind  = 'EXPR';
      OUTPUT;
    END;
    ELSE IF (PRXMATCH(rxSum, s)) THEN
    DO;
      toVar = PRXPOSN(rxSum, 1, s);
      expr  = CATX(' ', toVar, PRXPOSN(rxSum, 2, s));
      kind  = 'EXPR';
      OUTPUT;
    END;
  RUN;

  PROC DATASETS LIB=WORK NOLIST NOWARN;
    DELETE _lin_dsstmts;
  RUN; QUIT;

%mend lin_exprDataStep;
