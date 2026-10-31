#!/usr/bin/env python3
"""
Run the lineage macros over a folder of SCAPROC *.txt files on SAS (via SASPy) and bring the
results back to a local folder.

Usage:
  python run_lineage.py --logs <folder with *.txt> --out <local output folder> [--attrs] [--no-steps]
                        [--no-column-dag] [--json] [--rank-dir LR]

For every <name>.txt it writes <out>/<name>/<name>_dataset.dot, <name>_column.dot (plus <name>_dataset_attrs.dot with --attrs) and three *.csv
files; <out>/lineage_summary.csv lists one row per log. If Graphviz ('dot') is on the PATH the
*.dot files are also rendered to *.svg.

Environment:
  SASPY_HELPERS  folder containing connect_saspy.py (default: D:\\Projects\\Python\\saspy_helpers)
  SAS_LIN_DIR    remote scratch folder (default: ~/scaLineage)
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HELPERS = os.environ.get("SASPY_HELPERS", r"D:\Projects\Python\saspy_helpers")
sys.path.insert(0, HELPERS)

ROOT = Path(__file__).resolve().parent
MACROS = ROOT / "code" / "macros"
ORDER = [
    "lin_readLog", "lin_prepSource", "lin_exprDataStep", "lin_exprSql", "lin_tokenize",
    "lin_buildLineage", "lin_writeDag", "lin_writeJson", "lin_processLog", "lin_runAll",
]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--logs", required=True, help="folder holding the SCAPROC *.txt files")
    ap.add_argument("--out", default=str(ROOT / "output"), help="local output folder")
    ap.add_argument("--ext", default="txt", help="extension of the log files (default txt)")
    ap.add_argument("--attrs", action="store_true", help="list the columns inside the data set nodes")
    ap.add_argument("--no-steps", action="store_true", help="leave the processing steps out of the dataset DAG")
    ap.add_argument("--no-column-dag", action="store_true", help="skip the column level DAG")
    ap.add_argument("--json", action="store_true", help="also write <name>.json (nodes / edges of both levels)")
    ap.add_argument("--rank-dir", default="LR", choices=["TB", "BT", "LR", "RL"])
    args = ap.parse_args()

    logs = Path(args.logs)
    files = sorted(p for p in logs.iterdir() if p.is_file() and p.suffix.lower() == "." + args.ext.lower())
    empty = [p for p in files if p.stat().st_size == 0]
    files = [p for p in files if p.stat().st_size > 0]
    for p in empty:
        print(f"Skipping empty file {p.name}")
    if not files:
        print(f"No non-empty *.{args.ext} files in {logs}", file=sys.stderr)
        return 1

    import connect_saspy  # noqa: E402  (auto-connects on import)

    sas = connect_saspy.get_connection()._sas_session
    if sas is None:
        print("Could not connect to SAS", file=sys.stderr)
        return 1

    try:
        home = re.search(r"^HOME=([^\s;]+)", sas.submit("%put HOME=%sysfunc(sysget(HOME));")["LOG"], re.M).group(1)
        remote = os.environ.get("SAS_LIN_DIR", f"{home}/scaLineage")
        # every run uses its own logs / out folders, so old results cannot leak into this run
        stamp = time.strftime("%Y%m%d_%H%M%S")
        remote_logs = f"{remote}/logs_{stamp}"
        remote_out = f"{remote}/out_{stamp}"
        sas.submit(
            "options dlcreatedir;"
            + "".join(f"libname _t '{d}'; libname _t clear;" for d in (remote, f"{remote}/code", remote_logs, remote_out))
        )
        for name in ORDER:
            sas.upload(str(MACROS / f"{name}.sas"), f"{remote}/code/{name}.sas", overwrite=True)
        for p in files:
            sas.upload(str(p), f"{remote_logs}/{p.name}", overwrite=True)

        includes = "".join(f'%include "{remote}/code/{n}.sas";\n' for n in ORDER)
        flag = lambda b: "Y" if b else "N"  # noqa: E731
        log = sas.submit(
            includes
            + f"%lin_runAll(p_logDir={remote_logs}, p_outDir={remote_out}, p_ext={args.ext},"
            f" p_attrs_yn={flag(args.attrs)}, p_includeSteps_yn={flag(not args.no_steps)},"
            f" p_columnDag_yn={flag(not args.no_column_dag)}, p_rankDir={args.rank_dir}, p_json_yn={flag(args.json)})\n"
        )["LOG"]
        problems = [l for l in log.splitlines() if re.match(r"(ERROR|WARNING)\b", l)]
        for l in dict.fromkeys(problems):
            print(l)

        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        remote_files = []
        for item in sas.dirlist(remote_out) or []:
            if item.endswith("/"):
                remote_files += [f"{item}{sub}" for sub in sas.dirlist(f"{remote_out}/{item}") or []]
            else:
                remote_files.append(item)
        for rel in remote_files:
            dest = out / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            sas.download(str(dest), f"{remote_out}/{rel}")
        print(f"Downloaded {len(remote_files)} files to {out}")
    finally:
        connect_saspy.close_connection()

    dot = shutil.which("dot")
    if dot:
        for f in out.rglob("*.dot"):
            subprocess.run([dot, "-Tsvg", str(f), "-o", str(f.with_suffix(".svg"))], check=False)
        print("Rendered *.dot to *.svg with Graphviz")
    else:
        print("Graphviz 'dot' not found: render the *.dot files with  dot -Tsvg x.dot -o x.svg")
    return 0


if __name__ == "__main__":
    sys.exit(main())
