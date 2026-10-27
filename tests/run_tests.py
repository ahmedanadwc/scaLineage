#!/usr/bin/env python3
r"""
Run the SAS regression tests for the lineage macros over SASPy.

Usage:  python tests/run_tests.py

Environment:
  SASPY_HELPERS  folder containing connect_saspy.py (default: D:\Projects\Python\saspy_helpers)
  SAS_TEST_DIR   remote scratch folder (default: ~/scaLineage_tests)
  LIN_TEST_LOG   optional path: the full SAS log is written there

Exit code: 0 when every assertion passes, 1 otherwise.
"""
import os
import re
import sys
from pathlib import Path

HELPERS = os.environ.get("SASPY_HELPERS", r"D:\Projects\Python\saspy_helpers")
sys.path.insert(0, HELPERS)
import connect_saspy  # noqa: E402  (auto-connects on import)

ROOT = Path(__file__).resolve().parent.parent
MACROS = ROOT / "code" / "macros"
TESTS = ROOT / "tests" / "sas"
MACRO_FILES = [
    "lin_startRecord", "lin_stopRecord",
    "lin_readLog", "lin_prepSource", "lin_exprDataStep", "lin_exprSql", "lin_tokenize",
    "lin_buildLineage", "lin_writeDag", "lin_processLog", "lin_runAll",
]
TEST_FILES = ["test_framework.sas", "test_lineage.sas"]


def main() -> int:
    sas = connect_saspy.get_connection()._sas_session
    if sas is None:
        print("Could not connect to SAS", file=sys.stderr)
        return 1
    try:
        home = re.search(r"^HOME=([^\s;]+)", sas.submit("%put HOME=%sysfunc(sysget(HOME));")["LOG"], re.M).group(1)
        remote = os.environ.get("SAS_TEST_DIR", f"{home}/scaLineage_tests")
        remote_code = f"{remote}/code"
        sas.submit(
            f"options dlcreatedir; libname _t '{remote}'; libname _t clear;"
            f"libname _t '{remote_code}'; libname _t clear;"
        )
        for name in MACRO_FILES:
            sas.upload(str(MACROS / f"{name}.sas"), f"{remote_code}/{name}.sas", overwrite=True)
        for name in TEST_FILES:
            sas.upload(str(TESTS / name), f"{remote}/{name}", overwrite=True)

        # SCAPROC only records the source of code that is submitted directly (not %include'd), so the test
        # file is submitted chunk by chunk, split at the SUBMIT marker lines
        chunks = (TESTS / "test_lineage.sas").read_text(encoding="utf-8").split("/*@@SUBMIT*/")
        log = sas.submit(
            "ods html5 (id=saspy_internal) close; ods listing;\n"
            f"%let g_codeRoot={remote_code}; %let g_testRoot={remote};\n"
        )["LOG"]
        for chunk in chunks:
            log += sas.submit(chunk.replace("&g_testRoot/test_framework.sas", f"{remote}/test_framework.sas"))["LOG"]
    finally:
        connect_saspy.close_connection()

    if os.environ.get("LIN_TEST_LOG"):
        Path(os.environ["LIN_TEST_LOG"]).write_text(log, encoding="utf-8")
    passed = re.findall(r"^TEST_PASS: (.+)$", log, re.M)
    failed = re.findall(r"^TEST_FAIL: (.+)$", log, re.M)
    # F3 deliberately feeds an empty file and expects this one warning
    expected = re.compile(r"WARNING: lin_processLog: .*holds no SCAPROC steps")
    problems = [l for l in log.splitlines() if re.match(r"(ERROR|WARNING)\b", l) and not expected.search(l)]
    done = "TEST_DONE" in log

    for name in passed:
        print(f"PASS  {name}")
    for name in failed:
        print(f"FAIL  {name}")
    for line in list(dict.fromkeys(problems))[:20]:
        print(f"LOG   {line}")
    print(f"\n{len(passed)} passed, {len(failed)} failed, {len(problems)} ERROR/WARNING log lines")
    if not done:
        print("Test program did not reach TEST_DONE", file=sys.stderr)
    return 0 if (done and not failed and not problems) else 1


if __name__ == "__main__":
    sys.exit(main())
