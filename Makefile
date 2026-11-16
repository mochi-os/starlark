# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: Apache-2.0

check:
	python3 tools/check.py
	python3 -B -m unittest discover -s tools -p 'test_*.py'
