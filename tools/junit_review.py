#!/usr/bin/env python3
"""Compare reported test outcomes in two existing MoonFort retained review ZIPs."""
import argparse
import csv
import io
import json
import sys
import xml.parsers.expat as expat
import zipfile
from coverage_review import bundle, require, sha, MAX_OUTPUT, MAX_REPORT


def junit(data):
    require(len(data) <= MAX_REPORT, 'JUnit report exceeds 1 MiB')
    parser = expat.ParserCreate()
    stack, suites, cases = [], [], []
    current, diagnostic = None, None

    def start(tag, attrs):
        nonlocal current, diagnostic
        require(len(stack) < 64, 'JUnit nesting exceeds 64')
        parent = stack[-1] if stack else None
        if not stack:
            require(tag in ('testsuites', 'testsuite'), 'JUnit root must be testsuites or testsuite')
        elif tag == 'testsuites':
            raise ValueError('nested testsuites is unsupported')
        elif tag == 'testsuite':
            require(parent in ('testsuites', 'testsuite') and current is None, 'misplaced testsuite')
        elif tag == 'testcase':
            require(parent == 'testsuite' and current is None, 'misplaced testcase')
            require(len(cases) < 10000, 'JUnit exceeds 10000 testcases')
            require('name' in attrs, 'testcase requires a name')
            current = {'suite_path': list(suites), 'classname': attrs.get('classname', ''), 'name': attrs['name'],
                       'source_line': parser.CurrentLineNumber, 'test_index': len(cases) + 1,
                       'time': attrs.get('time', ''), 'file': attrs.get('file', ''), 'line': attrs.get('line', ''),
                       'status': attrs.get('status', ''), 'result': attrs.get('result', ''), 'diagnostics': []}
            require(current['status'] in ('', 'run', 'notrun') and current['result'] in ('', 'completed', 'suppressed', 'skipped'), 'unsupported testcase status/result')
            require(not (current['status'] == 'notrun' and current['result'] == 'completed'), 'contradictory testcase status/result')
        elif tag in ('failure', 'error', 'skipped'):
            require(parent == 'testcase' and current is not None, 'misplaced testcase outcome')
            diagnostic = {'kind': tag, 'type': attrs.get('type', ''), 'message': attrs.get('message', ''), 'text': ''}
            current['diagnostics'].append(diagnostic)
        elif tag == 'properties':
            require(parent in ('testsuite', 'testcase'), 'misplaced properties')
        elif tag == 'property':
            require(parent == 'properties', 'misplaced property')
        elif tag in ('system-out', 'system-err'):
            require(parent in ('testsuite', 'testcase'), 'misplaced output')
        else:
            raise ValueError('unsupported JUnit element: ' + tag)
        if tag == 'testsuite': suites.append(attrs.get('name', ''))
        stack.append(tag)

    def end(tag):
        nonlocal current, diagnostic
        if tag in ('failure', 'error', 'skipped'): diagnostic = None
        if tag == 'testcase':
            kinds = {item['kind'] for item in current['diagnostics']}
            skipped = 'skipped' in kinds or current['status'] == 'notrun' or current['result'] in ('suppressed', 'skipped')
            require(not (skipped and kinds & {'error', 'failure'}), 'contradictory skipped/failing testcase')
            current['outcome'] = 'skipped' if skipped else 'error' if 'error' in kinds else 'failed' if 'failure' in kinds else 'passed'
            cases.append(current); current = None
        if tag == 'testsuite': suites.pop()
        stack.pop()

    def text(value):
        if diagnostic is not None: diagnostic['text'] += value

    def forbidden(*_):
        raise ValueError('DTD and entity declarations are unsupported in JUnit review')

    parser.StartElementHandler, parser.EndElementHandler, parser.CharacterDataHandler = start, end, text
    parser.StartDoctypeDeclHandler = forbidden
    parser.EntityDeclHandler = forbidden
    parser.ExternalEntityRefHandler = forbidden
    parser.Parse(data, True)
    require(not stack and cases is not None, 'incomplete JUnit report')
    return cases


def compare_cases(before, after, changes_only=False):
    def grouped(cases):
        groups = {}
        for case in cases:
            identity = (tuple(case['suite_path']), case['classname'], case['name'])
            groups.setdefault(identity, []).append(case)
        return groups
    old, new = grouped(before), grouped(after)
    rows, counts = [], {}
    for identity in sorted(set(old) | set(new)):
        previous, current = old.get(identity, []), new.get(identity, [])
        if len(previous) > 1 or len(current) > 1: status = 'ambiguous-identity'
        elif not previous: status = 'added'
        elif not current: status = 'removed'
        elif previous[0]['outcome'] != current[0]['outcome']: status = 'changed-outcome'
        elif any(previous[0][key] != current[0][key] for key in ('time', 'file', 'line', 'status', 'result', 'diagnostics')): status = 'changed-details'
        else: status = 'unchanged'
        counts[status] = counts.get(status, 0) + 1
        if not changes_only or status != 'unchanged':
            rows.append({'suite_path': list(identity[0]), 'classname': identity[1], 'name': identity[2],
                         'status': status, 'before': previous, 'after': current})
    return rows, counts


def csv_output(rows):
    stream = io.StringIO(newline='')
    writer = csv.writer(stream, quoting=csv.QUOTE_ALL, lineterminator='\r\n')
    writer.writerow(['suite_path_json', 'classname', 'name', 'status', 'before_json', 'after_json'])
    for row in rows:
        writer.writerow([json.dumps(row['suite_path'], ensure_ascii=False), row['classname'], row['name'], row['status'],
                         json.dumps(row['before'], ensure_ascii=False), json.dumps(row['after'], ensure_ascii=False)])
    return stream.getvalue()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before_bundle'); parser.add_argument('after_bundle')
    parser.add_argument('--report', required=True, help='exact before JUnit artifact path')
    parser.add_argument('--after-report', help='exact after artifact path, defaults to --report')
    parser.add_argument('--changes-only', action='store_true')
    parser.add_argument('--format', choices=('json', 'csv'), default='json')
    args = parser.parse_args(argv)
    try:
        old_bytes, old_context = bundle(args.before_bundle, args.report, report_label='JUnit')
        new_bytes, new_context = bundle(args.after_bundle, args.after_report or args.report, report_label='JUnit')
        old, new = junit(old_bytes), junit(new_bytes)
        rows, counts = compare_cases(old, new, args.changes_only)
        context = {'schema': 'moonfort.junit-review.v1', 'before': old_context | {'testcase_count': len(old)},
                   'after': new_context | {'testcase_count': len(new)}, 'status_counts': counts, 'row_count': len(rows),
                   'changes_only': args.changes_only,
                   'meaning': 'Reported outcomes matched by exact nested suite names, classname and name; duplicate identities are unpaired. Not execution, regression proof, acceptance or promotion.'}
        output = (csv_output(rows) if args.format == 'csv' else json.dumps(context | {'rows': rows}, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        require(len(output) <= MAX_OUTPUT, 'comparison exceeds 16 MiB output limit')
        sys.stdout.buffer.write(output)
        sys.stderr.write(json.dumps(context | {'candidate_sha256': sha(output), 'candidate_size_bytes': len(output)}, ensure_ascii=False, indent=2) + '\n')
        return 0
    except (ValueError, OSError, UnicodeError, TypeError, KeyError, RecursionError, zipfile.BadZipFile, NotImplementedError, expat.ExpatError) as error:
        print('JUnit review refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
