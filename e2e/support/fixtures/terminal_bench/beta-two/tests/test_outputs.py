import os


def test_report_exists():
    assert os.path.exists("/app/report.txt")
