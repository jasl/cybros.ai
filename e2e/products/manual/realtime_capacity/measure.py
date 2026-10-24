"""Sample only the owned server/generator processes while running one tier."""
import argparse
import json
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--server", type=int, required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--database", action="append", default=[])
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command
if command[0] == "--":
    command = command[1:]
samples = []
descriptors = {}
database_samples = []
with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as child:
    while child.poll() is None:
        result = subprocess.run(
            ["ps", "-p", f"{args.server},{child.pid}", "-o", "pid=,time=,rss=,%cpu="],
            capture_output=True, text=True, check=True,
        )
        samples.append({"at": time.monotonic(), "processes": result.stdout.strip()})
        if args.database and len(samples) % 5 == 0:
            if not all(name.startswith("cybros_nexus_") and "_e2e_" in name and
                       all(c.isalnum() or c == "_" for c in name) for name in args.database):
                raise ValueError("database diagnostics require isolated E2E names")
            query = ("SELECT pid,state,wait_event_type,wait_event FROM pg_stat_activity WHERE datname IN (" +
                     ",".join("'" + name + "'" for name in args.database) + ")")
            activity = subprocess.run(["psql", "-d", "postgres", "-At", "-c", query],
                                      capture_output=True, text=True, check=True).stdout
            pids = [line.split("|")[0] for line in activity.splitlines()]
            if pids:
                processes = subprocess.run(["ps", "-p", ",".join(pids), "-o", "pid=,time=,rss="],
                                           capture_output=True, text=True, check=True).stdout
                database_samples.append({"at": time.monotonic(), "activity": activity, "processes": processes})
        if len(samples) == 7:
            for role, pid in [("server", args.server), ("generator", child.pid)]:
                listing = subprocess.run(["lsof", "-a", "-p", str(pid), "-F", "f"],
                                         capture_output=True, text=True)
                descriptors[role] = sum(line[1:].isdigit() for line in listing.stdout.splitlines() if line.startswith("f"))
        time.sleep(1)
    output = child.stdout.read()
    if child.returncode:
        raise SystemExit(child.returncode)
    report = json.loads(output)
    report["server_pid"] = args.server
    report["generator_pid"] = child.pid
    report["process_samples"] = samples
    report["open_fds_sample"] = descriptors
    report["database_samples"] = database_samples
    for role, pid in [("server", args.server), ("generator", child.pid)]:
        rows = []
        for sample in samples:
            for line in sample["processes"].splitlines():
                fields = line.split()
                if int(fields[0]) == pid:
                    minutes, seconds = fields[1].split(":")
                    rows.append((sample["at"], int(minutes)*60+float(seconds), int(fields[2])))
        if len(rows) > 1:
            report[f"{role}_cpu_percent"] = 100*(rows[-1][1]-rows[0][1])/(rows[-1][0]-rows[0][0])
            report[f"{role}_peak_rss_mib"] = max(row[2] for row in rows)/1024
    Path(args.output).write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ("process_samples", "database_samples")}), flush=True)
