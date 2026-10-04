import unittest

from scenarios.dns_referral import negative_reply


class NegativeReplyTest(unittest.TestCase):
    def test_empty_negative_answer(self):
        self.assertEqual(
            negative_reply("status: NOERROR\nANSWER: 0, AUTHORITY: 0"), (0, 0)
        )

    def test_counts_only_authority_records(self):
        reply = (
            "status: NOERROR\nANSWER: 0, AUTHORITY: 1\n"
            ";; AUTHORITY SECTION:\n. 123 IN NS a.root-servers.net.\n"
            ";; ADDITIONAL SECTION:\n. 123 IN SOA ignored.example. hostmaster.example. 1 2 3 4 5\n"
        )
        self.assertEqual(negative_reply(reply), (1, 0))

    def test_soa_negative_answer(self):
        reply = (
            "status: NOERROR\nANSWER: 0, AUTHORITY: 1\n;; AUTHORITY SECTION:\n"
            "example. 123 IN SOA ns.example. hostmaster.example. 1 2 3 4 5\n"
        )
        self.assertEqual(negative_reply(reply), (0, 1))

    def test_rejects_positive_answer_or_dns_failure(self):
        for reply in ("status: NOERROR\nANSWER: 1", "status: SERVFAIL\nANSWER: 0"):
            with self.subTest(reply=reply), self.assertRaises(RuntimeError):
                negative_reply(reply)
