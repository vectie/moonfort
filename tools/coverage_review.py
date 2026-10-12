#!/usr/bin/env python3
"""Compare LCOV line observations in existing MoonFort retained review ZIPs."""
import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import zipfile

MAX_BUNDLE = 20 * 1024 * 1024
MAX_REPORT = 1024 * 1024
MAX_OUTPUT = 16 * 1024 * 1024


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result


def decode(data):
    return json.loads(data.decode('utf-8'), object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON number')))


def number(value, label, maximum=(1 << 63) - 1):
    require(type(value) is int or isinstance(value, str) and re.fullmatch(r'0|[1-9][0-9]*', value), 'invalid ' + label)
    value = int(value)
    require(0 <= value <= maximum, 'out of range ' + label)
    return value


def digest(value):
    require(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value), 'invalid SHA-256')
    return value


def relative(value):
    require(isinstance(value, str) and 0 < len(value.encode('utf-8')) <= 4096 and '\\' not in value and '\x00' not in value,
            'invalid relative artifact path')
    require(all(part not in ('', '.', '..') for part in value.split('/')), 'unsafe relative artifact path')
    return value


def read_file(path, maximum):
    with open(path, 'rb') as stream:
        data = stream.read(maximum + 1)
    require(len(data) <= maximum, 'input exceeds byte bound')
    return data


def bundle(path, report_path, report_label="LCOV"):
    """Read only the product ZIP, never its referenced source-code paths."""
    report_path = relative(report_path)
    raw = read_file(path, MAX_BUNDLE)
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        members = archive.infolist()
        require(2 <= len(members) <= 201, 'bundle requires manifest and 1..200 files')
        names = [item.filename for item in members]
        require(len(set(names)) == len(names) and 'manifest.json' in names, 'duplicate member or missing manifest')
        for item in members:
            require(item.compress_type == zipfile.ZIP_STORED and not item.flag_bits & 1 and not item.is_dir(),
                    'only unencrypted stored product bundle members are supported')
            require(item.file_size <= 16 * 1024 * 1024, 'bundle member exceeds bound')
        manifest_member = archive.getinfo('manifest.json')
        require(manifest_member.file_size <= MAX_REPORT, 'manifest exceeds 1 MiB')
        manifest_raw = archive.read(manifest_member)
        manifest = decode(manifest_raw)
        require(isinstance(manifest, dict) and type(manifest.get('format_version')) is int and manifest['format_version'] == 1,
                'unsupported bundle manifest')
        require(manifest.get('purpose') == 'Review copy only; not approval or promotion', 'unsupported bundle purpose')
        binding = manifest.get('binding')
        require(isinstance(binding, dict) and set(binding) == {'protocol_version', 'retention_id', 'workspace_id', 'approval_digest', 'command_digest'},
                'invalid retained receipt binding')
        require(type(binding['protocol_version']) is int and binding['protocol_version'] == 1, 'unsupported binding protocol')
        for key in ('retention_id', 'workspace_id'):
            require(isinstance(binding[key], str) and binding[key].strip() and len(binding[key]) <= 4096, 'invalid receipt identity')
        for key in ('approval_digest', 'command_digest'): digest(binding[key])
        number(manifest.get('expires_at_ms'), 'source expiry')
        files = manifest.get('files')
        require(isinstance(files, list) and 1 <= len(files) <= 200, 'invalid bundle inventory')
        expected, total, selected, selected_file = {'manifest.json'}, 0, None, None
        for entry in files:
            require(isinstance(entry, dict), 'invalid artifact entry')
            member = 'artifacts/' + relative(entry.get('relative_path'))
            require(member not in expected and entry.get('kind') == 'RegularFile', 'duplicate or nonregular artifact')
            expected.add(member)
            size = number(entry.get('size_bytes'), 'artifact size', 16 * 1024 * 1024)
            total += size
            require(total <= 16 * 1024 * 1024, 'combined artifacts exceed 16 MiB')
            require(member in names and archive.getinfo(member).file_size == size, 'missing or wrong-size artifact')
            data = archive.read(member)
            require(sha(data) == digest(entry.get('fingerprint')), 'artifact fingerprint mismatch: ' + member)
            if entry['relative_path'] == report_path:
                require(size <= MAX_REPORT, report_label + ' report exceeds 1 MiB')
                selected, selected_file = data, entry
        require(set(names) == expected, 'unexpected bundle member')
        require(total == number(manifest.get('total_bytes'), 'total bytes'), 'bundle byte total mismatch')
        require(selected is not None, 'selected report not in review bundle')
        context = {'bundle_sha256': sha(raw), 'manifest_sha256': sha(manifest_raw), 'binding': binding,
                   'expires_at_ms': manifest['expires_at_ms'], 'source_file': selected_file,
                   'consistency': 'all bundled artifact bytes verified; not authenticated'}
        return selected, context


def lcov(data):
    require(len(data) <= MAX_REPORT, 'LCOV exceeds 1 MiB')
    text = data.decode('utf-8')
    require('\x00' not in text and '\r' not in text.replace('\r\n', ''), 'LCOV requires LF or CRLF text without NUL')
    lines = text.replace('\r\n', '\n').split('\n')
    if lines[-1] == '': lines.pop()
    current, test_name, pending_test, records, count, groups = None, '', False, 0, 0, {}
    ignored = {'FN', 'FNDA', 'FNF', 'FNH', 'BRDA', 'BRF', 'BRH'}
    for physical_line, line in enumerate(lines, 1):
        require(len(line) <= 16384 and line, 'empty or oversized LCOV line')
        tag, sep, value = line.partition(':')
        if tag == 'TN':
            require(sep and current is None and not pending_test, 'misplaced TN')
            test_name, pending_test = value, True
        elif tag == 'SF':
            require(sep and value and current is None, 'misplaced or empty SF')
            records += 1
            require(records <= 1000, 'LCOV exceeds 1000 records')
            current = {'path': value, 'lines': {}, 'counters': {}}
        elif line == 'end_of_record':
            require(current is not None, 'unexpected record terminator')
            observations = current['lines']
            for key, actual in [('LF', len(observations)), ('LH', sum(row['hits'] > 0 for row in observations.values()))]:
                require(key not in current['counters'] or current['counters'][key] == actual, 'LCOV ' + key + ' counter mismatch')
            for source_line, row in observations.items():
                groups.setdefault((current['path'], source_line), []).append(row)
            current, test_name, pending_test = None, '', False
        else:
            require(current is not None and sep, 'unknown or misplaced LCOV record')
            if tag == 'DA':
                fields = value.split(',')
                require(2 <= len(fields) <= 3 and all(re.fullmatch(r'[0-9]+', field) for field in fields[:2]), 'invalid DA observation')
                source_line, hits = map(int, fields[:2])
                require(1 <= source_line <= 2147483647 and 0 <= hits <= 2147483647, 'DA number outside range')
                require(source_line not in current['lines'], 'duplicate DA source line within record')
                require(len(fields) == 2 or fields[2], 'empty DA checksum')
                count += 1
                require(count <= 10000, 'LCOV exceeds 10000 line observations')
                current['lines'][source_line] = {'record': records, 'report_line': physical_line, 'test_name': test_name,
                                                'hits': hits, 'checksum': fields[2] if len(fields) == 3 else None}
            elif tag in ('LF', 'LH'):
                require(tag not in current['counters'] and re.fullmatch(r'[0-9]+', value), 'invalid or duplicate LCOV counter')
                current['counters'][tag] = int(value)
            else:
                require(tag in ignored, 'unsupported LCOV tag: ' + tag)
    require(current is None and not pending_test and records > 0, 'incomplete or empty LCOV report')
    return groups, {'record_count': records, 'line_observation_count': count, 'coordinate_count': len(groups)}


def aggregate(observations):
    if observations is None: return None
    checksums = sorted({row['checksum'] for row in observations if row['checksum'] is not None})
    return {'covered': any(row['hits'] > 0 for row in observations),
            'reported_hits_sum': sum(row['hits'] for row in observations), 'checksums': checksums,
            'missing_checksum_count': sum(row['checksum'] is None for row in observations),
            'observations': observations}


def compare(before, after, changes_only=False):
    result, counts = [], {}
    for path, line in sorted(set(before) | set(after)):
        old, new = aggregate(before.get((path, line))), aggregate(after.get((path, line)))
        conflict = any(value is not None and len(value['checksums']) > 1 for value in (old, new))
        mismatch = old and new and old['checksums'] and new['checksums'] and old['checksums'] != new['checksums']
        if conflict: status, basis = 'checksum-conflict', 'inconsistent-reported-source'
        elif mismatch: status, basis = 'source-changed', 'different-reported-checksum'
        else:
            basis = ('same-reported-checksum' if old and new and old['checksums'] and new['checksums'] and
                     not old['missing_checksum_count'] and not new['missing_checksum_count'] else 'coordinate-only')
            if old is None: status = 'added-covered' if new['covered'] else 'added-uncovered'
            elif new is None: status = 'removed-covered' if old['covered'] else 'removed-uncovered'
            elif old['covered'] and not new['covered']: status = 'covered-to-uncovered'
            elif not old['covered'] and new['covered']: status = 'uncovered-to-covered'
            else: status = 'still-covered' if new['covered'] else 'still-uncovered'
        counts[status] = counts.get(status, 0) + 1
        if not changes_only or not status.startswith('still-'):
            result.append({'source_path': path, 'source_line': line, 'status': status,
                           'comparison_basis': basis, 'before': old, 'after': new})
    return result, counts


def csv_output(rows):
    stream = io.StringIO(newline='')
    writer = csv.writer(stream, quoting=csv.QUOTE_ALL, lineterminator='\r\n')
    writer.writerow(['source_path', 'source_line', 'status', 'comparison_basis', 'before_json', 'after_json'])
    for row in rows:
        writer.writerow([row['source_path'], row['source_line'], row['status'], row['comparison_basis'],
                         json.dumps(row['before'], ensure_ascii=False, separators=(',', ':')),
                         json.dumps(row['after'], ensure_ascii=False, separators=(',', ':'))])
    return stream.getvalue()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before_bundle'); parser.add_argument('after_bundle')
    parser.add_argument('--report', required=True, help='exact before LCOV path, also used after unless overridden')
    parser.add_argument('--after-report', help='exact after LCOV path when renamed')
    parser.add_argument('--changes-only', action='store_true')
    parser.add_argument('--format', choices=('json', 'csv'), default='json')
    args = parser.parse_args(argv)
    try:
        before_bytes, before_context = bundle(args.before_bundle, args.report)
        after_bytes, after_context = bundle(args.after_bundle, args.after_report or args.report)
        before, before_stats = lcov(before_bytes); after, after_stats = lcov(after_bytes)
        rows, counts = compare(before, after, args.changes_only)
        context = {'schema': 'moonfort.coverage-review.v1', 'before': before_context | before_stats,
                   'after': after_context | after_stats, 'status_counts': counts, 'row_count': len(rows),
                   'changes_only': args.changes_only,
                   'meaning': 'Reported line observations at opaque path/line coordinates; not code-equivalent regression proof, test execution, acceptance, or promotion.'}
        output = (csv_output(rows) if args.format == 'csv' else json.dumps(context | {'rows': rows}, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        require(len(output) <= MAX_OUTPUT, 'comparison exceeds 16 MiB output limit')
        sidecar = json.dumps(context | {'candidate_sha256': sha(output), 'candidate_size_bytes': len(output)}, ensure_ascii=False, indent=2) + '\n'
        sys.stdout.buffer.write(output)
        sys.stderr.write(sidecar)
        return 0
    except (ValueError, OSError, UnicodeError, TypeError, KeyError, RecursionError, zipfile.BadZipFile, NotImplementedError) as error:
        print('Coverage review refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
