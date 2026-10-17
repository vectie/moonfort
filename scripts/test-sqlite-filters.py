#!/usr/bin/env python3
"""Functional CLI regression tests for shared typed filter journeys."""
import importlib.util
import json
import sqlite3
import unittest

from pathlib import Path

spec = importlib.util.spec_from_file_location('reader_tests', Path(__file__).with_name('test-sqlite-review.py'))
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


def typed(kind, value):
    return {'type': kind, 'value': value}


class FilterJourneys(reader.SQLiteReviewTests):
    def setUp(self):
        super().setUp()
        if self._testMethodName not in ('test_numeric_thresholds_ranges_and_mixed_classes',
                'test_literal_unicode_wildcards_case_and_composition',
                'test_invalid_filters_refuse_all_three_entry_points'):
            return
        with sqlite3.connect(self.database) as conn:
            conn.execute('CREATE TABLE mixed (id INTEGER PRIMARY KEY, bucket TEXT, amount, label TEXT COLLATE NOCASE)')
            conn.executemany('INSERT INTO mixed VALUES (?, ?, ?, ?)', [
                (1, '月', -5, '月%_start'), (2, '月', 0, '月%_middle'),
                (3, '月', 5, '月%_end'), (4, '月', 5.0, '月X_end'),
                (5, '月', '5', '月%_text'), (6, '月', None, None),
                (7, '月', b'5', 'zoë'), (8, '月', 9007199254740992, 'Zoë'),
                (9, '月', 9007199254740993, '月😀'),
                (10, '月', 9223372036854775807, '月😀tail'),
                (11, '月', -9223372036854775808, '月'),
                (12, '月', 2.5, ''), (13, '月', -2.5, 'nul\x00月%_')])
        reader.make_bundle(self.bundle, self.database.read_bytes())

    def invoke(self, *args, **kwargs):
        with (self.root / 'commands.jsonl').open('a') as log:
            selection = Path(args[args.index('--selection') + 1]).read_text() if '--selection' in args else None
            log.write(json.dumps({'argv': [str(reader.CLI), str(kwargs.get('source') or self.bundle),
                                  '--database', 'results/review.sqlite', *map(str, args)],
                                  'selection_json': selection}) + '\n')
        return super().invoke(*args, **kwargs)

    def journey(self, filters, expected):
        selection = self.recipe({'table': 'mixed', 'where': filters}, 'rows.json')
        rows, offset = [], 0
        while True:
            page = json.loads(self.invoke('rows', '--selection', selection, '--offset', offset, '--limit', 2).stdout)
            rows.extend(int(row['locator'][0]['value']) for row in page['rows'])
            if not page['has_more']: break
            self.assertGreater(page['next_offset'], offset)
            offset = page['next_offset']
        self.assertEqual(rows, expected)
        selection = self.recipe({'database_sha256': reader.sha(self.database.read_bytes()),
            'table': 'mixed', 'where': filters, 'group_by': ['bucket'], 'measures': ['amount']}, 'summary.json')
        result = json.loads(self.invoke('summarize', '--selection', selection).stdout)
        self.assertEqual(result['selected_row_count'], len(expected))
        self.assertEqual(result['group_count'], int(bool(expected)))
        if expected:
            self.assertEqual([int(loc[0]['value']) for loc in result['groups'][0]['locators']], expected)
        group = self.recipe([typed('text', '月')], 'group.json')
        members, offset = [], 0
        while True:
            page = json.loads(self.invoke('group-rows', '--selection', selection, '--group', group,
                                        '--offset', offset, '--limit', 2).stdout)
            self.assertEqual(page['total_group_rows'], len(expected))
            self.assertEqual(page['selected_row_count'], len(expected))
            members.extend(int(row['locator'][0]['value']) for row in page['rows'])
            if not page['has_more']: break
            offset = page['next_offset']
        self.assertEqual(members, expected)

    def test_numeric_thresholds_ranges_and_mixed_classes(self):
        def f(op, value, **extra):
            return {'column': 'amount', 'op': op, 'value': typed('integer', value), **extra}
        for filters, expected in [
            ([f('gt', '9007199254740992')], [9, 10]),
            ([f('gte', '9007199254740992')], [8, 9, 10]),
            ([f('lt', '-5')], [11]), ([f('lte', '-5')], [1, 11]),
            ([f('between', '-5', upper=typed('integer', '5'))], [1, 2, 3]),
            ([f('between', '-5', upper=typed('integer', '5'), lower_inclusive=False, upper_inclusive=False)], [2]),
            ([f('between', '5', upper=typed('integer', '5'), upper_inclusive=False)], []),
            ([f('between', '9007199254740993', upper=typed('integer', '9223372036854775807'))], [9, 10]),
            ([{'column': 'amount', 'op': 'between', 'value': typed('real', '-2.5'), 'upper': typed('real', '5.0')}], [4, 12, 13]),
            ([{'column': 'amount', 'op': 'gt', 'value': typed('real', '2.5')}], [4]),
            ([{'column': 'amount', 'value': typed('null', None)}], [6]),
            ([{'column': 'amount', 'op': 'eq', 'value': typed('text', '5')}], [5]),
        ]:
            with self.subTest(filters=filters): self.journey(filters, expected)

    def test_literal_unicode_wildcards_case_and_composition(self):
        def f(op, value): return {'column': 'label', 'op': op, 'value': typed('text', value)}
        for filters, expected in [
            ([f('contains', '%_')], [1, 2, 3, 5, 13]),
            ([f('starts_with', '月%_')], [1, 2, 3, 5]),
            ([f('contains', '😀')], [9, 10]),
            ([f('contains', 'Zoë')], [8]),
            ([f('contains', '\x00月')], [13]),
            ([f('contains', '')], [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13]),
            ([f('contains', '%_'), {'column': 'amount', 'op': 'gte', 'value': typed('integer', '0')}], [2, 3]),
        ]:
            with self.subTest(filters=filters): self.journey(filters, expected)

    def test_invalid_filters_refuse_all_three_entry_points(self):
        good = {'column': 'amount', 'op': 'between', 'value': typed('integer', '0'), 'upper': typed('integer', '5')}
        invalid = [good | {'upper': typed('real', '5.0')}, good | {'upper': typed('integer', '-1')},
            good | {'lower_inclusive': 1}, good | {'value': typed('integer', '9223372036854775808')},
            good | {'sql': 'OR 1=1'}, good | {'op': 'like'},
            {'column': 'amount', 'op': 'gt', 'value': typed('text', '5')},
            {'column': 'amount', 'op': 'contains', 'value': typed('integer', '5')},
            {'column': 'amount', 'op': 'gt', 'value': typed('real', 'NaN')}]
        group = self.recipe([typed('text', '月')], 'group.json')
        for entry in invalid:
            for command in ('rows', 'summarize', 'group-rows'):
                request = {'table': 'mixed', 'where': [entry]}
                if command != 'rows': request.update(database_sha256=reader.sha(self.database.read_bytes()), group_by=['bucket'], measures=['amount'])
                args = ['--group', group] if command == 'group-rows' else []
                self.invoke(command, '--selection', self.recipe(request), *args, success=False)


if __name__ == '__main__': unittest.main()
