#!/usr/bin/env python3
"""Unit coverage for the Logic Free Tempo modal helper."""

from __future__ import annotations

import unittest

from logic_free_tempo_modal import DEFAULT_FREE_TEMPO_POLICY, resolve_free_tempo_modal


class FakeRunner:
    def __init__(self, snapshots, click_status="clicked"):
        self.snapshots = list(snapshots)
        self.click_status = click_status
        self.detect_calls = 0
        self.clicks = []

    def detect(self):
        index = min(self.detect_calls, len(self.snapshots) - 1)
        self.detect_calls += 1
        return self.snapshots[index]

    def click(self, role, name):
        self.clicks.append((role, name))
        return {"status": self.click_status, "role": role, "name": name}


def present_snapshot(
    *,
    title=None,
    buttons=None,
    checkboxes=None,
    radio_buttons=None,
    static_texts=None,
):
    return {
        "status": "present",
        "kind": "sheet",
        "title": title or "Free Tempo Recording",
        "buttons": buttons or ["Cancel", "OK"],
        "checkboxes": checkboxes or [{"name": "Don't show again", "value": "0"}],
        "radio_buttons": radio_buttons or [
            {"name": "Analyze region tempo and set project tempo", "value": "0"},
            {"name": "Don't analyze region tempo or change project tempo", "value": "0"},
        ],
        "static_texts": static_texts or ["Free Tempo Recording"],
    }


class ResolveFreeTempoModalTests(unittest.TestCase):
    def test_absent_modal_returns_not_present(self):
        runner = FakeRunner([{"status": "not_present"}])
        result = resolve_free_tempo_modal(runner=runner, pause=lambda _: None)
        self.assertEqual(result["status"], "not_present")
        self.assertEqual(result["policy_id"], DEFAULT_FREE_TEMPO_POLICY["policy_id"])
        self.assertEqual(runner.clicks, [])

    def test_resolve_clicks_selection_checkbox_and_confirm(self):
        runner = FakeRunner(
            [
                present_snapshot(),
                {"status": "not_present"},
            ]
        )
        result = resolve_free_tempo_modal(runner=runner, pause=lambda _: None)
        self.assertEqual(result["status"], "dismissed")
        self.assertEqual(
            runner.clicks,
            [
                ("radio button", "Don't analyze region tempo or change project tempo"),
                ("checkbox", "Don't show again"),
                ("button", "OK"),
            ],
        )
        self.assertEqual(result["decision"]["selection"], DEFAULT_FREE_TEMPO_POLICY["selection_labels"][0])
        self.assertEqual(result["decision"]["suppress_future_prompts"], "requested")
        self.assertEqual(result["decision"]["confirm"], "OK")

    def test_selection_button_is_clicked_when_policy_option_is_a_button(self):
        label = "Don't analyze region tempo or change project tempo"
        runner = FakeRunner(
            [
                {
                    "status": "present",
                    "kind": "sheet",
                    "title": "Free Tempo Recording",
                    "buttons": [label],
                    "checkboxes": [],
                    "radio_buttons": [],
                    "static_texts": ["Free Tempo Recording"],
                },
                {"status": "not_present"},
            ]
        )
        result = resolve_free_tempo_modal(runner=runner, pause=lambda _: None)
        self.assertEqual(result["status"], "dismissed")
        self.assertEqual(runner.clicks, [("button", label)])
        self.assertEqual(result["decision"]["confirm"], label)
        self.assertEqual(result["decision"]["confirm_strategy"], "selection_button")

    def test_already_selected_plan_uses_single_button_fallback(self):
        runner = FakeRunner(
            [
                present_snapshot(
                    buttons=["Apply"],
                    checkboxes=[],
                    radio_buttons=[
                        {"name": "Don't analyze region tempo or change project tempo", "value": "1"}
                    ],
                ),
                {"status": "not_present"},
            ]
        )
        result = resolve_free_tempo_modal(runner=runner, pause=lambda _: None)
        self.assertEqual(result["status"], "dismissed")
        self.assertEqual(runner.clicks, [("checkbox", "Don't show again"), ("button", "Apply")])
        self.assertTrue(result["decision"]["selection_already_active"])
        self.assertEqual(result["decision"]["confirm_strategy"], "single_button_fallback")

    def test_missing_named_selection_blocks(self):
        runner = FakeRunner(
            [
                present_snapshot(
                    radio_buttons=[{"name": "Analyze region tempo and set project tempo", "value": "1"}]
                )
            ]
        )
        result = resolve_free_tempo_modal(runner=runner, pause=lambda _: None)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "selection_control_missing")
        self.assertEqual(runner.clicks, [])

    def test_modal_still_visible_after_actions_blocks(self):
        runner = FakeRunner(
            [
                present_snapshot(),
                present_snapshot(),
            ]
        )
        result = resolve_free_tempo_modal(runner=runner, pause=lambda _: None)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["reason"], "modal_still_visible")

    def test_resolve_handles_korean_localized_modal(self):
        runner = FakeRunner(
            [
                present_snapshot(
                    title="프리 템포 녹음",
                    buttons=["취소", "확인"],
                    checkboxes=[{"name": "다시 표시 안 함", "value": "0"}],
                    radio_buttons=[
                        {"name": "프로젝트에 리전 템포 적용", "value": "0"},
                        {"name": "프로젝트에 평균 리전 템포 적용", "value": "0"},
                        {"name": "리전에 프로젝트 템포 적용", "value": "0"},
                        {
                            "name": "리전 템포를 분석하거나 프로젝트 템포를 변경하지 않음",
                            "value": "0",
                        },
                    ],
                    static_texts=["프리 템포 녹음"],
                ),
                {"status": "not_present"},
            ]
        )
        result = resolve_free_tempo_modal(runner=runner, pause=lambda _: None)
        self.assertEqual(result["status"], "dismissed")
        self.assertEqual(
            runner.clicks,
            [
                ("radio button", "리전 템포를 분석하거나 프로젝트 템포를 변경하지 않음"),
                ("checkbox", "다시 표시 안 함"),
                ("button", "확인"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
