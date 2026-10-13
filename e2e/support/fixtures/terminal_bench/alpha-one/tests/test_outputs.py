import subprocess


def test_answer_counts_the_lines():
    out = subprocess.run(["python3", "/app/answer.py"], capture_output=True, text=True, check=True).stdout
    assert out.strip() == "3"
