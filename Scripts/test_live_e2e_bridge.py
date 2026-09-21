import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def load_live_e2e_module():
    script_path = Path(__file__).with_name("live-e2e-test.py")
    spec = importlib.util.spec_from_file_location("live_e2e_test_module", script_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ExternalTmuxMCPClientCaptureTests(unittest.TestCase):
    def make_client(self, capture_file: Path):
        module = load_live_e2e_module()
        client = object.__new__(module.ExternalTmuxMCPClient)
        client.capture_file = str(capture_file)
        client.responses = {}
        client.capture_offset = 0
        client.capture_remainder = ""
        return client

    def test_refresh_responses_only_processes_new_appended_lines(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            capture_file = Path(tmpdir) / "capture.txt"
            response_one = {"jsonrpc": "2.0", "id": 1, "result": {"ok": True}}
            response_two = {"jsonrpc": "2.0", "id": 2, "result": {"ok": True}}
            capture_file.write_text(json.dumps(response_one) + "\n", encoding="utf-8")

            client = self.make_client(capture_file)
            client._refresh_responses()
            self.assertEqual(set(client.responses), {1})

            client.responses.pop(1)
            with capture_file.open("a", encoding="utf-8") as file:
                file.write(json.dumps(response_two) + "\n")

            client._refresh_responses()
            self.assertEqual(set(client.responses), {2})

    def test_refresh_responses_parses_large_raw_jsonrpc_line(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            capture_file = Path(tmpdir) / "capture.txt"
            large_payload = {
                "jsonrpc": "2.0",
                "id": 77,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps(
                                {
                                    "logic_pro_running": True,
                                    "channels": [
                                        {"channel": "Accessibility", "detail": "A" * 1024},
                                        {"channel": "AppleScript", "detail": "B" * 1024},
                                        {"channel": "MIDIKeyCommands", "detail": "C" * 1024},
                                    ],
                                }
                            ),
                        }
                    ]
                },
            }
            capture_file.write_text(json.dumps(large_payload) + "\n", encoding="utf-8")

            client = self.make_client(capture_file)
            client._refresh_responses()

            self.assertIn(77, client.responses)
            self.assertEqual(client.responses[77]["id"], 77)


if __name__ == "__main__":
    unittest.main()
