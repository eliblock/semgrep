import json
import os
import sys
from pathlib import Path
from typing import List

import requests


def send_comment(message: str, github_token: str, pull_request_number: str) -> None:
    """

    Assumes commithash is in GITHUB_EVENT_PATH file at obj["pull_request"]["head"]["sha"]

    If pull_request_number is "" then does nothing
    """
    if pull_request_number == "":
        return

    session = requests.Session()
    session.headers["Authorization"] = f"Token {github_token}"
    url = f"https://api.github.com/repos/returntocorp/semgrep/issues/{pull_request_number}/comments"
    session.headers["Accept"] = "application/vnd.github.comfort-fade-preview+json"

    commit_id = json.loads(Path(os.getenv("GITHUB_EVENT_PATH")).read_text())[
        "pull_request"
    ]["head"]["sha"]
    pr_comment_payload = {
        "body": message,
        "commit_id": commit_id,
    }
    r = session.post(url, json=pr_comment_payload)

    # Raise if unable to comment
    print(message)
    r.raise_for_status()


def read_timing(filename: Path) -> List[float]:
    print(f"Reading {filename}")
    times = filename.read_text()
    return [float(t) for t in times.split()]


def main() -> None:
    # There are two versions of each timing to improve stability
    baseline_timing_file_1 = Path(sys.argv[1])
    baseline_timing_file_2 = Path(sys.argv[2])
    latest_timing_file_1 = Path(sys.argv[3])
    latest_timing_file_2 = Path(sys.argv[4])
    github_token = sys.argv[5]

    # Note this only defined in pull requests
    pull_request_number = sys.argv[6] if len(sys.argv) >= 7 else ""

    baseline_times = zip(
        read_timing(baseline_timing_file_1), read_timing(baseline_timing_file_2)
    )
    latest_times = zip(
        read_timing(latest_timing_file_1), read_timing(latest_timing_file_2)
    )
    # Eliminate "flukes" by taking the fastest time available for each
    # benchmark.
    baseline_times = [min(t1, t2) for t1, t2 in baseline_times]
    latest_times = [min(t1, t2) for t1, t2 in latest_times]

    # Accumulators
    n = 0
    total_baseline = 0.0
    total_latest = 0.0
    total_rel_dur = 0.0
    min_rel_dur = 1.0
    max_rel_dur = 1.0

    # Accumulators of warning messages and error messages in the format
    # expected by GitHub comments.
    messages = []
    errors = 0

    for baseline_time, latest_time in zip(baseline_times, latest_times):
        i = n
        n += 1
        total_baseline += baseline_time
        total_latest += latest_time

        rel_dur = latest_time / baseline_time
        total_rel_dur += rel_dur
        min_rel_dur = min(min_rel_dur, rel_dur)
        max_rel_dur = max(max_rel_dur, rel_dur)

        print(
            f"[{i}] {rel_dur:.3f}x "
            f"Baseline: {baseline_time:.3f}, Latest: {latest_time:.3f}"
        )

        perc = 100 * (rel_dur - 1)

        # Assert latest time is not more than 20% slower than baseline
        # or is within a fixed "probably environmental" range
        if latest_time > baseline_time * 1.2 and latest_time - baseline_time > 5.0:
            errors += 1
            messages.append(f"🚫 Benchmark #{i} is too slow: " f"+{perc:.1f}%")
        elif rel_dur > 1.1:
            messages.append(
                f"⚠️Potential non-blocking slowdown in benchmark #{i}: " f"+{perc:.1f}%"
            )
        elif rel_dur < 0.9:
            messages.append(f"🔥 Potential speedup in benchmark #{i}: " f"{perc:.1f}%")

    mean_rel_dur = total_rel_dur / n
    mean_perc = 100 * (mean_rel_dur - 1)
    if mean_perc > 0:
        mean_perc_str = f"{mean_perc:.1f}% slower"
    else:
        mean_perc_str = f"{-mean_perc:.1f}% faster"

    print(f"Average: {rel_dur:.3f}x, " f"Min: {rel_dur:.3f}x, " f"Max: {rel_dur:.3f}x")
    print(f"Total Baseline: {total_baseline} s, Latest: {total_latest} s")

    # Send PR comment if anything's weird or really wrong
    if messages:
        messages.append(f"{n} benchmarks, {mean_perc_str} on average.")
        messages.append(
            "Deviations greater than 10% from the baseline are reported. "
            "See run output for more details."
        )
        msg = "\n\n".join(messages)
        print(f"Sending warnings and errors as a PR comment:\n{msg}")
        send_comment(
            msg,
            github_token,
            pull_request_number,
        )

    # Fail only after printing and sending all messages
    assert not errors

    # Assert the rules in aggregate are not more than 6% slower than baseline
    assert mean_rel_dur < 1.06


if __name__ == "__main__":
    main()
