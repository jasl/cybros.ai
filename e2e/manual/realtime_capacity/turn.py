"""One local Pion TURN process; one load-generator process per tier."""
import json
import os
import subprocess
import time
from pathlib import Path

root = Path(__file__).resolve().parent
output = root.parent.parent / "artifacts" / "realtime_capacity"
with (output / "turn-server.log").open("w") as log:
    server = subprocess.Popen(
        [str(output / "turn")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=log, text=True,
    )
    try:
        url = server.stdout.readline().strip()
        if not url.startswith("turn:"):
            raise RuntimeError("TURN server did not start")
        address = url.removeprefix("turn:").split("?")[0]
        for count in map(int, os.environ.get("CAPACITY_TIERS", "1,10,50,100,200,400,800").split(",")):
            report = output / f"turn-{count}-{int(time.time())}.json"
            subprocess.run([
                "python3", str(root / "measure.py"), "--server", str(server.pid),
                "--output", str(report), "--", str(output / "load"), "-mode", "turn",
                "-address", address, "-count", str(count),
                "-duration", os.environ.get("CAPACITY_SECONDS", "20")+"s",
            ], check=True)
            result = json.loads(report.read_text())
            delivered = result["received_packets"] / max(1, result["sent_packets"])
            offered = result["sent_packets"]*9600/result["duration_seconds"]/1e6
            if result["errors"] or delivered < 0.99 or result["p99_ms"] >= 100 or offered < count*0.99:
                break
    finally:
        server.stdin.close()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
