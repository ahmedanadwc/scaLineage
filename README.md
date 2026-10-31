# scaLineage

Extract **data / column lineage** from SAS Code Analyzer (`PROC SCAPROC`) recordings and draw a **DAG** for every recording.

Give it a folder of `*.txt` recordings. For each one it writes, into a sub-folder named after the file:

| File | What it is |
|---|---|
| `<name>_dataset.dot` | Data set level DAG: files, data set versions and processing steps (with run times). No columns; with `p_attrs_yn=Y` / `--attrs` the graph label says "Click here to see Column attributes" and links to `<name>_dataset_attrs.svg` |
| `<name>_dataset_attrs.dot` | Only with `p_attrs_yn=Y` / `--attrs`: the same DAG with the columns listed inside the data set nodes. The graph label says "Click here to see Column lineage" and links to `<name>_column.svg` |
| `<name>_column.dot` | Column level DAG: one box per column, one cluster per data set, one arrow per lineage edge |
| `<name>_column_lineage.csv` | One row per column edge (step, method, from data set / version / column, to data set / version / column, expression) |
| `<name>_dataset_lineage.csv` | One row per step input / output (data sets with version, and files) |
| `<name>_steps.csv` | One row per step (proc, elapsed, duration) |
| `<name>.json` | Optional (`p_json_yn=Y` / `--json`): node / edge graph with both levels, see below |

`lineage_summary.csv` (one row per recording) is written next to the sub-folders.

Render the `.dot` files with Graphviz: `dot -Tsvg x_column.dot -o x_column.svg`. The links inside the DAGs point to the `.svg` files next to them, so render all of them (`run_lineage.py` does) and open the `.svg` to click through.

The DOT output is plain and portable: no global `node [...]` defaults in the data set DAG, every node carries its own shape and colour, and there is one `"a" -> "b"` statement per edge (no `{a b} -> {c}` set syntax). It is the same form as the SIMPLE theme of the older dotMySASProgram tool, so there is no theme option.

## JSON graph

`%lin_processLog(..., p_json_yn=Y)` (and `%lin_runAll(..., p_json_yn=Y)`) also writes `<name>.json`: one graph holding both levels, so a consumer filters on `"level"`.

| | Fields |
|---|---|
| node | `id`, `label`, `type` (`dataset`, `file`, `step`, `column`), `level` (`dataset` or `column`); data sets also `columns` (with `p_attrs_yn=Y`); steps `step`, `seconds`; columns `dataset` (id of the data set node) `unresolved: true` (step has source, column not traced) or `nosource: true` (step has no recorded source) |
| edge, level `dataset` | `source`, `target`, `type` (`input`, `output`, or `flow` without step nodes), `step`: same `source` / `target` / `type` shape as the older dotMySASProgram JSON |
| edge, level `column` | `source`, `target`, `type: "column"`, `method` (`EXPR`, `RENAME`, `NAME`, `FILE`, `INPUT`, `CONST`), `step`, `expr` |

Node ids are the ids used in the DOT files.

## Record the programs correctly

The column lineage needs the `ATTR` records. `%lin_startRecord` / `%lin_stopRecord` always record with `ATTR OPENTIMES EXPANDMACROS`:

```sas
%lin_startRecord(p_outFile=%str(~/logs/my_program.txt))
/* ... your program ... */
%lin_stopRecord
```

Or record by hand with the same options:

```sas
proc scaproc;
  record "~/logs/my_program.txt" attr opentimes expandmacros;
run;
/* ... your program ... */
proc scaproc;
  write;
run;
```

A recording without `ATTR` records still gets a data set level DAG, but a warning is written and no columns can be traced.

## Run it

**From SAS** (edit the paths first): `programs/usage_lin_runAll.sas`

```sas
%lin_runAll(p_logDir=~/scaLineage/logs, p_outDir=~/scaLineage/output, p_attrs_yn=Y)
%lin_processLog(p_inFile=~/scaLineage/logs/x.txt, p_outDir=~/scaLineage/output)   /* one file */
```

**From Windows, against SAS ODA via SASPy.** It needs a Python with `saspy` installed and `connect_saspy.py` (folder in `SASPY_HELPERS`, default `D:\Projects\Python\saspy_helpers`). The conda environment `sas_python2` has both:

```
D:\Projects\Python\envs\sas_python2\python.exe run_lineage.py --logs "C:\path\to\logs" --out "D:\Projects\SAS\scaLineage\output" --attrs
```

The macros use only SAS 9.4 syntax and take every path as a parameter (Unix or Windows style), so they also run on a 9.4 install; the test suite is run on SAS ODA only.

It uploads the macros and the logs, runs `%lin_runAll`, and downloads the results. If Graphviz (`dot`) is on the PATH the `.dot` files are also rendered to `.svg`.
Options: `--attrs` (list columns inside the data set nodes), `--no-steps`, `--no-column-dag`, `--json`, `--rank-dir TB|BT|LR|RL`, `--ext txt`.
Empty files are skipped.

## How the lineage is derived

SCAPROC records which data sets and files each step read and wrote, and the columns it used (`ATTR` records), but **not which input column feeds which output column**. The macros combine those facts with the source SCAPROC stores for each step:

| Method | Meaning |
|---|---|
| `EXPR` | Derived by an expression: a DATA step assignment / sum statement, or a PROC SQL select item. Table aliases, joins, `CASE`, `CALCULATED`, `UNION` (matched by position) and assignments that use earlier derived columns (`y = x * 2` after `x = a + b`) are followed. |
| `RENAME` | `rename=(old=new)` option or `RENAME` statement |
| `NAME` | Same column name in an input of the step (pass-through, `SELECT *`, PROC SORT / APPEND / SUMMARY output, ...). It is the only evidence for steps that have no recorded source (steps generated by a macro). |
| `FILE` | Read from an external file (PROC IMPORT) |
| `INPUT` | Read by an `INPUT` statement from an `INFILE` or in-stream data (`DATALINES`) |
| `CONST` | Expression without any column (a literal, a function of constants) |
| `AUTO` | Automatic column of PROC SUMMARY / MEANS (`_FREQ_`, `_TYPE_`) |
| `NOSOURCE` | The step has no recorded source (code that is included from a file or generated by `CALL EXECUTE`) and the column is in no input. Drawn with an orange outline; a warning is written. Submit the code directly when recording to avoid it |
| `UNRESOLVED` | The step has source, but nothing in it says where the column came from (drawn with a red outline) |

A data set that is written more than once is shown once per **version** (`WORK.ONE (v2)`), so a step that reads and rewrites the same table (`PROC SORT`) does not create a cycle.

### Limits

- Lineage comes from the *text* of each step. Hash objects, arrays, `CALL EXECUTE`, dynamic code, sub-queries in a `FROM` clause and macro-generated steps are only partly traceable; the affected columns fall back to `NAME`, `NOSOURCE` or `UNRESOLVED`.
- `lineage_summary.csv` reports `unresolved` and `noSource` separately, plus `unresPct`: unresolved as a percentage of the column edges of steps that have recorded source.
- Conditions (`IF ... THEN`) are not treated as sources, only the value assigned.
- Library names are taken from the recording; an unqualified table in SQL source is matched to the data set the step actually read or wrote.

## Layout

```
code/macros/    lin_startRecord / lin_stopRecord (record), then
                lin_readLog -> lin_prepSource -> lin_exprDataStep + lin_exprSql -> lin_tokenize
                -> lin_buildLineage -> lin_writeDag + lin_writeJson, driven by lin_processLog (one log)
                and lin_runAll (a folder)
programs/       usage_lin_runAll.sas
tests/          run_tests.py (runs tests/sas/test_lineage.sas on SAS and reports PASS/FAIL)
tests/golden/   two real recordings and their expected *_column_lineage.csv
run_lineage.py  run the whole thing against SAS ODA from Windows
```

| Macro | Purpose |
|---|---|
| `%lin_startRecord`, `%lin_stopRecord` | Start / finish the SCAPROC recording with the options the lineage needs |
| `%lin_readLog` | Parse one recording into steps, data set / file I/O, column attributes and step source |
| `%lin_prepSource` | Split each step's source into statements |
| `%lin_exprDataStep`, `%lin_exprSql` | Find the derivation expressions of DATA steps / PROC SQL |
| `%lin_tokenize` | Find the column references inside each expression |
| `%lin_buildLineage` | Resolve references against the recorded columns, add versions |
| `%lin_writeJson` | Write the node / edge JSON graph of both levels |
| `%lin_writeDag` | Write the dataset and column DOT files |
| `%lin_processLog` | The chain above plus the CSV files, for one recording |
| `%lin_runAll` | `%lin_processLog` for every file in a folder |

## Tests

`python tests/run_tests.py` (same Python as above) records real SCAPROC output of small programs on SAS (DATA step, PROC SQL, in-place sort, files, SASHELP, included code), checks the lineage tables, the DOT and JSON output (every edge endpoint has a node), the whole-folder run, and two golden recordings: the column lineage of `tests/golden/*.txt` must equal the committed `*_column_lineage.csv`. After a deliberate change of the lineage rules, regenerate those CSVs with `run_lineage.py` and review the diff.

Environment variables: `SASPY_HELPERS`, `SAS_TEST_DIR` (remote scratch folder), `LIN_TEST_LOG` (write the full SAS log there).
