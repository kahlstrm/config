"""Three DNS queries reproduce RouterOS's response change without a Java client."""

from datetime import datetime, timezone
import re

from lab import run

HOST = "s3.eu-west-1.amazonaws.com"
DNS_PORT = 1053


def negative_reply(output):
    if "status: NOERROR" not in output or not re.search(r"ANSWER: 0\b", output):
        raise RuntimeError("Expected a NOERROR reply with no AAAA answers")
    authority = output.partition(";; AUTHORITY SECTION:")[2].split(";;", 1)[0]
    records = [line.split() for line in authority.splitlines() if line.strip()]
    roots = sum(
        len(record) >= 5 and record[0] == "." and record[3] == "NS"
        for record in records
    )
    soa = sum(len(record) >= 5 and record[3] == "SOA" for record in records)
    return roots, soa


def experiment(lab):
    result = (
        lab.directory
        / "results"
        / "dns-referral"
        / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    )
    result.mkdir(parents=True)
    print(f"Results: {result}", flush=True)

    def query(name, kind, filename):
        output = run(
            "dig", "@127.0.0.1", "-p", str(DNS_PORT), name, kind,
            "+time=3", "+tries=1", capture_output=True, timeout=10,
        ).stdout
        (result / filename).write_text(output)
        if "status: NOERROR" not in output:
            raise RuntimeError(f"DNS query failed; inspect {result / filename}")
        return output

    with lab.forward("tcp", DNS_PORT, 53), lab.forward("udp", DNS_PORT, 53):
        lab.ssh("/ip/dhcp-client/set [find] use-peer-dns=no")
        lab.ssh('/ip/dns/set servers=1.1.1.1 allow-remote-requests=yes use-doh-server=""')
        (result / "router.txt").write_text(
            lab.ssh("/system/resource/print; /ip/dns/print")
        )
        lab.ssh("/ip/dns/cache/flush")
        try:
            before = negative_reply(query(HOST, "AAAA", "before.txt"))
            query(".", "NS", "root-query.txt")
            after = negative_reply(query(HOST, "AAAA", "after.txt"))
            reproduced = before[0] == 0 and after[0] > 0 and after[1] == 0
            summary = (
                f"Before root query: root NS={before[0]}, SOA={before[1]}\n"
                f"After root query: root NS={after[0]}, SOA={after[1]}\n"
                f"Referral-shaped response change reproduced: {reproduced}\n"
            )
            (result / "summary.txt").write_text(summary)
            print(summary, end="")
        finally:
            lab.ssh("/ip/dns/cache/flush")
    return result
