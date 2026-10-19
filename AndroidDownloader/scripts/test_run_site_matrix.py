"""Offline receipt validation tests. Does not start ADB or use a network."""

import json
import unittest

from run_site_matrix import summarize, validate_result


def receipt(video_id="real-id"):
    return {"site": "YouTube", "id": video_id, "bytes": 1000, "duration": 2,
            "streams": ["video", "audio"], "sha256": "a" * 64,
            "uri": "content://media/external/video/media/2", "decodedSamples": 3}


def stdout(value):
    return "INSTRUMENTATION_STATUS: stream=FEIYU_SITE_RESULT " + json.dumps(value) + "\nOK (1 test)\n"


class DownloadReceiptTests(unittest.TestCase):
    def test_stdout_receipt_does_not_require_logcat(self):
        actual, error = validate_result(stdout(receipt()), "", "marker", "youtube")
        self.assertIsNone(error)
        self.assertEqual(actual["id"], "real-id")

    def test_junit_skip_does_not_pass_without_real_file(self):
        actual, error = validate_result("OK (1 test)", "", "marker", "youtube")
        self.assertIsNone(actual)
        self.assertIn("skipped", error)

    def test_metadata_only_does_not_count(self):
        value = receipt()
        value.pop("uri")
        actual, error = validate_result(stdout(value), "", "marker", "youtube")
        self.assertIsNone(actual)
        self.assertIsNotNone(error)

    def test_silent_video_does_not_count(self):
        value = receipt()
        value["streams"] = ["video"]
        self.assertIsNotNone(validate_result(stdout(value), "", "marker", "youtube")[1])

    def test_missing_decodes_do_not_count(self):
        value = receipt()
        value.pop("decodedSamples")
        self.assertIsNotNone(validate_result(stdout(value), "", "marker", "youtube")[1])

    def test_failed_junit_does_not_count_even_with_receipt(self):
        actual, error = validate_result(stdout(receipt()) + "FAILURES!!!", "", "marker", "youtube")
        self.assertIsNone(actual)
        self.assertIsNotNone(error)

    def test_old_logcat_receipt_does_not_count(self):
        value = "FEIYU_SITE_RESULT " + json.dumps(receipt())
        self.assertIsNotNone(validate_result("OK (1 test)", value, "missing-marker", "youtube")[1])

    def test_duplicate_real_ids_do_not_satisfy_two_fixtures(self):
        state = {"results": [{"status": "passed", "site": "youtube", "downloadedFile": receipt()} for _ in range(2)]}
        summarize(state)
        self.assertEqual(state["distinctVideoIds"]["youtube"], ["real-id"])
        self.assertFalse(state["selectedFixtureCoveragePassed"])
        self.assertFalse(state["sixSitesTwoDistinctVideosPassed"])


if __name__ == "__main__":
    unittest.main()
